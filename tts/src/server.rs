//! Shared server state and the router.

use axum::extract::DefaultBodyLimit;
use axum::routing::{get, post};
use axum::Router;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use crate::api;
use crate::config::Config;
use crate::supervisor::Supervisor;

/// State shared by every handler.
///
/// Cheap to clone (the `Config` is behind an `Arc`), which is what axum's
/// `State` extractor wants.
#[derive(Clone)]
pub struct AppState {
    pub cfg: Arc<Config>,
    pub http: reqwest::Client,
    /// `None` when running in attach mode: fronting a TTS server that something
    /// else started. In that case a restart cannot be performed, because only
    /// the supervisor is allowed to restart its child.
    pub supervisor: Option<Arc<Supervisor>>,
    /// True while an upload-triggered restart is in flight, so `/api/health` can
    /// say so and the page can disable Generate instead of showing a connection
    /// error it cannot explain.
    restarting: Arc<AtomicBool>,
}

impl AppState {
    pub fn new(cfg: Arc<Config>, supervisor: Option<Arc<Supervisor>>) -> Self {
        let http = reqwest::Client::builder()
            // Synthesis streams for a long time; a short timeout here would cut
            // waveforms off mid-flight.
            .timeout(Duration::from_secs(900))
            .connect_timeout(Duration::from_secs(5))
            .build()
            .expect("building HTTP client");
        AppState {
            cfg,
            http,
            supervisor,
            restarting: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn restarting(&self) -> bool {
        self.restarting.load(Ordering::SeqCst)
    }

    pub fn set_restarting(&self, value: bool) {
        self.restarting.store(value, Ordering::SeqCst);
    }

    /// Which backend is in use.
    ///
    /// Prefers what the supervisor saw on the child's output, since that is the
    /// live truth; falls back to scraping the log, which is what a server
    /// started outside this process leaves behind.
    pub fn backend(&self) -> String {
        self.supervisor
            .as_ref()
            .and_then(|s| s.backend())
            .or_else(|| self.cfg.backend_actual())
            .unwrap_or_else(|| "unknown".to_string())
    }
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/", get(api::index))
        .route("/api/health", get(api::health))
        .route("/api/voices", get(api::voices_handler))
        .route("/api/speak", post(api::speak))
        .route("/api/voices/upload", post(api::upload))
        .route("/v1/audio/voices", get(api::proxy_voices))
        .route("/v1/audio/speech", post(api::speech))
        // The default request body limit is 2 MB, which would reject a
        // legitimate reference clip before our own 50 MB check ever runs.
        .layer(DefaultBodyLimit::max(api::BODY_LIMIT))
        .with_state(state)
}
