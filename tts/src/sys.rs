//! Small OS helpers. Deliberately hand-rolled against `/proc` and `libc` rather
//! than pulling in a heavier crate: the needs here are tiny and the failure
//! modes are ones we want to reason about explicitly.

use std::fs;
use std::net::{SocketAddr, TcpStream};
use std::time::Duration;

/// Process IDs whose executable name is exactly `name`.
///
/// Reads `/proc/<pid>/comm`, which holds the executable name truncated to 15
/// characters. Matching exactly by name — never by command line — is deliberate:
/// a substring match on the command line matches the shell running the search
/// itself, which is how `pkill -f koboldcpp` ends up killing the invoking shell.
pub fn pids_by_name(name: &str) -> Vec<i32> {
    let mut out = Vec::new();
    let Ok(entries) = fs::read_dir("/proc") else {
        return out;
    };
    for entry in entries.flatten() {
        let fname = entry.file_name();
        let s = fname.to_string_lossy();
        if !s.bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        if let Ok(comm) = fs::read_to_string(format!("/proc/{s}/comm")) {
            // KoboldCpp is a PyInstaller binary and can appear as two processes;
            // every match is returned, and callers list them all.
            if comm.trim() == name {
                if let Ok(pid) = s.parse::<i32>() {
                    out.push(pid);
                }
            }
        }
    }
    out.sort_unstable();
    out
}

/// The full command line of a process, with NULs turned into spaces.
pub fn cmdline(pid: i32) -> Option<String> {
    let raw = fs::read(format!("/proc/{pid}/cmdline")).ok()?;
    Some(String::from_utf8_lossy(&raw).replace('\0', " ").trim().to_string())
}

/// Is a TCP port accepting connections? Used to mean "the server is answering",
/// which is a stronger statement than "the process exists".
pub fn port_open(port: u16) -> bool {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    TcpStream::connect_timeout(&addr, Duration::from_millis(1500)).is_ok()
}

/// Wait until a port stops accepting connections, or the deadline passes.
/// Returns true if it went closed.
pub fn wait_port_closed(port: u16, timeout: Duration) -> bool {
    let start = std::time::Instant::now();
    while start.elapsed() < timeout {
        if !port_open(port) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    !port_open(port)
}

/// Wait until a PID is gone. `kill(pid, 0)` succeeds while the process exists.
pub fn wait_pid_gone(pid: i32, timeout: Duration) -> bool {
    let start = std::time::Instant::now();
    while start.elapsed() < timeout {
        if !pid_alive(pid) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    !pid_alive(pid)
}

/// Wait until no process with this exact name remains.
///
/// Needed because a port is released early in shutdown, well before the process
/// actually exits. Waiting only on the port lets `down` return while the old
/// server is still tearing down, and a caller that immediately starts again can
/// then race it — the same mistake that made the shell `stop` report success
/// while the server was still alive.
pub fn wait_name_gone(name: &str, timeout: Duration) -> bool {
    let start = std::time::Instant::now();
    while start.elapsed() < timeout {
        if pids_by_name(name).is_empty() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    pids_by_name(name).is_empty()
}

/// Does this PID exist? Note this stays true for zombies, which is why callers
/// prefer `pids_by_name` for liveness and this for signalling.
pub fn pid_alive(pid: i32) -> bool {
    // SAFETY: kill() with signal 0 performs error checking only; it sends
    // nothing and mutates nothing.
    unsafe { libc::kill(pid, 0) == 0 }
}

/// Send SIGTERM.
pub fn term(pid: i32) {
    // SAFETY: no memory is touched; this only delivers a signal.
    unsafe {
        libc::kill(pid, libc::SIGTERM);
    }
}

/// Send SIGKILL, for processes that ignore polite requests.
pub fn kill(pid: i32) {
    // SAFETY: as above.
    unsafe {
        libc::kill(pid, libc::SIGKILL);
    }
}

/// This process's PID.
pub fn getpid() -> i32 {
    // SAFETY: getpid() takes no arguments and cannot fail.
    unsafe { libc::getpid() }
}
