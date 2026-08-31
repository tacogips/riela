//! Pure endpoint rules for the desktop shell.
//!
//! Everything here is side-effect free so the loopback guard, the outbound
//! header policy and the `riela` binary lookup can be unit-tested without a
//! network or a filesystem.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// Port RielaApp's embedded web listener binds when enabled from its menu.
pub const DEFAULT_APP_PORT: u16 = 19_091;
/// Port `riela serve` binds by default.
pub const DEFAULT_SERVE_PORT: u16 = 8_787;

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum EndpointKind {
    RielaApp,
    CliServe,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub struct Endpoint {
    pub origin: String,
    pub port: u16,
    pub kind: EndpointKind,
    /// `true` when this process spawned the server and therefore owns its
    /// lifetime. External servers are never terminated.
    pub managed: bool,
}

impl Endpoint {
    pub fn new(port: u16, kind: EndpointKind, managed: bool) -> Self {
        Self {
            origin: loopback_origin(port),
            port,
            kind,
            managed,
        }
    }
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum EndpointError {
    #[error("{0}")]
    InvalidOrigin(String),
    #[error("{0}")]
    InvalidPath(String),
}

pub fn loopback_origin(port: u16) -> String {
    format!("http://127.0.0.1:{port}")
}

/// Accepts only explicit loopback origins over plain HTTP and returns the port.
///
/// Anything else — a remote host, HTTPS, a path, a missing port — is rejected so
/// `RIELA_DESKTOP_SERVER_URL` can never point the desktop shell off the machine.
pub fn parse_loopback_origin(raw: &str) -> Result<u16, EndpointError> {
    let trimmed = raw.trim();
    let invalid = || {
        EndpointError::InvalidOrigin(format!(
            "\"{raw}\" is not a loopback origin; use http://127.0.0.1:<port>"
        ))
    };

    let rest = trimmed.strip_prefix("http://").ok_or_else(invalid)?;
    let rest = rest.strip_suffix('/').unwrap_or(rest);
    if rest.contains('/') || rest.contains('?') || rest.contains('#') || rest.contains('@') {
        return Err(invalid());
    }

    let (host, port) = if let Some(after_bracket) = rest.strip_prefix('[') {
        let (host, tail) = after_bracket.split_once(']').ok_or_else(invalid)?;
        (host.to_string(), tail.strip_prefix(':').map(str::to_string))
    } else {
        match rest.rsplit_once(':') {
            Some((host, port)) => (host.to_string(), Some(port.to_string())),
            None => (rest.to_string(), None),
        }
    };

    if !matches!(host.as_str(), "127.0.0.1" | "localhost" | "::1") {
        return Err(invalid());
    }
    let port = port.ok_or_else(|| {
        EndpointError::InvalidOrigin(format!(
            "\"{raw}\" must name an explicit port, e.g. http://127.0.0.1:{DEFAULT_SERVE_PORT}"
        ))
    })?;
    port.parse::<u16>()
        .ok()
        .filter(|port| *port != 0)
        .ok_or_else(invalid)
}

/// Guards the path the WebView asked for before it is joined onto the endpoint
/// origin, so a compromised page cannot escape the loopback server.
pub fn validate_relative_path(path: &str) -> Result<(), EndpointError> {
    let invalid = |reason: &str| {
        EndpointError::InvalidPath(format!(
            "\"{path}\" is not a valid dashboard path: {reason}"
        ))
    };

    if !path.starts_with('/') {
        return Err(invalid("it must start with \"/\""));
    }
    if path.starts_with("//") {
        return Err(invalid("protocol-relative paths are not allowed"));
    }
    if path.contains("://") {
        return Err(invalid("absolute URLs are not allowed"));
    }
    if path.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(invalid("it contains whitespace or control characters"));
    }

    let route = path
        .split_once(['?', '#'])
        .map(|(route, _)| route)
        .unwrap_or(path);
    if route.split('/').any(|segment| segment == "..") {
        return Err(invalid("parent-directory segments are not allowed"));
    }
    Ok(())
}

/// Headers that must never be forwarded from the WebView to the Riela server.
///
/// `Host`/`Origin` are re-derived by the host process, cookies are not part of
/// Riela's auth model, `sec-*` headers describe the WebView's own fetch context,
/// and hop-by-hop headers belong to the connection reqwest establishes itself.
fn is_dropped_header(name: &str) -> bool {
    const DROPPED: &[&str] = &[
        "host",
        "origin",
        "referer",
        "cookie",
        "set-cookie",
        "connection",
        "content-length",
        "transfer-encoding",
        "te",
        "trailer",
        "upgrade",
        "keep-alive",
    ];
    let lower = name.to_ascii_lowercase();
    DROPPED.contains(&lower.as_str()) || lower.starts_with("proxy-") || lower.starts_with("sec-")
}

/// Builds the header list sent to the Riela server.
///
/// Riela's loopback servers reject state-changing requests whose `Origin` is not
/// the server's own origin, so the host stamps it for every non-safe method. The
/// browser build gets this for free from same-origin `fetch`.
pub fn outbound_headers(
    method: &str,
    endpoint_origin: &str,
    incoming: &[(String, String)],
) -> Vec<(String, String)> {
    let mut headers: Vec<(String, String)> = incoming
        .iter()
        .filter(|(name, _)| !is_dropped_header(name))
        .cloned()
        .collect();

    let safe = matches!(
        method.to_ascii_uppercase().as_str(),
        "GET" | "HEAD" | "OPTIONS"
    );
    if !safe {
        headers.push(("Origin".to_string(), endpoint_origin.to_string()));
    }
    headers
}

/// Where to look for a `riela` binary when no server is already running.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct BinaryLookup {
    pub env_override: Option<PathBuf>,
    pub path_entries: Vec<PathBuf>,
    pub fallback_candidates: Vec<PathBuf>,
}

