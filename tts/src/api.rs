//! HTTP handlers.
//!
//! The `/api/*` routes back the bundled page; the `/v1/*` routes are
//! OpenAI-shaped so the same server can be dropped into other clients.

use axum::extract::{Multipart, State};
use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::json;
use std::time::Instant;

use crate::server::AppState;
use crate::voices;

/// Longest input accepted in one request, in characters. Longer requests are
/// slow enough that the browser gives up waiting before the audio arrives.
pub const MAX_TEXT_CHARS: usize = 4000;

/// Upload cap. A reference clip for zero-shot cloning is seconds long, so this
/// is far above any legitimate use and only exists to bound a hostile one.
pub const MAX_UPLOAD_BYTES: usize = 50 * 1024 * 1024;

/// Body limit for the whole request. Must exceed `MAX_UPLOAD_BYTES` because the
/// multipart framing adds overhead on top of the file itself.
pub const BODY_LIMIT: usize = 64 * 1024 * 1024;

fn error(status: StatusCode, message: impl Into<String>) -> Response {
    (status, Json(json!({ "detail": message.into() }))).into_response()
}

/// The page, with the port substituted so the header reads correctly.
pub async fn index(State(state): State<AppState>) -> Response {
    let html = include_str!("../assets/index.html")
        .replace("__PORT__", &state.cfg.webui_port.to_string());
    ([(header::CONTENT_TYPE, "text/html; charset=utf-8")], html).into_response()
}

/// Liveness and configuration, as the page needs it.
pub async fn health(State(state): State<AppState>) -> Json<serde_json::Value> {
    Json(json!({
        "tts_up": crate::client::tts_up(&state).await,
        "tts_port": state.cfg.port,
        "backend": state.backend(),
        "restarting": state.restarting(),
        "voice_dir": state.cfg.voices.to_string_lossy(),
        "accepts": [".mp3", ".wav"],
        "max_upload_mb": MAX_UPLOAD_BYTES / (1024 * 1024),
    }))
}

/// Voices, annotated with what disk says about each one.
pub async fn voices_handler(State(state): State<AppState>) -> Response {
    match crate::client::fetch_voices(&state.cfg).await {
        Ok(names) => {
            let list = voices::describe(&state.cfg.voices, &names);
            Json(json!({ "voices": list, "backend": state.backend() })).into_response()
        }
        Err(e) => error(
            StatusCode::SERVICE_UNAVAILABLE,
            format!("TTS server not reachable on {}: {e}", state.cfg.port),
        ),
    }
}

/// KoboldCpp's own voice list, passed through untouched.
///
/// Deliberately not reshaped. Callers of an OpenAI-compatible endpoint get the
/// flat string array that KoboldCpp actually produces; inventing a different
/// shape here would make the two disagree.
pub async fn proxy_voices(State(state): State<AppState>) -> Response {
    match crate::client::fetch_raw_voices(&state.cfg).await {
        Ok(body) => (StatusCode::OK, Json(body)).into_response(),
        Err(e) => error(
            StatusCode::BAD_GATEWAY,
            format!("cannot reach the TTS server: {e}"),
        ),
    }
}

/// Validate a voice name against what the server advertises.
///
/// This check is not cosmetic. An unadvertised name is NOT an error upstream:
/// KoboldCpp quietly substitutes an unrelated default speaker, so the result
/// sounds like a plausible voice that is not the one asked for. Better to refuse
/// than to return the wrong voice confidently.
async fn check_voice(state: &AppState, voice: &str) -> Result<(), Response> {
    if voice.is_empty() {
        return Ok(());
    }
    let names = crate::client::fetch_voices(&state.cfg).await.map_err(|e| {
        error(
            StatusCode::BAD_GATEWAY,
            format!("cannot reach the TTS server: {e}"),
        )
    })?;
    if names.iter().any(|n| n == voice) {
        return Ok(());
    }
    Err(error(
        StatusCode::BAD_REQUEST,
        format!(
            "'{voice}' is not an available voice. Available: {}",
            names.join(", ")
        ),
    ))
}

