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
//   start the daemon a page cannot run a program; a shell can, and `troupe` is designed
//                    to be started exactly this way — one lock file, one daemon, and a
//                    second attempt finds the first one rather than racing it
//
// Nothing here is a second implementation of the protocol. What comes back is a port and
// a token, and the web bundle speaks to it with the same client it uses for a worker.

use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

use serde::Serialize;

#[derive(Serialize, Clone)]
pub struct DaemonEndpoint {
    pub transport: String,
    pub port: u16,
    pub token: String,
}

/// Where the daemon publishes itself, by the same rules the daemon uses to choose.
fn discovery_path() -> Option<PathBuf> {
    let base = std::env::var_os("LOCALAPPDATA")
        .or_else(|| std::env::var_os("XDG_RUNTIME_DIR"))
        .map(PathBuf::from)
        .or_else(|| dirs_home().map(|h| h.join(".troupe/run")))?;

    Some(base.join("troupe").join("daemon.json"))
}

fn dirs_home() -> Option<PathBuf> {
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

/// The daemon's WebSocket, or `null` if none is running.
///
/// A read rather than a probe: a `daemon.json` left behind by a daemon that died names a
/// port nothing is listening on, and the client finds that out when it dials, which is
/// where that failure belongs. Pretending to know here would mean a second timeout in
/// front of the one the connection already has.
#[tauri::command]
pub fn daemon_endpoint() -> Option<DaemonEndpoint> {
    read_endpoint()
}

/// Start the daemon and wait for it to publish itself.
///
/// `troupe daemon` takes a lock: two shells racing produce one daemon and the loser
/// exits, so this does not have to coordinate with anything. What it does have to do is
/// wait — the process is up before the file is written, and returning a `null` endpoint
/// because the answer was a hundred milliseconds away would send the person to a dialog
/// asking them to type a port.
#[tauri::command]
pub fn daemon_start(binary: Option<String>) -> Result<Option<DaemonEndpoint>, String> {
    if let Some(running) = read_endpoint() {
        return Ok(Some(running));
    }

    let program = binary.unwrap_or_else(|| "troupe".to_string());

    Command::new(&program)
        .arg("daemon")
        .spawn()
        .map_err(|e| format!("could not start {program}: {e}. Install the Troupe command line tool, or start it yourself with `troupe daemon`."))?;

    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if let Some(endpoint) = read_endpoint() {
            return Ok(Some(endpoint));
        }
        std::thread::sleep(Duration::from_millis(100));
    }

    Err("the daemon started but did not publish an endpoint within ten seconds".into())
}
