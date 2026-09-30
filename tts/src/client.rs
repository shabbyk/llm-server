//! Thin client for KoboldCpp's OpenAI-shaped audio API.
//!
//! Every call here goes to 127.0.0.1, so no TLS is needed and `reqwest` is built
//! without its default features — which also keeps OpenSSL out of the build.

use anyhow::{anyhow, Context, Result};
use std::time::Duration;

use crate::config::Config;
use crate::server::AppState;

fn client(timeout_secs: u64) -> Result<reqwest::Client> {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(timeout_secs))
        .build()
        .context("building HTTP client")
}

/// Is KoboldCpp answering on its port?
///
/// Asks over HTTP rather than merely probing the socket: the port can be bound
/// before the server is willing to serve, and "loaded" is not the same as
/// "ready".
pub async fn tts_up(state: &AppState) -> bool {
    let url = format!("{}/", state.cfg.tts_url());
    matches!(
        state.http.get(&url).timeout(Duration::from_secs(3)).send().await,
        Ok(_)
    )
}

/// KoboldCpp's voice list exactly as it sends it, for pass-through.
pub async fn fetch_raw_voices(cfg: &Config) -> Result<serde_json::Value> {
    let url = format!("{}/v1/audio/voices", cfg.tts_url());
    client(10)?
        .get(&url)
        .send()
        .await
        .with_context(|| format!("GET {url}"))?
        .error_for_status()
        .with_context(|| format!("GET {url}"))?
        .json()
        .await
        .context("parsing voice list")
}

/// The voice names the server currently advertises.
///
/// KoboldCpp returns a flat array of strings:
///
///     {"status": "ok", "voices": ["kobo", "ref_synthetic.wav", ...]}
///
/// The `[{"id","name"}]` object shape is also accepted, so this works unchanged
/// against an OpenAI-compatible endpoint.
///
/// These names are the authority on what the server will accept. They are NOT
/// read off the filesystem: a file can exist and not be loaded, and a loaded
/// voice can outlive its file (see the stale/builtin distinction in `voices.rs`).
pub async fn fetch_voices(cfg: &Config) -> Result<Vec<String>> {
    let url = format!("{}/v1/audio/voices", cfg.tts_url());
    let body: serde_json::Value = client(10)?
        .get(&url)
        .send()
        .await
        .with_context(|| format!("GET {url}"))?
        .error_for_status()
        .with_context(|| format!("GET {url}"))?
        .json()
        .await
        .context("parsing voice list")?;

    let array = body
        .get("voices")
        .and_then(|v| v.as_array())
        .ok_or_else(|| anyhow!("voice list has no 'voices' array"))?;

    Ok(array
        .iter()
        .filter_map(|entry| match entry {
            serde_json::Value::String(s) => Some(s.clone()),
            other => other
                .get("id")
                .or_else(|| other.get("name"))
                .and_then(|s| s.as_str())
                .map(str::to_string),
        })
        .collect())
}
