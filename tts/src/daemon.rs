//! Daemonisation and liveness.
//!
//! This replaces tmux. `tts up` forks, calls `setsid()`, and redirects stdio, so
//! the process is reparented to init and detached from the controlling terminal
//! — nothing sends it SIGHUP when the shell closes.
//!
//! Liveness is decided by the **kernel**, not by a pidfile. A lock file is held
//! with `flock(LOCK_EX | LOCK_NB)` for the daemon's whole lifetime:
//!
//!   * lock denied  -> a daemon is alive
//!   * lock acquired -> nothing is running, and any pidfile is stale
//!
//! That is the direct fix for the shell version's worst failure mode, where a
//! pidfile on disk disagreed with reality and `status` lied in both directions.
//! The pidfile still exists, but only to know who to signal.
//!
//! ORDERING NOTE: `fork()` in a multithreaded process is only sound if the child
//! immediately execs, and the tokio runtime is multithreaded. So everything here
//! runs in `main` *before* the runtime is built. Do not move it.

use anyhow::{bail, Context, Result};
use std::fs::{File, OpenOptions};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::io::RawFd;
use std::path::{Path, PathBuf};

use crate::config::Config;

pub fn lock_path(cfg: &Config) -> PathBuf {
    cfg.logs.join("tts.lock")
}

pub fn pid_path(cfg: &Config) -> PathBuf {
    cfg.logs.join("tts.pid")
}

/// Hold the daemon lock for this process's lifetime.
///
/// The returned `File` must be kept alive; dropping it releases the lock.
pub fn acquire_lock(cfg: &Config) -> Result<File> {
    std::fs::create_dir_all(&cfg.logs)
        .with_context(|| format!("creating {}", cfg.logs.display()))?;
    let path = lock_path(cfg);
    let file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(&path)
        .with_context(|| format!("opening {}", path.display()))?;

    // SAFETY: flock() operates on the fd and has no memory-safety implications.
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc != 0 {
        let err = std::io::Error::last_os_error();
        if err.raw_os_error() == Some(libc::EWOULDBLOCK) {
            bail!("a TTS daemon is already running (lock held on {})", path.display());
        }
        bail!("flock {}: {err}", path.display());
    }
    Ok(file)
}

/// Is a daemon running? Answered by trying to take the lock and releasing it.
pub fn is_running(cfg: &Config) -> bool {
    let path = lock_path(cfg);
    let Ok(file) = OpenOptions::new().read(true).write(true).open(&path) else {
        return false;
    };
    // SAFETY: as above.
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc == 0 {
        // We got it, so nobody else holds it. Hand it straight back.
        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_UN) };
        false
    } else {
        true
    }
}

pub fn read_pid(cfg: &Config) -> Option<i32> {
    std::fs::read_to_string(pid_path(cfg))
        .ok()?
        .trim()
        .parse()
        .ok()
}

pub fn write_pid(cfg: &Config, pid: i32) -> Result<()> {
    std::fs::write(pid_path(cfg), pid.to_string())
        .with_context(|| format!("writing {}", pid_path(cfg).display()))
}

pub fn remove_pid(cfg: &Config) {
    let _ = std::fs::remove_file(pid_path(cfg));
}

/// Which side of the fork are we on?
pub enum Fork {
    /// In the original process. Read from the notification pipe to learn whether
    /// the daemon came up, then exit.
    Parent { notify: OwnedFd },
    /// In the detached daemon.
    Child { notify: OwnedFd },
}

/// Fork twice and detach.
///
/// Two forks, not one: after the first, `setsid()` makes the process a session
/// leader, and a session leader can acquire a controlling terminal by opening
/// one. The second fork guarantees the daemon is not a session leader, so it
/// never can. This is the classic dance and the reason `nohup` alone is not
/// enough.
pub fn daemonize() -> Result<Fork> {
    let mut fds: [RawFd; 2] = [0; 2];
    // SAFETY: pipe() fills the two-entry array we pass it.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        bail!("pipe() failed: {}", std::io::Error::last_os_error());
    }
    let (read_fd, write_fd) = (fds[0], fds[1]);

    // SAFETY: fork() is called before any threads exist, which is the only time
    // it is sound. The runtime is built after this returns.
    let pid = unsafe { libc::fork() };
    if pid < 0 {
        bail!("fork() failed: {}", std::io::Error::last_os_error());
    }

    if pid > 0 {
        // Parent: keep the read end, let the child own the write end.
        // SAFETY: we just created these fds and own them.
        unsafe { libc::close(write_fd) };
        return Ok(Fork::Parent {
            notify: unsafe { OwnedFd::from_raw_fd(read_fd) },
        });
    }

    // Child.
    // SAFETY: closing an fd we own.
    unsafe { libc::close(read_fd) };

    // SAFETY: setsid() takes no arguments and only fails if we are already a
    // process group leader, which we are not right after fork().
    if unsafe { libc::setsid() } < 0 {
        bail!("setsid() failed: {}", std::io::Error::last_os_error());
    }

    // SAFETY: second fork, still before any threads exist.
    let pid2 = unsafe { libc::fork() };
    if pid2 < 0 {
        bail!("second fork() failed: {}", std::io::Error::last_os_error());
    }
    if pid2 > 0 {
        // The intermediate process exits immediately; the daemon is its child.
        // SAFETY: _exit avoids running any destructors in the intermediate.
        unsafe { libc::_exit(0) };
    }

    // SAFETY: we own the write end.
    Ok(Fork::Child {
        notify: unsafe { OwnedFd::from_raw_fd(write_fd) },
    })
}

/// Point stdin, stdout and stderr at `path` (or /dev/null), so the daemon holds
/// no reference to the terminal it was launched from.
pub fn redirect_stdio(path: Option<&Path>) -> Result<()> {
    let target = match path {
        Some(p) => OpenOptions::new().create(true).append(true).open(p),
        None => OpenOptions::new().read(true).write(true).open("/dev/null"),
    }
    .context("opening stdio target")?;

    let fd = target.as_raw_fd();
    // SAFETY: dup2() replaces the standard descriptors. It duplicates `fd`, so
    // `target` may be dropped afterwards without closing them.
    for std_fd in [libc::STDIN_FILENO, libc::STDOUT_FILENO, libc::STDERR_FILENO] {
        if unsafe { libc::dup2(fd, std_fd) } < 0 {
            bail!("dup2({fd}, {std_fd}) failed: {}", std::io::Error::last_os_error());
        }
    }
    Ok(())
}

/// Tell the waiting parent that the daemon is up.
///
/// The caller drops the fd immediately afterwards, which closes the pipe and
/// lets the parent's read return.
pub fn notify_ready(fd: &OwnedFd, message: &str) {
    let bytes = format!("{message}\n");
    // SAFETY: writing to a pipe fd we own. A short write is harmless because the
    // parent treats EOF without a line as failure.
    unsafe {
        libc::write(
            fd.as_raw_fd(),
            bytes.as_ptr() as *const libc::c_void,
            bytes.len(),
        );
    }
}

/// Block until the daemon reports readiness, or the pipe closes first.
///
/// Reads a *line* rather than to EOF, so it returns as soon as the daemon
/// reports and cannot hang on a pipe that stays open.
pub fn wait_for_ready(fd: OwnedFd) -> Result<String> {
    use std::io::BufRead;

    let mut reader = std::io::BufReader::new(File::from(fd));
    let mut line = String::new();
    let read = reader
        .read_line(&mut line)
        .context("reading readiness report from the daemon")?;
    if read == 0 {
        bail!("the daemon exited during startup without reporting; check the log");
    }
    Ok(line.trim().to_string())
}
