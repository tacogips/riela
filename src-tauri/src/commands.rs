//! The IPC surface the dashboard talks to.
//!
//! `riela_fetch` is the whole network boundary: the WebView hands over a
//! relative path and the host performs the request against the discovered
//! loopback endpoint. HTTP error statuses are data, not failures — they are
//! passed back verbatim so the SPA's existing 404 → "cli-serve" fallback keeps
//! working unchanged.

use std::str::FromStr;
use std::sync::Arc;
use std::time::Duration;

use crate::endpoint::{outbound_headers, validate_relative_path, Endpoint};
use crate::lifecycle::{LifecycleError, ServerLifecycle};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const READY_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, serde::Deserialize)]
pub struct FetchRequest {
    pub path: String,
    pub method: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<String>,
}

#[derive(Debug, serde::Serialize)]
pub struct FetchResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

#[derive(Debug, serde::Serialize)]
pub struct CommandError {
    /// `invalid_request` | `server_unavailable` | `request_failed`
    pub code: &'static str,
    pub message: String,
}

impl CommandError {
    fn invalid_request(message: impl Into<String>) -> Self {
        Self {
            code: "invalid_request",
            message: message.into(),
        }
    }

    fn server_unavailable(message: impl Into<String>) -> Self {
        Self {
            code: "server_unavailable",
            message: message.into(),
        }
    }

    fn request_failed(message: impl Into<String>) -> Self {
        Self {
            code: "request_failed",
            message: message.into(),
        }
    }
}

#[derive(Debug, serde::Serialize)]
pub struct ServerStatus {
    pub state: &'static str,
    pub endpoint: Option<Endpoint>,
    pub detail: Option<String>,
}

pub struct AppState {
    pub lifecycle: Arc<ServerLifecycle>,
    pub http: reqwest::Client,
}

impl AppState {
    pub fn new(lifecycle: Arc<ServerLifecycle>) -> Self {
        Self {
            lifecycle,
            // No redirect following: every legitimate dashboard response is a
            // direct answer from the loopback server.
            http: reqwest::Client::builder()
                .timeout(REQUEST_TIMEOUT)
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .unwrap_or_default(),
        }
    }
}

/// Response headers that describe the host-to-server hop rather than the
/// payload, and must not leak into the WebView's synthetic `Response`.
fn is_hidden_response_header(name: &str) -> bool {
    matches!(
        name,
        "set-cookie" | "connection" | "content-length" | "content-encoding" | "transfer-encoding"
    )
}

fn parse_method(raw: &str) -> Result<reqwest::Method, CommandError> {
    reqwest::Method::from_str(raw)
        .map_err(|_| CommandError::invalid_request(format!("Unsupported HTTP method \"{raw}\".")))
}

async fn execute(state: &AppState, request: FetchRequest) -> Result<FetchResponse, CommandError> {
    validate_relative_path(&request.path)
        .map_err(|error| CommandError::invalid_request(error.to_string()))?;

    let endpoint =
        state.lifecycle.wait_ready(READY_TIMEOUT).await.map_err(
            |LifecycleError::Unavailable(detail)| CommandError::server_unavailable(detail),
        )?;

    let method = parse_method(&request.method)?;

    let mut builder = state.http.request(
        method.clone(),
        format!("{}{}", endpoint.origin, request.path),
    );
    for (name, value) in outbound_headers(method.as_str(), &endpoint.origin, &request.headers) {
        builder = builder.header(name, value);
    }
    if let Some(body) = request.body {
        builder = builder.body(body);
    }

    let response = match builder.send().await {
        Ok(response) => response,
        Err(error) => {
            // The server we discovered is gone or wedged: demote it so the next
            // attempt re-runs discovery instead of retrying a dead socket.
            if error.is_connect() || error.is_timeout() {
                state.lifecycle.mark_unreachable(error.to_string());
                return Err(CommandError::server_unavailable(error.to_string()));
            }
            return Err(CommandError::request_failed(error.to_string()));
        }
    };

    let status = response.status().as_u16();
    let headers = response
        .headers()
        .iter()
        .filter(|(name, _)| !is_hidden_response_header(name.as_str()))
        .filter_map(|(name, value)| {
            value
                .to_str()
                .ok()
                .map(|value| (name.as_str().to_string(), value.to_string()))
        })
        .collect();
    let body = response
        .text()
        .await
        .map_err(|error| CommandError::request_failed(error.to_string()))?;

    Ok(FetchResponse {
        status,
        headers,
        body,
    })
}

