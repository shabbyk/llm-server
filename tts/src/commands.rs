//! CLI subcommands that are not the server lifecycle: `say`, `add`, `log` and
//! `watch`.

use anyhow::{bail, Context, Result};
use serde_json::json;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::client;
use crate::config::Config;
use crate::voices;

/// `tts say`: text to a WAV file.
///
/// Talks to KoboldCpp on its own port rather than through this program's HTTP
/// API, so it works even when no daemon is running (as long as the TTS server
/// is up).
pub async fn say(
    cfg: &Config,
    text: String,
    voice: Option<String>,
    out: Option<PathBuf>,
) -> Result<()> {
    let text = text.trim().to_string();
    if text.is_empty() {
        bail!("no text given");
    }

    // Warn about an unadvertised name rather than failing: the server does not
    // treat it as an error either — it silently substitutes a default speaker,
    // so the output sounds plausible but is not the voice that was asked for.
    if let Some(v) = voice.as_deref() {
        if let Ok(names) = client::fetch_voices(cfg).await {
            if !names.is_empty() && !names.iter().any(|n| n == v) {
                eprintln!(
                    "WARNING: '{v}' is not an advertised voice -- the server will substitute"
                );
                eprintln!("         a default speaker and the result will not be your reference.");
                eprintln!("         Run 'tts voices' to see the real names (extension included).");
            }
        }
    }

    let mut payload = json!({ "input": text });
    if let Some(v) = voice.as_deref() {
        payload["voice"] = json!(v);
    }

    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(900))
        .build()?;
    let url = format!("{}/v1/audio/speech", cfg.tts_url());
    let response = http
        .post(&url)
        .json(&payload)
        .send()
        .await
        .with_context(|| {
            format!("POST {url} — is the TTS server running? Start it with: tts on")
        })?;

    let status = response.status();
    let bytes = response.bytes().await.context("reading the audio response")?;

    if !status.is_success() {
        bail!(
            "the TTS server returned {status}: {}",
            String::from_utf8_lossy(&bytes[..bytes.len().min(300)])
        );
    }
    // A failed synthesis can come back as HTTP 200 with a short JSON body.
    if !bytes.starts_with(b"RIFF") {
        bail!(
            "the TTS server returned a non-audio response: {}",
            String::from_utf8_lossy(&bytes[..bytes.len().min(200)])
        );
    }

    let out = out.unwrap_or_else(|| cfg.out.join(format!("{}.wav", timestamp())));
    if let Some(parent) = out.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating {}", parent.display()))?;
    }
    std::fs::write(&out, &bytes).with_context(|| format!("writing {}", out.display()))?;

    match voices::wav_duration(&out) {
        Some(d) => println!("  {}  {:.2}s  24000 Hz  1ch", out.display(), d),
        None => println!("  {}  ({} bytes)", out.display(), bytes.len()),
    }
    Ok(())
}

/// `tts add`: install a reference clip and restart so it becomes usable.
///
/// Posts to our own daemon rather than copying the file here, so the restart
/// goes through the supervisor that actually owns the child process.
pub async fn add(cfg: &Config, file: &Path) -> Result<()> {
    let src = std::fs::canonicalize(file)
        .with_context(|| format!("no such file: {}", file.display()))?;
    if !src.is_file() {
        bail!("not a file: {}", src.display());
    }

    // KoboldCpp's ttsdir scanner is literally:
    //     if filename.lower().endswith((".mp3", ".wav"))
    // Anything else would be copied in, advertised, and then fail at generation
    // time. Reject it before touching the voices directory.
    let suffix = src
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if !voices::ALLOWED_SUFFIXES.contains(&suffix.as_str()) {
        bail!(
            "KoboldCpp's ttsdir only loads .wav and .mp3, not '.{suffix}'.\n\
             Convert it first (no ffmpeg on this box; use whatever you have)."
        );
    }

    let filename = src
        .file_name()
        .and_then(|n| n.to_str())
        .context("filename is not valid UTF-8")?
        .to_string();

    let bytes = std::fs::read(&src).with_context(|| format!("reading {}", src.display()))?;

    let part = reqwest::multipart::Part::bytes(bytes).file_name(filename.clone());
    let form = reqwest::multipart::Form::new().part("file", part);

    let url = format!("http://127.0.0.1:{}/api/voices/upload", cfg.webui_port);
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(400))
        .build()?;

    let response = http.post(&url).multipart(form).send().await.with_context(|| {
        format!("POST {url} — is the daemon running? Start it with: tts on")
    })?;

    let status = response.status();
    let body: serde_json::Value = response.json().await.unwrap_or_default();

    if !status.is_success() {
        let detail = body
            .get("detail")
            .and_then(|d| d.as_str())
            .unwrap_or("no detail");
        bail!("upload rejected ({status}): {detail}");
    }

    println!("{}", body.get("message").and_then(|m| m.as_str()).unwrap_or("done"));
    if let Some(name) = body.get("file").and_then(|f| f.as_str()) {
        println!();
        println!("clone this voice with:");
        println!("    tts say \"Hello.\" -v {name}");
    }
    Ok(())
}

/// `tts log` / `tts watch`: follow a log file.
///
/// Shells out to `tail -f` rather than reimplementing follow semantics; it is
/// ubiquitous and does exactly the right thing with a rotating file.
pub fn tail(path: &Path, lines: usize) -> Result<()> {
    if !path.exists() {
        bail!(
            "no log at {} yet — has the server been started?",
            path.display()
        );
    }
    let status = std::process::Command::new("tail")
        .arg("-n")
        .arg(lines.to_string())
        .arg("-f")
        .arg(path)
        .status()
        .with_context(|| format!("running tail on {}", path.display()))?;
    if !status.success() {
        bail!("tail exited with {status}");
    }
    Ok(())
}

/// `YYYYmmdd-HHMMSS` in local time, for default output filenames.
fn timestamp() -> String {
    // SAFETY: localtime_r writes into the `tm` we own and returns a pointer to
    // it (or null on error, which we handle).
    unsafe {
        let now = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        if libc::localtime_r(&now, &mut tm).is_null() {
            return now.to_string();
        }
        format!(
            "{:04}{:02}{:02}-{:02}{:02}{:02}",
            tm.tm_year + 1900,
            tm.tm_mon + 1,
            tm.tm_mday,
            tm.tm_hour,
            tm.tm_min,
            tm.tm_sec
        )
    }
}
