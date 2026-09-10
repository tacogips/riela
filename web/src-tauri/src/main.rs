mod startup_window;

use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    io::{self, BufRead, Read, Write},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use tauri::Manager;
use tokio::sync::oneshot;

#[derive(Deserialize, Serialize)]
struct Request {
    method: String,
    path: String,
    headers: HashMap<String, String>,
    body: String,
}

#[derive(Deserialize, Serialize)]
struct Response {
    status: u16,
    headers: HashMap<String, String>,
    body: String,
}

#[derive(Deserialize)]
struct Reply {
    id: u64,
    response: Response,
}

#[derive(Default)]
struct Bridge {
    sequence: AtomicU64,
    pending: Mutex<HashMap<u64, oneshot::Sender<Response>>>,
}

#[tauri::command]
async fn riela_request(
    request: Request,
    state: tauri::State<'_, Arc<Bridge>>,
) -> Result<Response, String> {
    if !(request.path.starts_with("/api/v1/") || request.path == "/graphql")
        || request.body.len() > 8 * 1024 * 1024
    {
        return Err("Unsupported Riela request".into());
    }
    let id = state.sequence.fetch_add(1, Ordering::Relaxed);
    let (send, receive) = oneshot::channel();
    state
        .pending
        .lock()
        .map_err(|e| e.to_string())?
        .insert(id, send);
    let message = serde_json::json!({ "id": id, "request": request });
    let write_result = (|| -> io::Result<()> {
        let mut out = io::stdout().lock();
        serde_json::to_writer(&mut out, &message)?;
        out.write_all(b"\n")?;
        out.flush()
    })();
    if let Err(error) = write_result {
        state.pending.lock().map_err(|e| e.to_string())?.remove(&id);
        return Err(error.to_string());
    }
    let result = tokio::time::timeout(Duration::from_secs(120), receive).await;
    state.pending.lock().map_err(|e| e.to_string())?.remove(&id);
    result
        .map_err(|_| "Riela request timed out".to_string())?
        .map_err(|_| "Riela host disconnected".to_string())
}

fn main() {
    if std::env::var("RIELA_DESKTOP_IPC").as_deref() != Ok("stdio") {
        eprintln!("Open this window from RielaApp. It requires the Riela host IPC connection.");
        std::process::exit(2);
    }
    let bridge = Arc::new(Bridge::default());
    let reader_bridge = bridge.clone();
    tauri::Builder::default()
        .manage(bridge)
        .invoke_handler(tauri::generate_handler![riela_request])
        .setup(move |app| {
            if let Some(window) = app.get_webview_window("main") {
                tauri::async_runtime::spawn_blocking(move || {
                    if let Err(error) = startup_window::clamp_main_window_to_work_area(&window) {
                        eprintln!("Could not fit the Riela window: {error}");
                    }
                    if let Err(error) = window.show() {
                        eprintln!("Could not show the Riela window: {error}");
                    }
                    if let Err(error) = window.set_focus() {
                        eprintln!("Could not focus the Riela window: {error}");
                    }
                });
            }
            let handle = app.handle().clone();
            std::thread::spawn(move || {
                let mut input = io::stdin().lock();
                loop {
                    let mut line = String::new();
                    // Bound frames before allocating the entire response.
                    let read = (&mut input).take(32 * 1024 * 1024).read_line(&mut line);
                    match read {
                        Ok(0) | Err(_) => break,
                        Ok(_) if !line.ends_with('\n') => break,
                        _ => {}
                    }
                    if let Ok(reply) = serde_json::from_str::<Reply>(&line) {
                        if let Ok(mut pending) = reader_bridge.pending.lock() {
                            if let Some(sender) = pending.remove(&reply.id) {
                                let _ = sender.send(reply.response);
                            }
                        }
                    } else if let Ok(value) = serde_json::from_str::<serde_json::Value>(&line) {
                        if value["action"] == "show" {
                            if let Some(window) = handle.get_webview_window("main") {
                                let _ = window.show();
                                let _ = window.unminimize();
                                let _ = window.set_focus();
                            }
                        }
                    }
                }
                handle.exit(0);
            });
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("Riela desktop runtime failed");
}
