//! Riela Dashboard — the desktop shell around the shared `web/` SPA.
//!
//! The window loads the same bundle the browser serves; the only difference is
//! that its HTTP requests are executed by this process (see [`commands`]) so
//! Riela's loopback `Host`/`Origin`/CSRF rules are satisfied.

pub mod commands;
pub mod endpoint;
pub mod lifecycle;

use std::sync::Arc;

use commands::AppState;
use lifecycle::{LifecycleConfig, ProcessSpawner, ReqwestProber, ServerLifecycle};

pub fn run() {
    let cwd = std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."));
    let config = LifecycleConfig::from_environment(
        &cwd,
        std::env::var_os("RIELA_DESKTOP_SERVER_URL"),
        std::env::var_os("RIELA_DESKTOP_RIELA_BIN"),
        std::env::var_os("PATH"),
    );
    let lifecycle = ServerLifecycle::new(
        config,
        Arc::new(ReqwestProber::default()),
        Arc::new(ProcessSpawner),
    );

    let setup_lifecycle = lifecycle.clone();
    let shutdown_lifecycle = lifecycle.clone();

    tauri::Builder::default()
        .manage(AppState::new(lifecycle))
        .invoke_handler(tauri::generate_handler![
            commands::riela_fetch,
            commands::riela_server_status,
            commands::riela_server_retry
        ])
        .setup(move |_app| {
            // Discovery runs alongside the first paint so the SPA can render its
            // "Connecting to Riela…" state instead of a blank window.
            let lifecycle = setup_lifecycle.clone();
            tauri::async_runtime::spawn(async move { lifecycle.discover().await });
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("failed to build Riela Dashboard")
        .run(move |_handle, event| {
            if matches!(
                event,
                tauri::RunEvent::Exit | tauri::RunEvent::ExitRequested { .. }
            ) {
                // Only a server this process started is terminated.
                shutdown_lifecycle.shutdown();
            }
        });
}
