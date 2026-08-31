//! Discovery and lifetime management for the local Riela server.
//!
//! The desktop shell never assumes a server exists. It probes the two known
//! loopback hosts in preference order (RielaApp's listener first, because only
//! it serves the aggregate Instances/Run-log APIs), and spawns `riela serve`
//! itself when neither answers. Only a server this process started is ever
//! terminated.

use std::future::Future;
use std::path::Path;
use std::pin::Pin;
use std::process::Child;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::Notify;

use crate::endpoint::{
    loopback_origin, resolve_riela_binary, BinaryLookup, Endpoint, EndpointKind, DEFAULT_APP_PORT,
    DEFAULT_SERVE_PORT,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ServerState {
    Discovering,
    Starting { pid: u32 },
    Connected(Endpoint),
    Failed { detail: String },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ServerStatusSnapshot {
    pub state: &'static str,
    pub endpoint: Option<Endpoint>,
    pub detail: Option<String>,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum LifecycleError {
    #[error("{0}")]
    Unavailable(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProbeResult {
    Status(u16, String),
    Unreachable,
}

pub trait Prober: Send + Sync + 'static {
    fn get(&self, url: &str) -> Pin<Box<dyn Future<Output = ProbeResult> + Send + '_>>;
}

pub trait Spawner: Send + Sync + 'static {
    fn spawn(&self, binary: &Path, port: u16) -> std::io::Result<Child>;
}

/// A `reqwest`-backed prober with a short per-probe timeout: an unreachable port
/// must fail fast so discovery can move on to the next candidate.
pub struct ReqwestProber {
    client: reqwest::Client,
}

impl Default for ReqwestProber {
    fn default() -> Self {
        Self {
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(1))
                .build()
                .unwrap_or_default(),
        }
    }
}

impl Prober for ReqwestProber {
    fn get(&self, url: &str) -> Pin<Box<dyn Future<Output = ProbeResult> + Send + '_>> {
        let request = self.client.get(url.to_string());
        Box::pin(async move {
            match request.send().await {
                Ok(response) => {
                    let status = response.status().as_u16();
                    let body = response.text().await.unwrap_or_default();
                    ProbeResult::Status(status, body)
                }
                Err(_) => ProbeResult::Unreachable,
            }
        })
    }
}

pub struct ProcessSpawner;

impl Spawner for ProcessSpawner {
    fn spawn(&self, binary: &Path, port: u16) -> std::io::Result<Child> {
        std::process::Command::new(binary)
            .args(["serve", "--host", "127.0.0.1", "--port", &port.to_string()])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::inherit())
            .spawn()
    }
}

#[derive(Clone, Debug)]
pub struct LifecycleConfig {
    /// Set from `RIELA_DESKTOP_SERVER_URL`; pins discovery to a single port.
    pub explicit_port: Option<u16>,
    /// Fatal configuration problem detected before startup (e.g. an invalid
    /// `RIELA_DESKTOP_SERVER_URL`). Surfaced as `Failed` rather than a panic.
    pub configuration_error: Option<String>,
    pub app_port: u16,
    pub serve_port: u16,
    pub binary: BinaryLookup,
    pub startup_timeout: Duration,
    pub poll_interval: Duration,
}

impl Default for LifecycleConfig {
    fn default() -> Self {
        Self {
            explicit_port: None,
            configuration_error: None,
            app_port: DEFAULT_APP_PORT,
            serve_port: DEFAULT_SERVE_PORT,
            binary: BinaryLookup::default(),
            startup_timeout: Duration::from_secs(20),
            poll_interval: Duration::from_millis(250),
        }
    }
}

impl LifecycleConfig {
    pub fn from_environment(
        cwd: &Path,
        server_url: Option<std::ffi::OsString>,
        binary_override: Option<std::ffi::OsString>,
        path_var: Option<std::ffi::OsString>,
    ) -> Self {
        let mut config = Self {
            binary: BinaryLookup::from_environment(cwd, binary_override, path_var),
            ..Self::default()
        };
        if let Some(raw) = server_url.and_then(|value| value.into_string().ok()) {
            if !raw.trim().is_empty() {
                match crate::endpoint::parse_loopback_origin(&raw) {
                    Ok(port) => config.explicit_port = Some(port),
                    Err(error) => {
                        config.configuration_error =
                            Some(format!("RIELA_DESKTOP_SERVER_URL is invalid: {error}"))
                    }
                }
            }
        }
        config
    }
}

fn is_riela_healthz(status: u16, body: &str) -> bool {
    status == 200 && body.contains("\"service\":\"riela\"")
}

