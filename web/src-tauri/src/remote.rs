use crate::{Request, Response};
use base64::{engine::general_purpose::STANDARD, Engine};
use reqwest::{redirect::Policy, Client, Method, Url};
use std::time::Duration;

pub(super) fn target(endpoint: &str, path: &str) -> Result<(Url, String), String> {
    let origin = Url::parse(endpoint).map_err(|_| "Invalid server origin")?;
    if !matches!(origin.scheme(), "http" | "https")
        || origin.host_str().is_none()
        || !origin.username().is_empty()
        || origin.password().is_some()
        || origin.path() != "/"
        || origin.query().is_some()
        || origin.fragment().is_some()
    {
        return Err("Use an HTTP(S) server origin without a path or credentials".into());
    }
    let url = origin.join(path).map_err(|_| "Invalid API path")?;
    if !path.starts_with('/')
        || url.origin() != origin.origin()
        || url.fragment().is_some()
        || !(url.path().starts_with("/api/v1/") || url.path() == "/graphql")
    {
        return Err("Only Riela API paths are supported".into());
    }
    Ok((url, origin.origin().ascii_serialization()))
}

#[tauri::command]
pub async fn riela_remote_request(endpoint: String, request: Request) -> Result<Response, String> {
    let (url, origin) = target(&endpoint, &request.path)?;
    if request.body.len() > 8 * 1024 * 1024 {
        return Err("Request exceeds size limit".into());
    }
    let method = Method::from_bytes(request.method.as_bytes()).map_err(|_| "Invalid method")?;
    let client = Client::builder()
        .redirect(Policy::none())
        .timeout(Duration::from_secs(120))
        .connect_timeout(Duration::from_secs(15))
        .build()
        .map_err(|error| error.to_string())?;
    let mut outgoing = client.request(method, url).header("Origin", origin);
    for (name, value) in request.headers {
        if matches!(
            name.to_ascii_lowercase().as_str(),
            "authorization" | "content-type" | "accept" | "x-riela-csrf" | "x-riela-profile"
        ) {
            outgoing = outgoing.header(name, value);
        }
    }
    let mut incoming = outgoing
        .body(request.body)
        .send()
        .await
        .map_err(|error| error.to_string())?;
    if incoming.status().is_redirection() {
        return Err("Server redirects are not supported; enter the final server origin".into());
    }
    let status = incoming.status().as_u16();
    let headers = incoming
        .headers()
        .iter()
        .filter_map(|(name, value)| {
            value
                .to_str()
                .ok()
                .map(|value| (name.to_string(), value.to_string()))
        })
        .collect();
    let mut body = Vec::new();
    while let Some(chunk) = incoming.chunk().await.map_err(|error| error.to_string())? {
        if body.len() + chunk.len() > 24 * 1024 * 1024 {
            return Err("Response exceeds size limit".into());
        }
        body.extend_from_slice(&chunk);
    }
    Ok(Response {
        status,
        headers,
        body: STANDARD.encode(body),
    })
}

#[cfg(test)]
mod tests {
    use super::target;

    #[test]
    fn remote_http_preserves_auth_csrf_and_rejects_redirects() {
        use std::io::{Read, Write};
        use std::net::TcpListener;
        for status in [200, 401, 302] {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let endpoint = format!("http://{}", listener.local_addr().unwrap());
            let expected_origin = endpoint.clone();
            let server = std::thread::spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(std::time::Duration::from_secs(10)))
                    .unwrap();
                let mut bytes = Vec::new();
                let mut buffer = [0; 1024];
                while !bytes.windows(4).any(|part| part == b"\r\n\r\n") {
                    let count = stream.read(&mut buffer).unwrap();
                    assert!(count > 0);
                    bytes.extend_from_slice(&buffer[..count]);
                }
                let headers = String::from_utf8(bytes).unwrap().to_lowercase();
                assert!(headers.starts_with("post /graphql http/1.1"));
                assert!(headers.contains("authorization: bearer test-token\r\n"));
                assert!(headers.contains("x-riela-csrf: test-csrf\r\n"));
                assert!(headers.contains(&format!("origin: {expected_origin}\r\n")));
                assert!(!headers.contains("cookie:"));
                write!(stream, "HTTP/1.1 {status} Test\r\nContent-Length: 2\r\nContent-Type: application/json\r\nLocation: http://127.0.0.1:1/graphql\r\nConnection: close\r\n\r\n{{}}").unwrap();
            });
            let request = crate::Request {
                method: "POST".into(),
                path: "/graphql".into(),
                body: String::new(),
                headers: [
                    ("authorization".into(), "Bearer test-token".into()),
                    ("x-riela-csrf".into(), "test-csrf".into()),
                    ("cookie".into(), "local-secret=value".into()),
                ]
                .into(),
            };
            let result = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap()
                .block_on(super::riela_remote_request(endpoint, request));
            server.join().unwrap();
            if status == 302 {
                assert!(result.err().unwrap().contains("redirects"));
            } else {
                let response = result.unwrap();
                assert_eq!(response.status, status);
                assert_eq!(response.body, "e30=");
            }
        }
    }

    #[test]
    fn restricts_requests_to_selected_server_api() {
        let (url, origin) = target(
            "https://riela.example",
            "/api/v1/instances/a%2Fb?revision=2",
        )
        .unwrap();
        assert_eq!(
            url.as_str(),
            "https://riela.example/api/v1/instances/a%2Fb?revision=2"
        );
        assert_eq!(origin, "https://riela.example");
        for path in [
            "//evil.test/graphql",
            "/api/v1/../../secret",
            "/secret",
            "https://evil.test/graphql",
        ] {
            assert!(target("https://riela.example", path).is_err());
        }
        for endpoint in [
            "file:///tmp",
            "https://user:token@riela.example",
            "https://riela.example/path",
            "https://riela.example?token=x",
        ] {
            assert!(target(endpoint, "/graphql").is_err());
        }
    }
}
