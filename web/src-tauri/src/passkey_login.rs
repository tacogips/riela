use reqwest::Url;

fn login_url(endpoint: &str, device_id: &str) -> Result<Url, String> {
    let (_, origin) = crate::remote::target(endpoint, "/api/v1/auth/status")?;
    let mut url = Url::parse(&origin).map_err(|_| "Invalid server origin")?;
    if url.scheme() != "https"
        && !matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"))
    {
        return Err("Passkeys require HTTPS for remote servers".into());
    }
    if device_id.len() != 43
        || !device_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    {
        return Err("Invalid desktop login identifier".into());
    }
    url.set_fragment(Some(&format!("/auth/device/{device_id}")));
    Ok(url)
}

#[tauri::command]
pub async fn riela_open_passkey_login(endpoint: String, device_id: String) -> Result<(), String> {
    let url = login_url(&endpoint, &device_id)?;
    tauri::async_runtime::spawn_blocking(move || {
        #[cfg(target_os = "macos")]
        let mut command = std::process::Command::new("/usr/bin/open");
        #[cfg(target_os = "windows")]
        let mut command = std::process::Command::new("explorer.exe");
        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        let mut command = std::process::Command::new("xdg-open");
        let status = command
            .arg(url.as_str())
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map_err(|_| "Could not open the system browser".to_string())?;
        if status.success() {
            Ok(())
        } else {
            Err("Could not open the system browser".into())
        }
    })
    .await
    .map_err(|_| "Browser launcher failed".to_string())?
}

#[cfg(test)]
mod tests {
    use super::login_url;

    #[test]
    fn opens_only_https_server_login_with_an_opaque_device_id() {
        let id = "A".repeat(43);
        assert_eq!(
            login_url("https://riela.example", &id).unwrap().as_str(),
            format!("https://riela.example/#/auth/device/{id}")
        );
        assert!(login_url("http://remote.example", &id).is_err());
        assert!(login_url("http://127.0.0.1:8787", &id).is_ok());
        for id in ["--help", "../evil", "token?secret", "https://evil.example"] {
            assert!(login_url("https://riela.example", id).is_err());
        }
    }
}