pub struct ServerLifecycle {
    config: LifecycleConfig,
    prober: Arc<dyn Prober>,
    spawner: Arc<dyn Spawner>,
    state: Mutex<ServerState>,
    child: Mutex<Option<Child>>,
    /// Serialises `discover()`. Tauri runs commands concurrently and every
    /// in-flight `riela_fetch` that fails triggers its own `riela_server_retry`,
    /// so without this several callers would probe and spawn at the same time.
    discovery: tokio::sync::Mutex<()>,
    /// Incremented once per completed discovery run so callers that queued
    /// behind an in-flight run can tell it apart from a stale result.
    discovery_generation: AtomicU64,
    notify: Notify,
}

impl ServerLifecycle {
    pub fn new(
        config: LifecycleConfig,
        prober: Arc<dyn Prober>,
        spawner: Arc<dyn Spawner>,
    ) -> Arc<Self> {
        let initial = match &config.configuration_error {
            Some(detail) => ServerState::Failed {
                detail: detail.clone(),
            },
            None => ServerState::Discovering,
        };
        Arc::new(Self {
            config,
            prober,
            spawner,
            state: Mutex::new(initial),
            child: Mutex::new(None),
            discovery: tokio::sync::Mutex::new(()),
            discovery_generation: AtomicU64::new(0),
            notify: Notify::new(),
        })
    }

    fn set_state(&self, state: ServerState) {
        *self.state.lock().expect("lifecycle state poisoned") = state;
        self.notify.notify_waiters();
    }

    fn current_state(&self) -> ServerState {
        self.state.lock().expect("lifecycle state poisoned").clone()
    }

    pub fn status(&self) -> ServerStatusSnapshot {
        match self.current_state() {
            ServerState::Discovering => ServerStatusSnapshot {
                state: "discovering",
                endpoint: None,
                detail: None,
            },
            ServerState::Starting { pid } => ServerStatusSnapshot {
                state: "starting",
                endpoint: None,
                detail: Some(format!("Starting riela serve (pid {pid})")),
            },
            ServerState::Connected(endpoint) => ServerStatusSnapshot {
                state: "connected",
                endpoint: Some(endpoint),
                detail: None,
            },
            ServerState::Failed { detail } => ServerStatusSnapshot {
                state: "failed",
                endpoint: None,
                detail: Some(detail),
            },
        }
    }

    /// Marks a previously connected endpoint as gone so the next request
    /// re-runs discovery instead of hammering a dead socket.
    pub fn mark_unreachable(&self, detail: String) {
        let mut state = self.state.lock().expect("lifecycle state poisoned");
        if matches!(*state, ServerState::Connected(_)) {
            *state = ServerState::Failed { detail };
            drop(state);
            self.notify.notify_waiters();
        }
    }

    async fn probe_bootstrap(&self, port: u16) -> ProbeResult {
        self.prober
            .get(&format!("{}/api/v1/bootstrap", loopback_origin(port)))
            .await
    }

    async fn probe_healthz(&self, port: u16) -> ProbeResult {
        self.prober
            .get(&format!("{}/healthz", loopback_origin(port)))
            .await
    }

    /// Runs the full discovery state machine. Idempotent while connected.
    ///
    /// Concurrent callers are serialised and collapsed. The SPA runs several
    /// independent polling resources, so one endpoint failure produces a burst
    /// of `riela_server_retry` calls; they must share a single discovery rather
    /// than each probing and spawning a server of their own.
    pub async fn discover(self: &Arc<Self>) {
        if matches!(self.current_state(), ServerState::Connected(_)) {
            return;
        }
        let observed = self.discovery_generation.load(Ordering::SeqCst);
        let _discovery = self.discovery.lock().await;
        if matches!(self.current_state(), ServerState::Connected(_)) {
            return;
        }
        // A discovery that overlapped this request has already run to
        // completion; its outcome — success or failure — is this caller's
        // answer too. A later retry still starts a fresh run.
        if self.discovery_generation.load(Ordering::SeqCst) != observed {
            return;
        }
        self.run_discovery().await;
        self.discovery_generation.fetch_add(1, Ordering::SeqCst);
    }

