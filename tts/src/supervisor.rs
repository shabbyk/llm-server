//! Owns the KoboldCpp process.
//!
//! This is what replaces `run.sh` and tmux. The supervisor spawns the TTS
//! server as a child, streams its output to the log, watches for the line that
//! reports which backend actually initialised, and can restart it.
//!
//! Two details matter more than they look:
//!
//! * **`PR_SET_PDEATHSIG`** is set on the child, so if this process dies for any
//!   reason the kernel kills the TTS server too. Without it, a crash leaves a
//!   server holding port 5001 that nothing can stop.
//!
//! * **The backend is taken from the child's output, not from the flags.**
//!   `--ttsgpu` alone is a no-op that yields CPU numbers wearing a GPU label;
//!   only `--usevulkan 0` initialises Vulkan. So the log is the only trustworthy
//!   source, and reading it as we stream it avoids re-reading the file later.

use anyhow::{bail, Context, Result};
use std::process::Stdio;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::Mutex;

use crate::config::{Backend, Config};

/// How long to wait for the server to answer after starting. The model takes
/// ~8 s to load onto the GPU, but a cold start on a busy machine is slower.
const READY_TIMEOUT: Duration = Duration::from_secs(180);
const STOP_TIMEOUT: Duration = Duration::from_secs(30);

pub struct Supervisor {
    cfg: Arc<Config>,
    child: Mutex<Option<Child>>,
    /// Written by the output pumps, read by `backend()`. One cell, reused
    /// across restarts, so readers always see the latest server's report.
    backend: Arc<std::sync::Mutex<Option<String>>>,
}

impl Supervisor {
    pub fn new(cfg: Arc<Config>) -> Self {
        Supervisor {
            cfg,
            child: Mutex::new(None),
            backend: Arc::new(std::sync::Mutex::new(None)),
        }
    }

    /// The backend the running server reported, e.g. `Vulkan0`.
    pub fn backend(&self) -> Option<String> {
        self.backend.lock().ok().and_then(|b| b.clone())
    }

    /// Build the argv for KoboldCpp from the configuration.
    ///
    /// `--noblas` is deliberately absent: KoboldCpp rejects it together with
    /// `--usevulkan` (exit code 2), and it made no measurable difference anyway.
    fn command(&self, model: &std::path::Path) -> Command {
        let mut cmd = Command::new(&self.cfg.bin);
        cmd.arg("--port").arg(self.cfg.port.to_string());
        cmd.arg("--threads").arg(self.cfg.threads.to_string());

        if self.cfg.backend == Backend::Gpu {
            // Exactly these two, in this order. `--usevulkan 0` is what actually
            // initialises Vulkan; without it `--ttsgpu` does nothing.
            cmd.arg("--usevulkan").arg("0");
            cmd.arg("--ttsgpu");
        }

        cmd.arg("--ttsmodel").arg(model);
        cmd.arg("--ttswavtokenizer").arg(self.cfg.tokenizer());
        cmd.arg("--ttsdir").arg(&self.cfg.voices);
        cmd.arg("--ttsmaxlen").arg(self.cfg.maxlen.to_string());
        cmd
    }