impl BinaryLookup {
    pub fn from_environment(
        cwd: &Path,
        env_override: Option<OsString>,
        path_var: Option<OsString>,
    ) -> Self {
        let path_entries = path_var
            .as_deref()
            .map(|value| {
                std::env::split_paths(value)
                    .filter(|entry| !entry.as_os_str().is_empty())
                    .collect()
            })
            .unwrap_or_default();

        Self {
            env_override: env_override
                .map(PathBuf::from)
                .filter(|p| !p.as_os_str().is_empty()),
            path_entries,
            fallback_candidates: vec![
                cwd.join(".build/release/riela"),
                cwd.join(".build/debug/riela"),
                PathBuf::from("/opt/homebrew/bin/riela"),
                PathBuf::from("/usr/local/bin/riela"),
            ],
        }
    }
}

/// Resolves the `riela` binary: explicit override first, then `PATH`, then the
/// well-known development and Homebrew locations.
pub fn resolve_riela_binary(
    lookup: &BinaryLookup,
    exists: impl Fn(&Path) -> bool,
) -> Option<PathBuf> {
    if let Some(override_path) = &lookup.env_override {
        return exists(override_path).then(|| override_path.clone());
    }
    lookup
        .path_entries
        .iter()
        .map(|entry| entry.join("riela"))
        .chain(lookup.fallback_candidates.iter().cloned())
        .find(|candidate| exists(candidate))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loopback_origin_is_explicit_ipv4() {
        assert_eq!(loopback_origin(8787), "http://127.0.0.1:8787");
    }

    #[test]
    fn parses_the_supported_loopback_hosts() {
        assert_eq!(
            parse_loopback_origin("http://127.0.0.1:8787").unwrap(),
            8787
        );
        assert_eq!(
            parse_loopback_origin("http://localhost:19091").unwrap(),
            19091
        );
        assert_eq!(parse_loopback_origin("http://[::1]:4000").unwrap(), 4000);
        assert_eq!(
            parse_loopback_origin("  http://127.0.0.1:8787/  ").unwrap(),
            8787
        );
    }

    #[test]
    fn rejects_non_loopback_origins() {
        for raw in [
            "https://127.0.0.1:8787",
            "http://example.com:8787",
            "http://10.0.0.5:8787",
            "http://127.0.0.1:8787/api",
            "http://127.0.0.1",
            "http://localhost",
            "http://127.0.0.1:0",
            "http://127.0.0.1:99999",
            "127.0.0.1:8787",
            "",
        ] {
            assert!(
                parse_loopback_origin(raw).is_err(),
                "expected {raw:?} to be rejected"
            );
        }
    }

    #[test]
    fn accepts_relative_dashboard_paths() {
        for path in [
            "/api/v1/bootstrap",
            "/api/v1/instances?limit=20",
            "/graphql",
            "/api/v1/runs/abc%2Fdef",
            "/api/v1/x#fragment",
        ] {
            assert!(
                validate_relative_path(path).is_ok(),
                "expected {path:?} to be accepted"
            );
        }
    }

    #[test]
    fn rejects_escaping_paths() {
        for path in [
            "//evil.example.com/api",
            "http://evil.example.com/api",
            "api/v1/bootstrap",
            "/api/../../etc/passwd",
            "/api/v1/boot strap",
            "/api/v1/\nbootstrap",
            "",
        ] {
            assert!(
                validate_relative_path(path).is_err(),
                "expected {path:?} to be rejected"
            );
        }
    }

    fn header(name: &str, value: &str) -> (String, String) {
        (name.to_string(), value.to_string())
    }

    #[test]
    fn keeps_riela_headers_and_drops_webview_context() {
        let incoming = vec![
            header("Content-Type", "application/json"),
            header("X-Riela-CSRF", "token-1"),
            header("X-Riela-Profile", "default"),
            header("Host", "tauri.localhost"),
            header("Origin", "tauri://localhost"),
            header("Cookie", "session=1"),
            header("Sec-Fetch-Mode", "cors"),
            header("Referer", "tauri://localhost/"),
            header("Connection", "keep-alive"),
            header("Content-Length", "42"),
            header("Proxy-Authorization", "Basic x"),
        ];

        let headers = outbound_headers("POST", "http://127.0.0.1:19091", &incoming);

        assert!(headers.contains(&header("Content-Type", "application/json")));
        assert!(headers.contains(&header("X-Riela-CSRF", "token-1")));
        assert!(headers.contains(&header("X-Riela-Profile", "default")));
        for dropped in [
            "Host",
            "Cookie",
            "Sec-Fetch-Mode",
            "Referer",
            "Connection",
            "Content-Length",
            "Proxy-Authorization",
        ] {
            assert!(
                !headers.iter().any(|(name, _)| name == dropped),
                "expected {dropped} to be dropped"
            );
        }
        assert_eq!(
            headers
                .iter()
                .filter(|(name, _)| name == "Origin")
                .collect::<Vec<_>>(),
            vec![&header("Origin", "http://127.0.0.1:19091")],
        );
    }

    #[test]
    fn stamps_origin_only_for_state_changing_methods() {
        let incoming = vec![header("X-Riela-CSRF", "token-1")];
        for method in ["POST", "put", "DELETE", "patch"] {
            let headers = outbound_headers(method, "http://127.0.0.1:8787", &incoming);
            assert!(
                headers.contains(&header("Origin", "http://127.0.0.1:8787")),
                "expected {method} to carry an Origin"
            );
        }
        for method in ["GET", "head", "OPTIONS"] {
            let headers = outbound_headers(method, "http://127.0.0.1:8787", &incoming);
            assert!(
                !headers.iter().any(|(name, _)| name == "Origin"),
                "expected {method} to omit Origin"
            );
        }
    }

    #[test]
    fn binary_lookup_reads_path_and_fallbacks_from_the_environment() {
        let lookup = BinaryLookup::from_environment(
            Path::new("/work/riela"),
            None,
            Some(OsString::from("/usr/bin:/opt/bin")),
        );
        assert_eq!(
            lookup.path_entries,
            vec![PathBuf::from("/usr/bin"), PathBuf::from("/opt/bin")]
        );
        assert_eq!(
            lookup.fallback_candidates,
            vec![
                PathBuf::from("/work/riela/.build/release/riela"),
                PathBuf::from("/work/riela/.build/debug/riela"),
                PathBuf::from("/opt/homebrew/bin/riela"),
                PathBuf::from("/usr/local/bin/riela"),
            ]
        );
    }

    #[test]
    fn resolves_the_override_before_anything_else() {
        let lookup = BinaryLookup {
            env_override: Some(PathBuf::from("/custom/riela")),
            path_entries: vec![PathBuf::from("/usr/bin")],
            fallback_candidates: vec![PathBuf::from("/opt/homebrew/bin/riela")],
        };
        assert_eq!(
            resolve_riela_binary(&lookup, |_| true),
            Some(PathBuf::from("/custom/riela"))
        );
    }

    #[test]
    fn a_missing_override_is_not_silently_replaced_by_a_path_hit() {
        let lookup = BinaryLookup {
            env_override: Some(PathBuf::from("/nonexistent/riela")),
            path_entries: vec![PathBuf::from("/usr/bin")],
            fallback_candidates: vec![PathBuf::from("/opt/homebrew/bin/riela")],
        };
        // Everything except the override exists, yet the lookup still fails:
        // an explicit RIELA_DESKTOP_RIELA_BIN must never fall through silently.
        assert_eq!(
            resolve_riela_binary(&lookup, |path| path != Path::new("/nonexistent/riela")),
            None
        );
    }

    #[test]
    fn falls_back_from_path_to_well_known_locations() {
        let lookup = BinaryLookup {
            env_override: None,
            path_entries: vec![PathBuf::from("/usr/bin"), PathBuf::from("/opt/bin")],
            fallback_candidates: vec![
                PathBuf::from("/work/.build/release/riela"),
                PathBuf::from("/opt/homebrew/bin/riela"),
            ],
        };

        assert_eq!(
            resolve_riela_binary(&lookup, |path| path == Path::new("/opt/bin/riela")),
            Some(PathBuf::from("/opt/bin/riela"))
        );
        assert_eq!(
            resolve_riela_binary(&lookup, |path| path == Path::new("/opt/homebrew/bin/riela")),
            Some(PathBuf::from("/opt/homebrew/bin/riela"))
        );
        assert_eq!(resolve_riela_binary(&lookup, |_| false), None);
    }
}
