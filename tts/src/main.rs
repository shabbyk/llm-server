//! Local TTS server wrapper: supervises KoboldCpp and serves the web UI.
//!
//! Replaces the shell + Python wrapper that used to surround the TTS server.
//! KoboldCpp itself is unchanged and still does the actual synthesis; this
//! program owns its lifecycle and fronts it with HTTP.
//!
//! Run `tts help` for the command list.

mod api;
mod cli;
mod client;
mod commands;
mod config;
mod daemon;
mod server;
mod supervisor;
mod sys;
mod voices;

use anyhow::{bail, Context, Result};
use clap::Parser;
use std::fs;
use std::net::{SocketAddr, UdpSocket};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use cli::{Cli, Command};
use config::Config;
use server::AppState;
use supervisor::Supervisor;

fn main() -> Result<()> {
    // Rust ignores SIGPIPE by default and turns a closed pipe into a panic, so
    // `tts status | head` would crash instead of exiting quietly. Restoring the
    // default disposition makes this behave like any other Unix tool.
    // SAFETY: setting a signal handler to the default; no memory involved.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }

    let cli = Cli::parse();
    let cfg = Config::load();
    let command = cli.command.unwrap_or(Command::Status);

    // `up` must fork BEFORE the tokio runtime exists. fork() in a multithreaded
    // process is only sound if the child immediately execs, and the runtime is
    // multithreaded — so this branch is deliberately kept separate from the rest
    // of the dispatch, and returns early in the parent.
    if matches!(command, Command::On) {
        return up(cfg);
    }

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("building async runtime")?;

    // `restart` and `toggle` end in `up`, which forks. fork() must not happen
    // while the runtime is alive, so those arms stop the daemon (async), drop
    // the runtime, and only then fork.
    match command {
        Command::Status => runtime.block_on(status(&cfg)),
        Command::Voices => runtime.block_on(voices_cmd(&cfg)),
        Command::Serve { attach } => {
            let supervisor = if attach {
                None
            } else {
                Some(Arc::new(Supervisor::new(Arc::new(cfg.clone()))))
            };
            runtime.block_on(serve(cfg, supervisor, None))
        }
        Command::Off => runtime.block_on(down(&cfg)),
        // `restart` stops then starts; `toggle` does exactly one of the two.
        // Both must fork, so the runtime is dropped first.
        Command::Restart => {
            if daemon::is_running(&cfg) {
                runtime.block_on(down(&cfg))?;
            } else {
                println!("tts: already OFF");
            }
            drop(runtime);
            up(cfg)
        }
        Command::Toggle => {
            if daemon::is_running(&cfg) {
                runtime.block_on(down(&cfg))?;
                drop(runtime);
                Ok(())
            } else {
                drop(runtime);
                up(cfg)
            }
        }
        Command::Say { text, voice, out } => {
            let text = if text.is_empty() {
                use std::io::Read;
                let mut buf = String::new();
                std::io::stdin().read_to_string(&mut buf).context("reading text from stdin")?;
                buf
            } else {
                text.join(" ")
            };
            runtime.block_on(commands::say(&cfg, text, voice, out))
        }
        Command::Add { file } => runtime.block_on(commands::add(&cfg, &file)),
        Command::Log => commands::tail(&cfg.logs.join("tts.log"), 50),
        Command::Watch => commands::tail(&cfg.server_log(), 100),
        Command::On => unreachable!("handled above"),
    }
}

// ---------------------------------------------------------------- lifecycle --

