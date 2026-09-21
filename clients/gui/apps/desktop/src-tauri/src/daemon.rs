// Finding the daemon that is already running on this computer, and starting it if it is
// not.
//
// The daemon writes `daemon.json` where the platform puts runtime files, carrying the
// port and token of every transport it serves. A browser can use exactly one of them —
// the loopback WebSocket — so that is the entry this reads and the only one it returns.
//
// Two things a tab cannot do, and the whole reason this file exists:
//
//   read the file    it is outside anything a page may open, and the token in it is
//                    what admits a client at all
//   start the daemon a page cannot run a program; a shell can, and `troupe-daemon run`
//                    is designed to be started exactly this way — one lock, one daemon,
//                    and a second attempt finds the first one rather than racing it
//
// Nothing here is a second implementation of the protocol. What comes back is a port and
// a token, and the web bundle speaks to it with the same client it uses for a worker.

use std::net::{SocketAddr, TcpStream};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde::Serialize;

#[derive(Serialize, Clone)]
pub struct DaemonEndpoint {
    pub transport: String,
    pub port: u16,
    pub token: String,
}

/// Where the daemon publishes itself, by the same rules the daemon uses to choose
/// (`Troupe.Protocol.Endpoint.discovery_path/0`): `%LOCALAPPDATA%`, else
/// `$XDG_RUNTIME_DIR`, else `~/.troupe/run`, and `troupe/daemon.json` under it.
fn discovery_path() -> Option<PathBuf> {
    let base = std::env::var_os("LOCALAPPDATA")
        .or_else(|| std::env::var_os("XDG_RUNTIME_DIR"))
        .map(PathBuf::from)
        .or_else(|| home().map(|h| h.join(".troupe/run")))?;

    Some(base.join("troupe").join("daemon.json"))
}

fn home() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
}

fn read_endpoint() -> Option<DaemonEndpoint> {
    let path = discovery_path()?;
    let contents = std::fs::read_to_string(path).ok()?;
    let json: serde_json::Value = serde_json::from_str(&contents).ok()?;
    let ws = json.get("ws")?;

    Some(DaemonEndpoint {
        transport: "ws".into(),
        port: u16::try_from(ws.get("port")?.as_u64()?).ok()?,
        token: ws.get("token")?.as_str()?.to_string(),
    })
}

/// Whether something is listening where the file says. A `daemon.json` left behind by a
/// daemon that died names a port nothing answers on, and starting a daemon over a stale
/// file is the whole point of `daemon_start`.
fn alive(endpoint: &DaemonEndpoint) -> bool {
    let addr = SocketAddr::from(([127, 0, 0, 1], endpoint.port));
    TcpStream::connect_timeout(&addr, Duration::from_millis(300)).is_ok()
}

/// The daemon's WebSocket, or `null` if none is published.
///
/// A read rather than a probe: the client finds out whether the port answers when it
/// dials, which is where that failure belongs, and a stale file is what `daemon_start`
/// exists to replace.
#[tauri::command]
pub fn daemon_endpoint() -> Option<DaemonEndpoint> {
    read_endpoint()
}

/// The commands that may be the daemon, in the order to try them.
///
/// `troupe-daemon` is the release the installers put on the `PATH`; on Windows it is a
/// `.cmd` shim, which `PATH` lookup does not find under the bare name. The install
/// directories are tried by absolute path for a shell whose `PATH` is older than the
/// installer's change to it. `troupe daemon` is the TUI's older spelling and is last.
fn candidates(binary: Option<String>) -> Vec<(String, Vec<&'static str>)> {
    let mut out: Vec<(String, Vec<&'static str>)> = Vec::new();
    if let Some(given) = binary {
        out.push((given, vec!["run"]));
    }

    if cfg!(windows) {
        out.push(("troupe-daemon.cmd".into(), vec!["run"]));
        out.push(("troupe-daemon.exe".into(), vec!["run"]));
        if let Some(local) = std::env::var_os("LOCALAPPDATA").map(PathBuf::from) {
            let shim = local.join("Programs").join("troupe").join("troupe-daemon.cmd");
            out.push((shim.to_string_lossy().into_owned(), vec!["run"]));
        }
    } else {
        out.push(("troupe-daemon".into(), vec!["run"]));
        if let Some(h) = home() {
            out.push((h.join(".local/bin/troupe-daemon").to_string_lossy().into_owned(), vec!["run"]));
        }
        out.push(("/usr/local/bin/troupe-daemon".into(), vec!["run"]));
    }

    out.push(("troupe".into(), vec!["daemon"]));
    out
}

fn spawn_any(binary: Option<String>) -> Result<String, String> {
    let mut tried = Vec::new();
    for (program, args) in candidates(binary) {
        // Detached from this process's console and streams: the daemon outlives the
        // window that started it, and its output is its own log, not ours.
        let attempt = Command::new(&program)
            .args(&args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
        match attempt {
            Ok(_child) => return Ok(format!("{program} {}", args.join(" "))),
            Err(e) => tried.push(format!("{program}: {e}")),
        }
    }

    Err(format!(
        "could not start the daemon. Install troupe-daemon (install.sh or install.ps1 from github.com/it-minds/troupe), \
         or start it yourself with `troupe-daemon run`. Tried: {}",
        tried.join("; ")
    ))
}

/// Start the daemon and wait for it to publish itself.
///
/// A published endpoint that answers is returned as it is. One that does not answer is a
/// file a dead daemon left behind, and the daemon is started over it — `run` is
/// idempotent and rewrites the file. Then wait: the process is up before the file is
/// written, and a `null` because the answer was a second away would send the person to a
/// dialog asking them to type a port.
#[tauri::command]
pub fn daemon_start(binary: Option<String>) -> Result<Option<DaemonEndpoint>, String> {
    if let Some(running) = read_endpoint() {
        if alive(&running) {
            return Ok(Some(running));
        }
    }

    let started = spawn_any(binary)?;

    // Whatever the file says once something answers on it: a new daemon rewrites the
    // file, and one that happened to get the old port back answers on the old one.
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        if let Some(endpoint) = read_endpoint() {
            if alive(&endpoint) {
                return Ok(Some(endpoint));
            }
        }
        std::thread::sleep(Duration::from_millis(200));
    }

    Err(format!("`{started}` started but did not publish a working endpoint within thirty seconds"))
}
