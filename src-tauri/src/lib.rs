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

/// Terminates a spawned `riela serve` when the shell — not the user interface —
/// ends the app, e.g. Ctrl-C on `mise run desktop:dev`. Tauri's `RunEvent::Exit`
/// only fires for a real quit, so without this a managed child would outlive it.
///
/// The signals are blocked before Tauri starts any threads (blocking is
/// inherited), then consumed by one dedicated thread through `sigwait`, which
/// keeps the shutdown work off the async-signal-safe path.
#[cfg(unix)]
fn install_signal_shutdown(lifecycle: Arc<ServerLifecycle>) {
    // SAFETY: plain libc signal-mask calls on a freshly zeroed `sigset_t`,
    // performed on the main thread before any other thread exists.
    unsafe {
        let mut signals: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut signals);
        for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
            libc::sigaddset(&mut signals, signal);
        }
        if libc::pthread_sigmask(libc::SIG_BLOCK, &signals, std::ptr::null_mut()) != 0 {
            return;
        }
        std::thread::spawn(move || {
            let mut received: libc::c_int = 0;
            if libc::sigwait(&signals, &mut received) == 0 {
                lifecycle.shutdown();
                std::process::exit(128 + received);
            }
        });
    }
}

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

    #[cfg(unix)]
    install_signal_shutdown(lifecycle.clone());

    let setup_lifecycle = lifecycle.clone();
    let shutdown_lifecycle = lifecycle.clone();

    tauri::Builder::default()
        .manage(AppState::new(lifecycle))
        .invoke_handler(tauri::generate_handler![
            commands::riela_fetch,
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
            // `Exit` only, not `ExitRequested`: the latter fires before exit is
            // committed and can be prevented, which would kill the managed
            // `riela serve` while the app keeps running.
            if matches!(event, tauri::RunEvent::Exit) {
                // Only a server this process started is terminated.
                shutdown_lifecycle.shutdown();
            }
        });
}