/// `tts on`: start the daemon, and wait until it reports ready.
fn up(cfg: Config) -> Result<()> {
    let log = cfg.logs.join("tts.log");

    // Check liveness *before* forking. The child would also refuse (it cannot
    // take the lock), but it would fail after the fork and the parent would only
    // see a closed pipe — a confusing message for an ordinary case.
    if daemon::is_running(&cfg) {
        let pid = daemon::read_pid(&cfg)
            .map(|p| format!(" (daemon pid {p})"))
            .unwrap_or_default();
        eprintln!("tts: already ON{pid}. Use 'tts off' first if you meant to restart.");
        std::process::exit(1);
    }

    if let Err(e) = fs::create_dir_all(&cfg.logs) {
        bail!("cannot create {}: {e}", cfg.logs.display());
    }

    match daemon::daemonize()? {
        daemon::Fork::Parent { notify } => {
            // Wait for the daemon to say it is up (or to die trying) before
            // returning to the shell, so `tts on` means *ready*, not "spawned".
            match daemon::wait_for_ready(notify) {
                Ok(msg) => {
                    println!("{msg}");
                    Ok(())
                }
                Err(e) => {
                    eprintln!("tts: {e}");
                    eprintln!("     log: {}", log.display());
                    std::process::exit(1);
                }
            }
        }
        daemon::Fork::Child { notify } => {
            if let Err(e) = run_daemon(cfg, notify, &log) {
                // Best effort: the parent may already be gone.
                eprintln!("tts: {e}");
                std::process::exit(1);
            }
            Ok(())
        }
    }
}

/// The daemon body. Runs in the detached child.
///
/// `notify` is the write end of the readiness pipe: the parent is blocked on it
/// until we either report success or die, so any failure must be reported
/// through it rather than only logged.
fn run_daemon(cfg: Config, notify: std::os::fd::OwnedFd, log: &Path) -> Result<()> {
    let result = daemon_body(&cfg, log, &notify);
    if let Err(e) = &result {
        daemon::notify_ready(&notify, &format!("error: {e}"));
    }
    // Closing the pipe lets the parent's read return either way.
    drop(notify);
    daemon::remove_pid(&cfg);
    result
}

fn daemon_body(
    cfg: &Config,
    log: &Path,
    notify: &std::os::fd::OwnedFd,
) -> Result<()> {
    daemon::redirect_stdio(Some(log))?;

    // Hold the lock for our whole lifetime. Dropping it on exit is what lets the
    // next `tts on` succeed.
    let _lock = daemon::acquire_lock(cfg)?;
    daemon::write_pid(cfg, sys::getpid())?;

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("building async runtime")?;

    let supervisor = Arc::new(Supervisor::new(Arc::new(cfg.clone())));
    runtime.block_on(serve(cfg.clone(), Some(supervisor), Some(notify)))
}

/// `tts off`: stop the daemon, and confirm the port and GPU were released.
async fn down(cfg: &Config) -> Result<()> {
    if !daemon::is_running(cfg) {
        // Nothing holds the lock. Clean up a stale pidfile so status stops
        // reporting a ghost.
        daemon::remove_pid(cfg);
        println!("tts: already OFF");
        return Ok(());
    }

    let pid = daemon::read_pid(cfg).context(
        "a daemon holds the lock but there is no pidfile to signal; \
         kill it by hand, or remove logs/tts.lock if it is stale",
    )?;

    sys::term(pid);
    if !sys::wait_pid_gone(pid, Duration::from_secs(30)) {
        eprintln!("tts: pid {pid} ignored SIGTERM; sending SIGKILL");
        sys::kill(pid);
        sys::wait_pid_gone(pid, Duration::from_secs(10));
    }

    if !sys::wait_port_closed(cfg.port, Duration::from_secs(15)) {
        bail!("port {} is still answering after stop", cfg.port);
    }
    if !sys::wait_port_closed(cfg.webui_port, Duration::from_secs(10)) {
        bail!("the web UI port {} is still answering after stop", cfg.webui_port);
    }

    // The daemon is gone and the ports are free, but the TTS server may still be
    // exiting. Wait for the process itself, not just its socket: releasing a port
    // happens early in shutdown, so returning now would let an immediate `up`
    // race a half-dead server for port 5001.
    if !sys::wait_name_gone("koboldcpp", Duration::from_secs(15)) {
        bail!("koboldcpp processes are still alive after stop");
    }

    daemon::remove_pid(cfg);
    println!("tts    OFF");
    report_gpu_released();
    Ok(())
}