/// Synthesis, for the bundled page. Multipart form: `text`, `voice`.
pub async fn speak(State(state): State<AppState>, mut form: Multipart) -> Response {
    let mut text = String::new();
    let mut voice = String::new();

    loop {
        match form.next_field().await {
            Ok(Some(field)) => match field.name().unwrap_or_default().to_string().as_str() {
                "text" => text = field.text().await.unwrap_or_default(),
                "voice" => voice = field.text().await.unwrap_or_default(),
                _ => {}
            },
            Ok(None) => break,
            Err(e) => return error(StatusCode::BAD_REQUEST, format!("malformed form body: {e}")),
        }
    }

    let text = text.trim().to_string();
    if text.is_empty() {
        return error(StatusCode::BAD_REQUEST, "No text given.");
    }
    if text.len() > MAX_TEXT_CHARS {
        return error(
            StatusCode::BAD_REQUEST,
            format!(
                "Text is {} characters; the limit is {MAX_TEXT_CHARS}. Split it into a few requests.",
                text.len()
            ),
        );
    }
    if state.restarting() {
        return error(
            StatusCode::SERVICE_UNAVAILABLE,
            "The TTS server is restarting after an upload. Try again in a few seconds.",
        );
    }
    if let Err(resp) = check_voice(&state, &voice).await {
        return resp;
    }

    synthesize(&state, &text, &voice).await
}

/// Synthesis, in OpenAI's request shape: `{"input": ..., "voice": ...}`.
///
/// `response_format` is accepted and ignored: the model produces PCM WAV and
/// that is what is returned. Silently transcoding would need a decoder we do not
/// have, so claiming to honour other formats would be a lie.
pub async fn speech(State(state): State<AppState>, Json(req): Json<serde_json::Value>) -> Response {
    let text = req
        .get("input")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .trim()
        .to_string();
    let voice = req
        .get("voice")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();

    if text.is_empty() {
        return error(StatusCode::BAD_REQUEST, "No 'input' given.");
    }
    if text.len() > MAX_TEXT_CHARS {
        return error(
            StatusCode::BAD_REQUEST,
            format!("Input is {} characters; the limit is {MAX_TEXT_CHARS}.", text.len()),
        );
    }
    if state.restarting() {
        return error(StatusCode::SERVICE_UNAVAILABLE, "The TTS server is restarting.");
    }
    if let Err(resp) = check_voice(&state, &voice).await {
        return resp;
    }

    synthesize(&state, &text, &voice).await
}

/// Shared synthesis path: call the model, and refuse to hand back anything that
/// is not actually audio.
async fn synthesize(state: &AppState, text: &str, voice: &str) -> Response {
    let mut payload = json!({ "input": text });
    if !voice.is_empty() {
        payload["voice"] = json!(voice);
    }

    let started = Instant::now();
    let response = state
        .http
        .post(format!("{}/v1/audio/speech", state.cfg.tts_url()))
        .json(&payload)
        .send()
        .await;

    let response = match response {
        Ok(r) => r,
        Err(e) if e.is_timeout() => {
            return error(StatusCode::GATEWAY_TIMEOUT, "The TTS server did not respond in time.")
        }
        Err(e) => {
            return error(
                StatusCode::BAD_GATEWAY,
                format!("Cannot reach the TTS server: {e}"),
            )
        }
    };

    let status = response.status();
    let bytes = match response.bytes().await {
        Ok(b) => b,
        Err(e) => {
            return error(
                StatusCode::BAD_GATEWAY,
                format!("reading the TTS response failed: {e}"),
            )
        }
    };

    if !status.is_success() {
        return error(
            StatusCode::from_u16(status.as_u16()).unwrap_or(StatusCode::BAD_GATEWAY),
            format!(
                "TTS server returned {status}: {}",
                String::from_utf8_lossy(&bytes[..bytes.len().min(300)])
            ),
        );
    }

    // A failed synthesis can still arrive as HTTP 200 with a short JSON body.
    // Catching that here beats handing the caller a "WAV" that plays as noise.
    if !bytes.starts_with(b"RIFF") {
        return error(
            StatusCode::BAD_GATEWAY,
            format!(
                "TTS server returned a non-audio response: {}",
                String::from_utf8_lossy(&bytes[..bytes.len().min(200)])
            ),
        );
    }

    let elapsed = started.elapsed().as_secs_f64();
    let duration = voices::wav_duration_bytes(&bytes);

    let mut response = Response::new(bytes.into_response().into_body());
    let headers = response.headers_mut();
    headers.insert(
        header::CONTENT_TYPE,
        header::HeaderValue::from_static("audio/wav"),
    );
    if let Ok(v) = header::HeaderValue::from_str(&format!("{elapsed:.2}")) {
        headers.insert("X-Elapsed-Sec", v);
    }
    if let Some(d) = duration {
        if let Ok(v) = header::HeaderValue::from_str(&format!("{d:.2}")) {
            headers.insert("X-Audio-Sec", v);
        }
    }
    headers.insert(
        header::CONTENT_DISPOSITION,
        header::HeaderValue::from_static("inline; filename=\"speech.wav\""),
    );
    response
}

