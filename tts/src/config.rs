//! Configuration for the TTS server wrapper.
//!
//! Precedence, highest wins:
//!
//!   1. environment variables
//!   2. `$TTS_DIR/config.env`
//!   3. built-in defaults (below)
//!
//! `TTS_DIR` itself is resolved from the environment (or `$HOME/tts`), never
//! from `config.env` — the file lives *inside* that directory, so letting it
//! define its own location would be circular.
//!
//! The runtime tree (`TTS_DIR`) is separate from the source tree. This binary is
//! source and lives in the repo; the models, the koboldcpp binary, the voices
//! and the logs live under `TTS_DIR` and are never committed.

use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

/// The audio tokenizer is not optional: the talker emits codec tokens and this
/// turns them back into a waveform.
pub const TOKENIZER_FILE: &str = "qwen3-tts-tokenizer-q8_0.gguf";

/// Model files, probed in this order when `TTS_MODEL=auto`. The 1.7B is
/// preferred: it costs only ~11% more wallclock than the 0.6B on the GPU, since
/// the codec Predictor dominates runtime and is the same size in both.
pub const MODEL_17B: &str = "Qwen3-TTS-12Hz-1.7B-Base-q8_0.gguf";
pub const MODEL_06B: &str = "qwen3-tts-0.6b-q8_0.gguf";

/// Which backend to ask KoboldCpp for. `Gpu` means Vulkan — KoboldCpp has no
/// ROCm path, so on an AMD card Vulkan through Mesa's RADV driver is the only
/// acceleration available. Measured RTF 0.82 on Vulkan against 1.78 on CPU.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Backend {
    Gpu,
    Cpu,
}

impl Backend {
    #[allow(dead_code)] // kept for symmetry; used by config parsing and display
    pub fn as_str(self) -> &'static str {
        match self {
            Backend::Gpu => "gpu",
            Backend::Cpu => "cpu",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Config {
    // Paths
    pub dir: PathBuf,
    pub bin: PathBuf,
    pub models: PathBuf,
    pub logs: PathBuf,
    pub voices: PathBuf,
    pub out: PathBuf,

    // Server
    pub port: u16,
    pub backend: Backend,
    pub threads: u32,
    pub maxlen: u32,

    // Web UI
    pub webui_port: u16,
    pub webui_host: String,

    // Model selection: "auto", "1.7b" or "0.6b"
    pub model: String,
}

/// `$HOME`, or a clear error rather than a surprising relative path.
fn home() -> PathBuf {
    match env::var_os("HOME") {
        Some(h) => PathBuf::from(h),
        None => PathBuf::from("/"),
    }
}

/// Parse a `KEY=VALUE` file. Blank lines and `#` comments are ignored, a leading
/// `export ` is tolerated, whitespace around the key and value is trimmed, and a
/// value may be wrapped in single or double quotes.
///
/// This is deliberately not a shell: no expansion, no `$(...)`, no `:=`. The
/// bash-era `: "${VAR:=default}"` form is gone; the environment already provides
/// override semantics without it.
fn parse_env_file(path: &Path) -> HashMap<String, String> {
    let mut map = HashMap::new();
    let Ok(text) = fs::read_to_string(path) else {
        return map;
    };
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let line = line.strip_prefix("export ").unwrap_or(line);
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        if key.is_empty() {
            continue;
        }
        let mut value = value.trim();
        // Strip one layer of matching quotes, if present.
        if value.len() >= 2
            && ((value.starts_with('"') && value.ends_with('"'))
                || (value.starts_with('\'') && value.ends_with('\'')))
        {
            value = &value[1..value.len() - 1];
        }
        map.insert(key.to_string(), value.to_string());
    }
    map
}

impl Config {
    pub fn load() -> Self {
        let dir = env::var_os("TTS_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| home().join("tts"));

        let file = parse_env_file(&dir.join("config.env"));

        // Environment beats the file; the file beats the default.
        let get = |key: &str| -> Option<String> {
            env::var(key).ok().filter(|s| !s.is_empty()).or_else(|| file.get(key).cloned())
        };
        let get_path = |key: &str, default: PathBuf| -> PathBuf {
            get(key).map(PathBuf::from).unwrap_or(default)
        };
        let get_u32 = |key: &str, default: u32| -> u32 {
            get(key).and_then(|v| v.trim().parse().ok()).unwrap_or(default)
        };

        let backend = match get("TTS_BACKEND").as_deref() {
            Some("cpu") => Backend::Cpu,
            _ => Backend::Gpu,
        };

        Config {
            bin: get_path("TTS_BIN", dir.join("bin").join("koboldcpp")),
            models: get_path("TTS_MODELS", dir.join("models")),
            logs: get_path("TTS_LOGS", dir.join("logs")),
            voices: get_path("TTS_VOICES", dir.join("voices")),
            out: get_path("TTS_OUT", dir.join("out")),
            port: get_u32("TTS_PORT", 5001) as u16,
            webui_port: get_u32("TTS_WEBUI_PORT", 8081) as u16,
            webui_host: get("TTS_WEBUI_HOST").unwrap_or_else(|| "0.0.0.0".to_string()),
            backend,
            threads: get_u32("TTS_THREADS", 6),
            maxlen: get_u32("TTS_MAXLEN", 4096),
            model: get("TTS_MODEL").unwrap_or_else(|| "auto".to_string()),
            dir,
        }
    }

    /// Resolve `TTS_MODEL` to a filename that exists in `models/`.
    ///
    /// Returns `None` when nothing suitable is present, so callers can print a
    /// useful message instead of guessing.
    pub fn model_file(&self) -> Option<PathBuf> {
        let candidates: Vec<&str> = match self.model.as_str() {
            "1.7b" => vec![MODEL_17B],
            "0.6b" => vec![MODEL_06B],
            // "auto": prefer the larger model, fall back to the smaller.
            _ => vec![MODEL_17B, MODEL_06B],
        };
        candidates
            .into_iter()
            .map(|name| self.models.join(name))
            .find(|p| p.is_file())
    }

    pub fn tokenizer(&self) -> PathBuf {
        self.models.join(TOKENIZER_FILE)
    }

    /// The URL KoboldCpp is expected to answer on.
    pub fn tts_url(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    pub fn server_log(&self) -> PathBuf {
        self.logs.join("server.log")
    }

    /// Which backend actually came up, read from the log.
    ///
    /// The log is the ONLY trustworthy source. `--ttsgpu` on its own merely
    /// permits GPU use; without `--usevulkan 0` the backend never initialises
    /// and you get CPU numbers wearing a GPU label. Last match wins, because a
    /// restart appends rather than truncates.
    pub fn backend_actual(&self) -> Option<String> {
        let text = fs::read_to_string(self.server_log()).ok()?;
        text.lines()
            .rev()
            .find_map(|l| l.split_once("TTSTransformer backend:").map(|(_, v)| v.trim().to_string()))
    }
}