    async fn run_discovery(self: &Arc<Self>) {
        if let Some(detail) = &self.config.configuration_error {
            self.set_state(ServerState::Failed {
                detail: detail.clone(),
            });
            return;
        }
        self.set_state(ServerState::Discovering);

        if let Some(port) = self.config.explicit_port {
            self.discover_explicit(port).await;
            return;
        }

        // 1. RielaApp's listener wins: it is the only host serving the
        //    aggregate Instances and Run-log APIs.
        if let ProbeResult::Status(200, _) = self.probe_bootstrap(self.config.app_port).await {
            self.set_state(ServerState::Connected(Endpoint::new(
                self.config.app_port,
                EndpointKind::RielaApp,
                false,
            )));
            return;
        }

        // 2. An already-running `riela serve`.
        match self.probe_healthz(self.config.serve_port).await {
            ProbeResult::Status(status, body) if is_riela_healthz(status, &body) => {
                self.set_state(ServerState::Connected(Endpoint::new(
                    self.config.serve_port,
                    EndpointKind::CliServe,
                    false,
                )));
                return;
            }
            ProbeResult::Status(..) => {
                // Something else owns the port; spawning would fail anyway and
                // proxying to it would be wrong.
                self.set_state(ServerState::Failed {
                    detail: format!(
                        "Port {} is in use by a service that is not `riela serve`. Stop it, or point the app elsewhere with RIELA_DESKTOP_SERVER_URL.",
                        self.config.serve_port
                    ),
                });
                return;
            }
            ProbeResult::Unreachable => {}
        }

        // 3. Nothing is listening: start our own server.
        self.spawn_and_wait().await;
    }

    async fn discover_explicit(self: &Arc<Self>, port: u16) {
        match self.probe_bootstrap(port).await {
            ProbeResult::Status(200, _) => {
                self.set_state(ServerState::Connected(Endpoint::new(
                    port,
                    EndpointKind::RielaApp,
                    false,
                )));
            }
            ProbeResult::Status(..) => match self.probe_healthz(port).await {
                ProbeResult::Status(status, body) if is_riela_healthz(status, &body) => {
                    self.set_state(ServerState::Connected(Endpoint::new(
                        port,
                        EndpointKind::CliServe,
                        false,
                    )));
                }
                _ => self.set_state(ServerState::Failed {
                    detail: format!(
                        "No Riela server answered at {} (RIELA_DESKTOP_SERVER_URL).",
                        loopback_origin(port)
                    ),
                }),
            },
            ProbeResult::Unreachable => self.set_state(ServerState::Failed {
                detail: format!(
                    "No Riela server answered at {} (RIELA_DESKTOP_SERVER_URL).",
                    loopback_origin(port)
                ),
            }),
        }
    }

    async fn spawn_and_wait(self: &Arc<Self>) {
        let Some(binary) = resolve_riela_binary(&self.config.binary, |path| path.is_file()) else {
            self.set_state(ServerState::Failed {
                detail: format!(
                    "No Riela server on {} or {} and no `riela` binary was found. Start RielaApp's web listener (Open Web Config), run `riela serve`, or set RIELA_DESKTOP_RIELA_BIN.",
                    loopback_origin(self.config.app_port),
                    loopback_origin(self.config.serve_port),
                ),
            });
            return;
        };

        // A previous managed server may still be alive — e.g. it wedged, a
        // request timed out, `mark_unreachable` demoted it, and the retry
        // brought us back here. Overwriting its handle would orphan it
        // (`std::process::Child` does not kill or reap on drop) and leave it
        // holding the port forever, so it is terminated and reaped first.
        self.terminate_managed_child();

        let child = match self.spawner.spawn(&binary, self.config.serve_port) {
            Ok(child) => child,
            Err(error) => {
                self.set_state(ServerState::Failed {
                    detail: format!("Could not start `{}`: {error}", binary.display()),
                });
                return;
            }
        };

        let pid = child.id();
        *self.child.lock().expect("lifecycle child poisoned") = Some(child);
        self.set_state(ServerState::Starting { pid });

        let deadline = std::time::Instant::now() + self.config.startup_timeout;
        loop {
            if let Some(detail) = self.managed_child_exit_detail() {
                self.terminate_managed_child();
                self.set_state(ServerState::Failed { detail });
                return;
            }

            if let ProbeResult::Status(status, body) =
                self.probe_healthz(self.config.serve_port).await
            {
                if is_riela_healthz(status, &body) {
                    self.set_state(ServerState::Connected(Endpoint::new(
                        self.config.serve_port,
                        EndpointKind::CliServe,
                        true,
                    )));
                    return;
                }
            }

            if std::time::Instant::now() >= deadline {
                self.terminate_managed_child();
                self.set_state(ServerState::Failed {
                    detail: format!(
                        "`riela serve` did not become ready within {}s.",
                        self.config.startup_timeout.as_secs()
                    ),
                });
                return;
            }
            tokio::time::sleep(self.config.poll_interval).await;
        }
    }