/// Print how much GPU memory is still mapped, so a silent failure to release
/// does not go unnoticed. This is the step where a leak would leave the GPU
/// occupied with nothing using it.
fn report_gpu_released() {
    let dirs = match fs::read_dir("/sys/class/drm") {
        Ok(d) => d,
        Err(_) => return,
    };
    for entry in dirs.flatten() {
        let mem = entry.path().join("device/mem_info_vram_used");
        if let Ok(text) = fs::read_to_string(&mem) {
            if let Ok(bytes) = text.trim().parse::<u64>() {
                println!("  GPU memory released: VRAM {} MB", bytes / 1_000_000);
                return;
            }
        }
    }
}

// ------------------------------------------------------------------- server --

/// Run the HTTP server. When `supervisor` is given, this process also owns the
/// TTS server and starts it first. `notify` is the readiness pipe for the
/// daemonised case; when it is `None` we print to stdout instead.
async fn serve(
    cfg: Config,
    supervisor: Option<Arc<Supervisor>>,
    notify: Option<&std::os::fd::OwnedFd>,
) -> Result<()> {
    let foreground = notify.is_none();

    if foreground {
        let _ = tracing_subscriber::fmt()
            .with_env_filter(
                tracing_subscriber::EnvFilter::try_from_env("TTS_LOG")
                    .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
            )
            .try_init();
    }

    // Start the TTS server first, so that by the time the HTTP port is open
    // there is something behind it.
    if let Some(sup) = supervisor.as_ref() {
        if let Err(e) = sup.start().await {
            if let Some(fd) = notify.as_ref() {
                daemon::notify_ready(fd, &format!("error: {e}"));
            }
            return Err(e).context("starting the TTS server");
        }
    }

    let addr = format!("{}:{}", cfg.webui_host, cfg.webui_port);
    let listener = match tokio::net::TcpListener::bind(&addr).await {
        Ok(l) => l,
        Err(e) => {
            if let Some(fd) = notify.as_ref() {
                daemon::notify_ready(fd, &format!("error: binding {addr}: {e}"));
            }
            // Do not leave a TTS server running with nothing in front of it.
            if let Some(sup) = supervisor.as_ref() {
                let _ = sup.stop().await;
            }
            return Err(e).with_context(|| format!("binding {addr}"));
        }
    };

    let backend = supervisor
        .as_ref()
        .and_then(|s| s.backend())
        .or_else(|| cfg.backend_actual())
        .unwrap_or_else(|| "unknown".to_string());

    let summary = format!(
        "tts: ready — ui http://{addr}/ (no auth), TTS port {}, backend {backend}",
        cfg.port
    );
    match notify.as_ref() {
        Some(fd) => daemon::notify_ready(fd, &summary),
        None => println!("{summary}"),
    }

    let state = AppState::new(Arc::new(cfg), supervisor.clone());
    let result = axum::serve(listener, server::router(state))
        .with_graceful_shutdown(async {
            // SIGTERM as well as Ctrl-C. `tts off` and any supervisor use
            // SIGTERM, and handling it lets the TTS server be stopped in an
            // orderly way instead of relying on the PDEATHSIG backstop.
            let mut term = match tokio::signal::unix::signal(
                tokio::signal::unix::SignalKind::terminate(),
            ) {
                Ok(s) => s,
                Err(_) => {
                    let _ = tokio::signal::ctrl_c().await;
                    return;
                }
            };
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {}
                _ = term.recv() => {}
            }
        })
        .await
        .context("serving HTTP");

    // Take the TTS server down with us. PDEATHSIG is the backstop if we are
    // killed outright, but an orderly exit should stop it explicitly.
    if let Some(sup) = supervisor {
        let _ = sup.stop().await;
    }
    result
}

// ------------------------------------------------------------------ commands --