/// Install a reference clip, then restart so the server picks it up.
///
/// KoboldCpp builds its voice bank once at startup and has no reload endpoint,
/// so an upload cannot take effect without a restart. That is ~5-10 s of
/// downtime while the model reloads, and this handler blocks until the server
/// answers again so the caller knows when the new voice is actually usable.
pub async fn upload(State(state): State<AppState>, mut form: Multipart) -> Response {
    let Some(supervisor) = state.supervisor.clone() else {
        return error(
            StatusCode::NOT_IMPLEMENTED,
            "This server is fronting a TTS process it does not own, so it cannot restart it \
             to load a new voice. Start it with `tts on` instead of `--attach`.",
        );
    };

    if state.restarting() {
        return error(
            StatusCode::CONFLICT,
            "A restart is already in progress. Wait for it to finish.",
        );
    }

    let mut received: Option<(String, Vec<u8>)> = None;
    loop {
        match form.next_field().await {
            Ok(Some(field)) => {
                if field.name() != Some("file") {
                    continue;
                }
                let filename = field.file_name().unwrap_or_default().to_string();
                match field.bytes().await {
                    Ok(data) => received = Some((filename, data.to_vec())),
                    Err(e) => {
                        return error(StatusCode::BAD_REQUEST, format!("reading upload failed: {e}"))
                    }
                }
            }
            Ok(None) => break,
            Err(e) => return error(StatusCode::BAD_REQUEST, format!("malformed form body: {e}")),
        }
    }

    let Some((filename, data)) = received else {
        return error(StatusCode::BAD_REQUEST, "No file part named 'file'.");
    };

    if data.is_empty() {
        return error(StatusCode::BAD_REQUEST, "Uploaded file is empty.");
    }
    if data.len() > MAX_UPLOAD_BYTES {
        return error(
            StatusCode::PAYLOAD_TOO_LARGE,
            format!(
                "{} MB exceeds the {} MB limit.",
                data.len() / (1024 * 1024),
                MAX_UPLOAD_BYTES / (1024 * 1024)
            ),
        );
    }

    let suffix = std::path::Path::new(&filename)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if !voices::ALLOWED_SUFFIXES.contains(&suffix.as_str()) {
        // KoboldCpp: if filename.lower().endswith((".mp3", ".wav"))
        // Anything else is silently never registered, so reject it here rather
        // than accepting a file that will never appear in the dropdown.
        return error(
            StatusCode::BAD_REQUEST,
            format!(
                "'.{suffix}' is not accepted. KoboldCpp's ttsdir loads only: .mp3, .wav"
            ),
        );
    }

    let Some(safe) = voices::sanitize_filename(&filename) else {
        return error(StatusCode::BAD_REQUEST, "Filename has no usable characters.");
    };

    if let Err(e) = tokio::fs::create_dir_all(&state.cfg.voices).await {
        return error(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("cannot create the voices directory: {e}"),
        );
    }
    let dest = state.cfg.voices.join(&safe);
    if let Err(e) = tokio::fs::write(&dest, &data).await {
        return error(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("writing {} failed: {e}", dest.display()),
        );
    }

    let duration = voices::wav_duration(&dest);
    let detail = duration.map(|d| format!(", {d}s")).unwrap_or_default();

    state.set_restarting(true);
    let outcome = supervisor.restart().await;
    state.set_restarting(false);

    match outcome {
        Err(e) => error(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("{safe}{detail} was saved, but the TTS server did not come back: {e}"),
        ),
        Ok(()) => {
            let count = crate::client::fetch_voices(&state.cfg)
                .await
                .map(|v| v.len())
                .unwrap_or(0);
            Json(json!({
                "ok": true,
                "file": safe,
                "duration": duration,
                "message": format!("{safe}{detail} is live. TTS back up with {count} voices"),
            }))
            .into_response()
        }
    }
}