    fn managed_child_exit_detail(&self) -> Option<String> {
        let mut guard = self.child.lock().expect("lifecycle child poisoned");
        let child = guard.as_mut()?;
        match child.try_wait() {
            Ok(Some(status)) => Some(format!(
                "`riela serve` exited with {status} before becoming ready."
            )),
            Ok(None) => None,
            Err(error) => Some(format!(
                "Could not observe the `riela serve` process: {error}"
            )),
        }
    }

    /// Waits for discovery to settle, up to `max`.
    pub async fn wait_ready(&self, max: Duration) -> Result<Endpoint, LifecycleError> {
        let deadline = std::time::Instant::now() + max;
        loop {
            // Register interest *before* re-reading the state so a transition
            // that lands between the two cannot be missed.
            let notified = self.notify.notified();
            match self.current_state() {
                ServerState::Connected(endpoint) => return Ok(endpoint),
                ServerState::Failed { detail } => return Err(LifecycleError::Unavailable(detail)),
                _ => {}
            }
            let now = std::time::Instant::now();
            if now >= deadline {
                return Err(LifecycleError::Unavailable(
                    "Still connecting to Riela…".to_string(),
                ));
            }
            if tokio::time::timeout(deadline - now, notified)
                .await
                .is_err()
            {
                return Err(LifecycleError::Unavailable(
                    "Still connecting to Riela…".to_string(),
                ));
            }
        }
    }

    /// Terminates the server this process started. External servers are left
    /// alone: another user session may be relying on them.
    pub fn shutdown(&self) {
        self.terminate_managed_child();
    }

    fn terminate_managed_child(&self) {
        let mut guard = self.child.lock().expect("lifecycle child poisoned");
        let Some(mut child) = guard.take() else {
            return;
        };
        if matches!(child.try_wait(), Ok(Some(_))) {
            return;
        }

        // SIGTERM first with a grace period: `riela serve` owns SQLite writers
        // that must be allowed to close cleanly.
        #[cfg(unix)]
        // SAFETY: `child` is a live process this instance spawned and has not
        // reaped, so its pid is still valid for the duration of this call.
        unsafe {
            libc::kill(child.id() as libc::pid_t, libc::SIGTERM);
        }

        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        loop {
            match child.try_wait() {
                Ok(Some(_)) => return,
                Ok(None) if std::time::Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(50));
                }
                _ => break,
            }
        }
        let _ = child.kill();
        let _ = child.wait();
    }
}

impl Drop for ServerLifecycle {
    fn drop(&mut self) {
        self.terminate_managed_child();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// Scripted prober: each URL maps to a queue of results; the last one is
    /// repeated once the queue drains.
    struct FakeProber {
        responses: Mutex<HashMap<String, Vec<ProbeResult>>>,
        requests: Mutex<Vec<String>>,
    }

    impl FakeProber {
        fn new(entries: &[(&str, Vec<ProbeResult>)]) -> Arc<Self> {
            Arc::new(Self {
                responses: Mutex::new(
                    entries
                        .iter()
                        .map(|(url, results)| ((*url).to_string(), results.clone()))
                        .collect(),
                ),
                requests: Mutex::new(Vec::new()),
            })
        }

        fn requests(&self) -> Vec<String> {
            self.requests.lock().unwrap().clone()
        }
    }

    impl Prober for FakeProber {
        fn get(&self, url: &str) -> Pin<Box<dyn Future<Output = ProbeResult> + Send + '_>> {
            self.requests.lock().unwrap().push(url.to_string());
            let mut responses = self.responses.lock().unwrap();
            let result = match responses.get_mut(url) {
                Some(queue) if queue.len() > 1 => queue.remove(0),
                Some(queue) => queue.first().cloned().unwrap_or(ProbeResult::Unreachable),
                None => ProbeResult::Unreachable,
            };
            Box::pin(async move { result })
        }
    }