    /// Spawn the server and wait until it answers. Idempotent-ish: refuses if a
    /// child is already tracked.
    pub async fn start(&self) -> Result<()> {
        {
            let guard = self.child.lock().await;
            if guard.is_some() {
                bail!("the TTS server is already running under this supervisor");
            }
        }

        let model = self.cfg.model_file().with_context(|| {
            format!(
                "no TTS model in {} (set TTS_MODEL, or fetch the GGUF)",
                self.cfg.models.display()
            )
        })?;
        if !self.cfg.bin.is_file() {
            bail!(
                "koboldcpp not found at {} — it is part of the runtime tree, not the repo",
                self.cfg.bin.display()
            );
        }

        tokio::fs::create_dir_all(&self.cfg.logs).await.ok();
        let log_path = self.cfg.server_log();

        let mut cmd = self.command(&model);
        cmd.stdout(Stdio::piped());
        cmd.stderr(Stdio::piped());
        cmd.stdin(Stdio::null());

        // Ask the kernel to kill the child if we die. Linux-only, which is fine
        // here, but it is the backstop that stops an orphaned server hogging
        // port 5001 after a crash.
        #[cfg(target_os = "linux")]
        unsafe {
            cmd.pre_exec(|| {
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }

        let mut child = cmd
            .spawn()
            .with_context(|| format!("spawning {}", self.cfg.bin.display()))?;

        // Stream both pipes into the log file, scanning for the backend report
        // on the way through. Interleaving between stdout and stderr is
        // approximate, which matches what a shell redirect would produce.
        {
            let log = Arc::new(tokio::sync::Mutex::new(
                tokio::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&log_path)
                    .await
                    .with_context(|| format!("opening {}", log_path.display()))?,
            ));

            // Clear the previous server's report; this one will publish its own.
            if let Ok(mut slot) = self.backend.lock() {
                *slot = None;
            }

            if let Some(out) = child.stdout.take() {
                tokio::spawn(pump(
                    out,
                    log.clone(),
                    self.backend.clone(),
                    "TTSTransformer backend:",
                ));
            }
            if let Some(err) = child.stderr.take() {
                tokio::spawn(pump(
                    err,
                    log.clone(),
                    self.backend.clone(),
                    "TTSTransformer backend:",
                ));
            }
        }

        *self.child.lock().await = Some(child);

        if let Err(e) = self.wait_ready().await {
            // Do not leave a half-started server behind.
            let _ = self.stop().await;
            return Err(e);
        }
        Ok(())
    }

    /// Poll until the server answers, or time out.
    async fn wait_ready(&self) -> Result<()> {
        let deadline = Instant::now() + READY_TIMEOUT;
        let url = format!("{}/", self.cfg.tts_url());
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(3))
            .build()?;

        while Instant::now() < deadline {
            // If the child died during load, stop early and say so rather than
            // waiting out the full timeout.
            {
                let mut guard = self.child.lock().await;
                if let Some(child) = guard.as_mut() {
                    if let Some(status) = child.try_wait().ok().flatten() {
                        bail!(
                            "the TTS server exited during load ({status}); see {}",
                            self.cfg.server_log().display()
                        );
                    }
                } else {
                    bail!("the TTS server is not being supervised");
                }
            }
            if http.get(&url).send().await.is_ok() {
                return Ok(());
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
        bail!(
            "the TTS server did not answer within {}s; see {}",
            READY_TIMEOUT.as_secs(),
            self.cfg.server_log().display()
        )
    }

    /// Terminate the child, escalate to SIGKILL if it ignores SIGTERM, and wait
    /// for the port to actually free.
    pub async fn stop(&self) -> Result<()> {
        let mut guard = self.child.lock().await;
        let Some(mut child) = guard.take() else {
            // Nothing tracked. Another server may still hold the port (started
            // by hand, or orphaned); say so rather than pretending.
            if crate::sys::port_open(self.cfg.port) {
                bail!(
                    "no supervised child, but port {} is still answering",
                    self.cfg.port
                );
            }
            return Ok(());
        };

        let pid = child.id().map(|p| p as i32);
        if let Some(pid) = pid {
            crate::sys::term(pid);
        }

        let waited = tokio::time::timeout(STOP_TIMEOUT, child.wait()).await;
        match waited {
            Ok(Ok(_)) => {}
            _ => {
                // SIGTERM did not land in time. Escalate.
                if let Some(pid) = pid {
                    crate::sys::kill(pid);
                }
                let _ = child.wait().await;
            }
        }

        if let Some(pid) = pid {
            crate::sys::wait_pid_gone(pid, Duration::from_secs(10));
        }
        if !crate::sys::wait_port_closed(self.cfg.port, Duration::from_secs(10)) {
            bail!("port {} is still answering after stop", self.cfg.port);
        }
        Ok(())
    }

    pub async fn restart(&self) -> Result<()> {
        self.stop().await?;
        self.start().await
    }
}

/// Read lines from a pipe, append them to the log, and record the backend when
/// the marker line goes past.
async fn pump<R>(
    reader: R,
    log: Arc<tokio::sync::Mutex<tokio::fs::File>>,
    backend: Arc<std::sync::Mutex<Option<String>>>,
    marker: &'static str,
) where
    R: tokio::io::AsyncRead + Unpin + Send + 'static,
{
    let mut lines = BufReader::new(reader).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        if let Some((_, value)) = line.split_once(marker) {
            if let Ok(mut slot) = backend.lock() {
                *slot = Some(value.trim().to_string());
            }
        }
        let mut file = log.lock().await;
        if file.write_all(line.as_bytes()).await.is_err() {
            break;
        }
        if file.write_all(b"\n").await.is_err() {
            break;
        }
    }
}