/// State, model, backend, ports and voices.
async fn status(cfg: &Config) -> Result<()> {
    let running = daemon::is_running(cfg);
    let pids = sys::pids_by_name("koboldcpp");

    if running {
        let pid = daemon::read_pid(cfg).unwrap_or(0);
        let model = pids
            .iter()
            .find_map(|pid| model_from_cmdline(*pid))
            .unwrap_or_else(|| "?".to_string());
        println!("tts    ON    model {model}   daemon pid {pid}");
    } else if pids.is_empty() {
        println!("tts    OFF");
    } else {
        // The server is up but no daemon owns it: started by hand, or orphaned.
        // Worth saying plainly rather than calling it OFF.
        println!("tts    ON    external (no daemon; {} koboldcpp process(es))", pids.len());
    }

    println!(
        "  backend: {}",
        cfg.backend_actual().unwrap_or_else(|| "unknown".to_string())
    );

    // "Answering on the port" is a stronger claim than "the process exists":
    // the model can be loaded while the listener is not up yet.
    let tts_up = sys::port_open(cfg.port);
    println!(
        "  tts    {:<6} {}",
        cfg.port,
        if tts_up { "HTTP 200" } else { "DOWN" }
    );

    if sys::port_open(cfg.webui_port) {
        println!(
            "  webui  ON    http://{}:{}/  (no auth)",
            lan_ip(),
            cfg.webui_port
        );
    } else {
        println!("  webui  OFF   start with: tts on");
    }

    match client::fetch_voices(cfg).await {
        Ok(v) if v.is_empty() => println!("  voices: (none)"),
        Ok(v) => println!("  voices: {}", v.join(", ")),
        Err(_) => println!("  voices: (unavailable)"),
    }

    println!(
        "  refs:  {} file(s) in {}",
        count_refs(&cfg.voices),
        cfg.voices.display()
    );
    println!("  dir:   {}", cfg.dir.display());

    Ok(())
}

async fn voices_cmd(cfg: &Config) -> Result<()> {
    match client::fetch_voices(cfg).await {
        Ok(list) => {
            println!("available voices (use the name EXACTLY, extension included):");
            for name in list {
                println!("  {name}");
            }
            Ok(())
        }
        Err(e) => {
            eprintln!("tts: cannot reach the TTS server on {}: {e}", cfg.port);
            eprintln!("     Start it with: tts on");
            std::process::exit(1);
        }
    }
}

/// Which model this process is using, read back from its argv. More reliable
/// than trusting the config, because the file may have changed since start.
fn model_from_cmdline(pid: i32) -> Option<String> {
    let cmd = sys::cmdline(pid)?;
    [config::MODEL_17B, config::MODEL_06B]
        .into_iter()
        .find(|name| cmd.contains(name))
        .map(str::to_string)
}

/// Count `.wav` and `.mp3` files, which is all KoboldCpp's `ttsdir` scanner
/// loads. Other formats are accepted by the filesystem but never registered.
fn count_refs(dir: &Path) -> usize {
    let Ok(entries) = fs::read_dir(dir) else {
        return 0;
    };
    entries
        .flatten()
        .filter(|e| {
            e.path()
                .extension()
                .and_then(|x| x.to_str())
                .map(|x| x.eq_ignore_ascii_case("wav") || x.eq_ignore_ascii_case("mp3"))
                .unwrap_or(false)
        })
        .count()
}

/// Best-effort LAN address, for printing a URL reachable from another machine.
/// Connecting a UDP socket performs a routing lookup and sends nothing; if it
/// fails, loopback is the honest answer rather than a wrong IP.
fn lan_ip() -> String {
    if let Ok(sock) = UdpSocket::bind("0.0.0.0:0") {
        if sock.connect("8.8.8.8:80").is_ok() {
            if let Ok(SocketAddr::V4(addr)) = sock.local_addr() {
                return addr.ip().to_string();
            }
        }
    }
    "127.0.0.1".to_string()
}