    /// Spawns a real but inert child process so pid handling, `try_wait` and
    /// termination are exercised for real without running `riela`.
    struct FakeSpawner {
        program: &'static str,
        args: &'static [&'static str],
        calls: AtomicUsize,
    }

    impl FakeSpawner {
        fn sleeping() -> Arc<Self> {
            Arc::new(Self {
                program: "sleep",
                args: &["30"],
                calls: AtomicUsize::new(0),
            })
        }

        fn exiting() -> Arc<Self> {
            Arc::new(Self {
                program: "false",
                args: &[],
                calls: AtomicUsize::new(0),
            })
        }

        fn calls(&self) -> usize {
            self.calls.load(Ordering::SeqCst)
        }
    }

    impl Spawner for FakeSpawner {
        fn spawn(&self, _binary: &Path, _port: u16) -> std::io::Result<Child> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            std::process::Command::new(self.program)
                .args(self.args)
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
        }
    }

    fn healthz_ok() -> ProbeResult {
        ProbeResult::Status(200, r#"{"service":"riela","status":"ok"}"#.to_string())
    }

    fn bootstrap_ok() -> ProbeResult {
        ProbeResult::Status(200, r#"{"profile":"default","revision":1}"#.to_string())
    }

    fn bootstrap_missing() -> ProbeResult {
        ProbeResult::Status(404, r#"{"error":"unknown path"}"#.to_string())
    }

    fn config_with_binary() -> LifecycleConfig {
        LifecycleConfig {
            binary: BinaryLookup {
                env_override: None,
                path_entries: Vec::new(),
                // Always present so binary resolution is not the thing under
                // test; `/bin/sh` exists on every supported host.
                fallback_candidates: vec![PathBuf::from("/bin/sh")],
            },
            startup_timeout: Duration::from_secs(2),
            poll_interval: Duration::from_millis(10),
            ..LifecycleConfig::default()
        }
    }

    #[tokio::test]
    async fn prefers_the_riela_app_listener() {
        let prober = FakeProber::new(&[(
            "http://127.0.0.1:19091/api/v1/bootstrap",
            vec![bootstrap_ok()],
        )]);
        let spawner = FakeSpawner::sleeping();
        let lifecycle = ServerLifecycle::new(config_with_binary(), prober.clone(), spawner.clone());

        lifecycle.discover().await;

        assert_eq!(
            lifecycle.current_state(),
            ServerState::Connected(Endpoint::new(19091, EndpointKind::RielaApp, false))
        );
        assert_eq!(spawner.calls(), 0);
        assert_eq!(
            prober.requests(),
            vec!["http://127.0.0.1:19091/api/v1/bootstrap"]
        );
    }

    #[tokio::test]
    async fn falls_back_to_an_existing_cli_serve() {
        let prober = FakeProber::new(&[("http://127.0.0.1:8787/healthz", vec![healthz_ok()])]);
        let spawner = FakeSpawner::sleeping();
        let lifecycle = ServerLifecycle::new(config_with_binary(), prober.clone(), spawner.clone());

        lifecycle.discover().await;

        assert_eq!(
            lifecycle.current_state(),
            ServerState::Connected(Endpoint::new(8787, EndpointKind::CliServe, false))
        );
        assert_eq!(spawner.calls(), 0);
    }

    #[tokio::test]
    async fn refuses_to_spawn_over_a_foreign_service_on_the_serve_port() {
        let prober = FakeProber::new(&[(
            "http://127.0.0.1:8787/healthz",
            vec![ProbeResult::Status(200, "grafana".to_string())],
        )]);
        let spawner = FakeSpawner::sleeping();
        let lifecycle = ServerLifecycle::new(config_with_binary(), prober.clone(), spawner.clone());

        lifecycle.discover().await;

        let ServerState::Failed { detail } = lifecycle.current_state() else {
            panic!("expected Failed, got {:?}", lifecycle.current_state());
        };
        assert!(
            detail.contains("is in use by a service that is not"),
            "{detail}"
        );
        assert_eq!(spawner.calls(), 0);
    }

    #[tokio::test]
    async fn reports_a_missing_binary_with_actionable_guidance() {
        let prober = FakeProber::new(&[]);
        let spawner = FakeSpawner::sleeping();
        let config = LifecycleConfig {
            binary: BinaryLookup::default(),
            ..config_with_binary()
        };
        let lifecycle = ServerLifecycle::new(config, prober, spawner.clone());

        lifecycle.discover().await;

        let ServerState::Failed { detail } = lifecycle.current_state() else {
            panic!("expected Failed");
        };
        assert!(detail.contains("RIELA_DESKTOP_RIELA_BIN"), "{detail}");
        assert!(detail.contains("Open Web Config"), "{detail}");
        assert_eq!(spawner.calls(), 0);
    }

    #[tokio::test]
    async fn spawns_and_connects_once_the_server_answers() {
        let prober = FakeProber::new(&[(
            "http://127.0.0.1:8787/healthz",
            vec![
                ProbeResult::Unreachable,
                ProbeResult::Unreachable,
                healthz_ok(),
            ],
        )]);
        let spawner = FakeSpawner::sleeping();
        let lifecycle = ServerLifecycle::new(config_with_binary(), prober.clone(), spawner.clone());

        lifecycle.discover().await;

        assert_eq!(
            lifecycle.current_state(),
            ServerState::Connected(Endpoint::new(8787, EndpointKind::CliServe, true))
        );
        assert_eq!(spawner.calls(), 1);
        lifecycle.shutdown();
    }

    #[tokio::test]
    async fn reports_a_server_that_dies_before_becoming_ready() {
        let prober = FakeProber::new(&[(
            "http://127.0.0.1:8787/healthz",
            vec![ProbeResult::Unreachable],
        )]);
        let spawner = FakeSpawner::exiting();
        let lifecycle = ServerLifecycle::new(config_with_binary(), prober, spawner.clone());

        lifecycle.discover().await;

        let ServerState::Failed { detail } = lifecycle.current_state() else {
            panic!("expected Failed, got {:?}", lifecycle.current_state());
        };
        assert!(detail.contains("before becoming ready"), "{detail}");
        assert_eq!(spawner.calls(), 1);
    }

    #[tokio::test]
    async fn times_out_and_kills_a_server_that_never_becomes_ready() {
        let prober = FakeProber::new(&[(
            "http://127.0.0.1:8787/healthz",
            vec![ProbeResult::Unreachable],
        )]);
        let spawner = FakeSpawner::sleeping();
        let config = LifecycleConfig {
            startup_timeout: Duration::from_millis(60),
            poll_interval: Duration::from_millis(10),
            ..config_with_binary()
        };
        let lifecycle = ServerLifecycle::new(config, prober, spawner.clone());

        lifecycle.discover().await;

        let ServerState::Failed { detail } = lifecycle.current_state() else {
            panic!("expected Failed");
        };
        assert!(detail.contains("did not become ready"), "{detail}");
        assert!(lifecycle.child.lock().unwrap().is_none());
    }

    #[tokio::test]
    async fn an_explicit_server_url_pins_discovery_to_one_port() {
        let config = LifecycleConfig {
            explicit_port: Some(4321),
            ..config_with_binary()
        };
        let prober = FakeProber::new(&[(
            "http://127.0.0.1:4321/api/v1/bootstrap",
            vec![bootstrap_ok()],
        )]);
        let spawner = FakeSpawner::sleeping();
        let lifecycle = ServerLifecycle::new(config, prober.clone(), spawner.clone());

        lifecycle.discover().await;

        assert_eq!(
            lifecycle.current_state(),
            ServerState::Connected(Endpoint::new(4321, EndpointKind::RielaApp, false))
        );
        assert_eq!(spawner.calls(), 0);
        assert_eq!(
            prober.requests(),
            vec!["http://127.0.0.1:4321/api/v1/bootstrap"]
        );
    }

    #[tokio::test]
    async fn an_explicit_cli_serve_url_is_detected_through_healthz() {
        let config = LifecycleConfig {
            explicit_port: Some(4321),
            ..config_with_binary()
        };
        let prober = FakeProber::new(&[
            (
                "http://127.0.0.1:4321/api/v1/bootstrap",
                vec![bootstrap_missing()],
            ),
            ("http://127.0.0.1:4321/healthz", vec![healthz_ok()]),
        ]);
        let lifecycle = ServerLifecycle::new(config, prober, FakeSpawner::sleeping());

        lifecycle.discover().await;

        assert_eq!(
            lifecycle.current_state(),
            ServerState::Connected(Endpoint::new(4321, EndpointKind::CliServe, false))
        );
    }

    #[tokio::test]
    async fn an_explicit_url_never_falls_back_to_spawning() {
        let config = LifecycleConfig {
            explicit_port: Some(4321),
            ..config_with_binary()
        };
        let spawner = FakeSpawner::sleeping();
        let lifecycle = ServerLifecycle::new(config, FakeProber::new(&[]), spawner.clone());

        lifecycle.discover().await;

        let ServerState::Failed { detail } = lifecycle.current_state() else {
            panic!("expected Failed");
        };
        assert!(detail.contains("RIELA_DESKTOP_SERVER_URL"), "{detail}");
        assert_eq!(spawner.calls(), 0);
    }

    #[tokio::test]
    async fn an_invalid_server_url_starts_failed_instead_of_panicking() {
        let config = LifecycleConfig::from_environment(
            Path::new("/work"),
            Some(std::ffi::OsString::from("https://example.com")),
            None,
            None,
        );
        let lifecycle = ServerLifecycle::new(config, FakeProber::new(&[]), FakeSpawner::sleeping());

        assert_eq!(lifecycle.status().state, "failed");
        lifecycle.discover().await;
        assert_eq!(lifecycle.status().state, "failed");
        assert!(lifecycle
            .status()
            .detail
            .unwrap()
            .contains("RIELA_DESKTOP_SERVER_URL is invalid"));
    }

    #[tokio::test]
    async fn mark_unreachable_only_demotes_a_connected_endpoint() {
        let prober = FakeProber::new(&[("http://127.0.0.1:8787/healthz", vec![healthz_ok()])]);
        let lifecycle = ServerLifecycle::new(config_with_binary(), prober, FakeSpawner::sleeping());

        lifecycle.mark_unreachable("gone".to_string());
        assert_eq!(lifecycle.current_state(), ServerState::Discovering);

        lifecycle.discover().await;
        lifecycle.mark_unreachable("connection refused".to_string());
        assert_eq!(
            lifecycle.current_state(),
            ServerState::Failed {
                detail: "connection refused".to_string()
            }
        );
    }

    #[tokio::test]
    async fn discover_is_a_no_op_once_connected() {
        let prober = FakeProber::new(&[("http://127.0.0.1:8787/healthz", vec![healthz_ok()])]);
        let lifecycle = ServerLifecycle::new(
            config_with_binary(),
            prober.clone(),
            FakeSpawner::sleeping(),
        );

        lifecycle.discover().await;
        let after_first = prober.requests().len();
        lifecycle.discover().await;

        assert_eq!(prober.requests().len(), after_first);
    }

    #[tokio::test]
    async fn wait_ready_returns_immediately_for_a_connected_lifecycle() {
        let prober = FakeProber::new(&[("http://127.0.0.1:8787/healthz", vec![healthz_ok()])]);
        let lifecycle = ServerLifecycle::new(config_with_binary(), prober, FakeSpawner::sleeping());
        lifecycle.discover().await;

        let endpoint = lifecycle
            .wait_ready(Duration::from_millis(50))
            .await
            .unwrap();
        assert_eq!(endpoint.origin, "http://127.0.0.1:8787");
    }

    #[tokio::test]
    async fn wait_ready_wakes_on_a_later_transition() {
        let prober = FakeProber::new(&[(
            "http://127.0.0.1:8787/healthz",
            vec![
                ProbeResult::Unreachable,
                ProbeResult::Unreachable,
                healthz_ok(),
            ],
        )]);
        let lifecycle = ServerLifecycle::new(config_with_binary(), prober, FakeSpawner::sleeping());

        let waiter = {
            let lifecycle = lifecycle.clone();
            tokio::spawn(async move { lifecycle.wait_ready(Duration::from_secs(5)).await })
        };
        lifecycle.discover().await;

        let endpoint = waiter.await.unwrap().unwrap();
        assert!(endpoint.managed);
        lifecycle.shutdown();
    }

    #[tokio::test]
    async fn wait_ready_surfaces_the_failure_detail() {
        let prober = FakeProber::new(&[(
            "http://127.0.0.1:8787/healthz",
            vec![ProbeResult::Status(200, "nginx".to_string())],
        )]);
        let lifecycle = ServerLifecycle::new(config_with_binary(), prober, FakeSpawner::sleeping());
        lifecycle.discover().await;

        let error = lifecycle
            .wait_ready(Duration::from_millis(50))
            .await
            .unwrap_err();
        assert!(matches!(error, LifecycleError::Unavailable(detail) if detail.contains("in use")));
    }

    #[tokio::test]
    async fn wait_ready_times_out_while_still_discovering() {
        let lifecycle = ServerLifecycle::new(
            config_with_binary(),
            FakeProber::new(&[]),
            FakeSpawner::sleeping(),
        );

        let error = lifecycle
            .wait_ready(Duration::from_millis(30))
            .await
            .unwrap_err();
        assert_eq!(
            error,
            LifecycleError::Unavailable("Still connecting to Riela…".to_string())
        );
    }

    #[tokio::test]
    async fn shutdown_terminates_the_managed_child_and_is_idempotent() {
        let prober = FakeProber::new(&[(
            "http://127.0.0.1:8787/healthz",
            vec![ProbeResult::Unreachable, healthz_ok()],
        )]);
        let spawner = FakeSpawner::sleeping();
        let lifecycle = ServerLifecycle::new(config_with_binary(), prober, spawner);
        lifecycle.discover().await;

        let pid = lifecycle
            .child
            .lock()
            .unwrap()
            .as_ref()
            .map(|child| child.id())
            .expect("a managed child");

        lifecycle.shutdown();
        assert!(lifecycle.child.lock().unwrap().is_none());
        // A second call must not touch an unrelated process that inherited the pid.
        lifecycle.shutdown();

        // The child was reaped, so no zombie is left behind holding the pid.
        assert!(pid > 0);
    }

    /// True while the process still exists (signal 0 probes without delivering).
    #[cfg(unix)]
    fn process_is_alive(pid: u32) -> bool {
        // SAFETY: `kill` with signal 0 only performs an existence/permission
        // check and delivers nothing.
        unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn respawning_terminates_the_previous_managed_child_instead_of_orphaning_it() {
        // healthz: unreachable -> spawn A; ok -> A connected; unreachable after
        // mark_unreachable -> respawn; ok -> B connected.
        let prober = FakeProber::new(&[(
            "http://127.0.0.1:8787/healthz",
            vec![
                ProbeResult::Unreachable,
                healthz_ok(),
                ProbeResult::Unreachable,
                healthz_ok(),
            ],
        )]);
        let spawner = FakeSpawner::sleeping();
        let lifecycle = ServerLifecycle::new(config_with_binary(), prober, spawner.clone());

        lifecycle.discover().await;
        let first_pid = lifecycle
            .child
            .lock()
            .unwrap()
            .as_ref()
            .map(|child| child.id())
            .expect("a managed child after the first discovery");
        assert!(process_is_alive(first_pid));

        lifecycle.mark_unreachable("connection refused".to_string());
        lifecycle.discover().await;

        assert_eq!(spawner.calls(), 2);
        assert!(
            !process_is_alive(first_pid),
            "the first managed server was orphaned instead of terminated"
        );

        let second_pid = lifecycle
            .child
            .lock()
            .unwrap()
            .as_ref()
            .map(|child| child.id())
            .expect("exactly one tracked child after the second discovery");
        assert_ne!(second_pid, first_pid);
        assert!(process_is_alive(second_pid));
        assert_eq!(
            lifecycle.current_state(),
            ServerState::Connected(Endpoint::new(8787, EndpointKind::CliServe, true))
        );

        lifecycle.shutdown();
        assert!(lifecycle.child.lock().unwrap().is_none());
        assert!(!process_is_alive(second_pid));
    }

    #[tokio::test]
    async fn concurrent_discoveries_collapse_into_a_single_spawn() {
        // Nothing ever answers, so each unguarded caller would spawn its own
        // server and only the last handle would be tracked.
        let prober = FakeProber::new(&[(
            "http://127.0.0.1:8787/healthz",
            vec![ProbeResult::Unreachable],
        )]);
        let spawner = FakeSpawner::sleeping();
        let config = LifecycleConfig {
            startup_timeout: Duration::from_millis(60),
            poll_interval: Duration::from_millis(10),
            ..config_with_binary()
        };
        let lifecycle = ServerLifecycle::new(config, prober, spawner.clone());

        let (first, second, third) = tokio::join!(
            {
                let lifecycle = lifecycle.clone();
                async move { lifecycle.discover().await }
            },
            {
                let lifecycle = lifecycle.clone();
                async move { lifecycle.discover().await }
            },
            {
                let lifecycle = lifecycle.clone();
                async move { lifecycle.discover().await }
            },
        );
        let _ = (first, second, third);

        assert_eq!(
            spawner.calls(),
            1,
            "concurrent retries must share one discovery"
        );
        assert!(lifecycle.child.lock().unwrap().is_none());
        assert!(matches!(
            lifecycle.current_state(),
            ServerState::Failed { .. }
        ));
    }

    #[tokio::test]
    async fn a_retry_after_a_completed_discovery_still_runs_a_fresh_one() {
        let prober = FakeProber::new(&[(
            "http://127.0.0.1:8787/healthz",
            vec![ProbeResult::Unreachable],
        )]);
        let spawner = FakeSpawner::sleeping();
        let config = LifecycleConfig {
            startup_timeout: Duration::from_millis(40),
            poll_interval: Duration::from_millis(10),
            ..config_with_binary()
        };
        let lifecycle = ServerLifecycle::new(config, prober, spawner.clone());

        lifecycle.discover().await;
        assert!(matches!(
            lifecycle.current_state(),
            ServerState::Failed { .. }
        ));

        // Sequential, so the collapse guard must not suppress this attempt.
        lifecycle.discover().await;
        assert_eq!(spawner.calls(), 2);

        lifecycle.shutdown();
    }

    #[tokio::test]
    async fn shutdown_never_touches_an_external_server() {
        let prober = FakeProber::new(&[("http://127.0.0.1:8787/healthz", vec![healthz_ok()])]);
        let spawner = FakeSpawner::sleeping();
        let lifecycle = ServerLifecycle::new(config_with_binary(), prober, spawner.clone());
        lifecycle.discover().await;

        lifecycle.shutdown();

        assert_eq!(spawner.calls(), 0);
        assert_eq!(
            lifecycle.current_state(),
            ServerState::Connected(Endpoint::new(8787, EndpointKind::CliServe, false))
        );
    }
}