fn snapshot(lifecycle: &ServerLifecycle) -> ServerStatus {
    let status = lifecycle.status();
    ServerStatus {
        state: status.state,
        endpoint: status.endpoint,
        detail: status.detail,
    }
}

#[tauri::command]
pub async fn riela_fetch(
    state: tauri::State<'_, AppState>,
    request: FetchRequest,
) -> Result<FetchResponse, CommandError> {
    execute(state.inner(), request).await
}

#[tauri::command]
pub async fn riela_server_retry(
    state: tauri::State<'_, AppState>,
) -> Result<ServerStatus, CommandError> {
    let lifecycle = state.lifecycle.clone();
    lifecycle.discover().await;
    Ok(snapshot(&lifecycle))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lifecycle::{LifecycleConfig, ProbeResult, Prober, ProcessSpawner};
    use std::future::Future;
    use std::pin::Pin;

    struct UnreachableProber;

    impl Prober for UnreachableProber {
        fn get(&self, _url: &str) -> Pin<Box<dyn Future<Output = ProbeResult> + Send + '_>> {
            Box::pin(async { ProbeResult::Unreachable })
        }
    }

    fn failed_state() -> AppState {
        let config = LifecycleConfig {
            configuration_error: Some("RIELA_DESKTOP_SERVER_URL is invalid: bad".to_string()),
            ..LifecycleConfig::default()
        };
        AppState::new(ServerLifecycle::new(
            config,
            Arc::new(UnreachableProber),
            Arc::new(ProcessSpawner),
        ))
    }

    fn request(path: &str) -> FetchRequest {
        FetchRequest {
            path: path.to_string(),
            method: "GET".to_string(),
            headers: Vec::new(),
            body: None,
        }
    }

    #[tokio::test]
    async fn rejects_paths_that_escape_the_endpoint_before_touching_the_network() {
        let state = failed_state();
        for path in [
            "//evil.example.com/api",
            "http://evil.example.com",
            "relative",
        ] {
            let error = execute(&state, request(path)).await.unwrap_err();
            assert_eq!(error.code, "invalid_request", "{path}: {}", error.message);
        }
    }

    #[tokio::test]
    async fn reports_server_unavailable_with_the_lifecycle_detail() {
        let state = failed_state();
        let error = execute(&state, request("/api/v1/bootstrap"))
            .await
            .unwrap_err();
        assert_eq!(error.code, "server_unavailable");
        assert!(
            error
                .message
                .contains("RIELA_DESKTOP_SERVER_URL is invalid"),
            "{}",
            error.message
        );
    }

    #[test]
    fn maps_methods_and_rejects_unparseable_ones() {
        assert_eq!(parse_method("POST").unwrap(), reqwest::Method::POST);
        assert_eq!(parse_method("DELETE").unwrap(), reqwest::Method::DELETE);
        let error = parse_method("BAD METHOD").unwrap_err();
        assert_eq!(error.code, "invalid_request");
        assert!(error.message.contains("BAD METHOD"), "{}", error.message);
    }

    #[test]
    fn hides_hop_by_hop_response_headers() {
        assert!(is_hidden_response_header("set-cookie"));
        assert!(is_hidden_response_header("content-length"));
        assert!(!is_hidden_response_header("content-type"));
        assert!(!is_hidden_response_header("x-riela-profile"));
    }
}
