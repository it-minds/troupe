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

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

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

pub(crate) fn home() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
}

pub(crate) fn read_endpoint() -> Option<DaemonEndpoint> {
    read_endpoint_at(&discovery_path()?)
}

fn read_endpoint_at(path: &Path) -> Option<DaemonEndpoint> {
    let contents = std::fs::read_to_string(path).ok()?;
    let json: serde_json::Value = serde_json::from_str(&contents).ok()?;
    let ws = json.get("ws")?;

    Some(DaemonEndpoint {
        transport: "ws".into(),
        port: u16::try_from(ws.get("port")?.as_u64()?).ok()?,
        token: ws.get("token")?.as_str()?.to_string(),
    })
}

/// Whether anything accepts a connection where the file says: what a daemon that said it
/// stops is waited out by, since one still closing its files may already have stopped
/// answering.
pub(crate) fn listening(endpoint: &DaemonEndpoint) -> bool {
    let addr = SocketAddr::from(([127, 0, 0, 1], endpoint.port));
    TcpStream::connect_timeout(&addr, Duration::from_millis(300)).is_ok()
}

/// Whether a Troupe daemon that takes the file's token answers where the file says: the
/// WebSocket upgrade, and `initialize` with the token answered with a result. A
/// `daemon.json` left behind by a daemon that died names a port that nothing answers on,
/// or that another program has taken since, and starting a daemon over a stale file is
/// the whole point of `daemon_start`; a port that merely accepts proves neither.
pub(crate) fn alive(endpoint: &DaemonEndpoint) -> bool {
    probe(endpoint, Duration::from_millis(1500)).unwrap_or(false)
}

/// The probe behind `alive`, each read and write given `wait`. `Ok(false)` for something
/// that answered as no Troupe daemon with this token would.
fn probe(endpoint: &DaemonEndpoint, wait: Duration) -> std::io::Result<bool> {
    match open(endpoint, wait)? {
        Some((mut stream, _reader)) => {
            let _ = stream.write_all(&frame(0x8, &[]));
            Ok(true)
        }
        None => Ok(false),
    }
}

/// What the daemon says to `identity.get`: who is linked, to which plane, and the key this
/// computer pinned for that plane (`plane_key`), which the shell checks a plane's signed
/// answer against itself rather than take the page's word for it (#657).
pub(crate) fn identity(endpoint: &DaemonEndpoint) -> Result<serde_json::Value, String> {
    let unreadable = |e: std::io::Error| format!("the daemon on this computer could not be asked who is signed in: {e}");
    let (mut stream, mut reader) = open(endpoint, Duration::from_secs(5))
        .map_err(unreadable)?
        .ok_or("the daemon on this computer did not answer as a Troupe daemon")?;
    let ask = serde_json::json!({ "jsonrpc": "2.0", "id": 2, "method": "identity.get", "params": {} });
    stream.write_all(&frame(0x1, ask.to_string().as_bytes())).map_err(unreadable)?;

    let answer = answer_to(&mut reader, 2).map_err(unreadable)?;
    let _ = stream.write_all(&frame(0x8, &[]));
    match answer {
        Some(message) => match (message.get("result"), message.get("error")) {
            (Some(result), _) => Ok(result.clone()),
            (None, Some(error)) => Err(format!("the daemon on this computer refused identity.get: {error}")),
            (None, None) => Err("the daemon on this computer answered identity.get with nothing".into()),
        },
        None => Err("the daemon on this computer closed the connection before it answered".into()),
    }
}

/// The answer to the request numbered `id`, past what the daemon says before it; `None`
/// where it closes first. A few frames at most.
fn answer_to(reader: &mut impl Read, id: u64) -> std::io::Result<Option<serde_json::Value>> {
    for _ in 0..16 {
        let (opcode, payload) = read_frame(reader)?;
        if opcode == 0x8 {
            return Ok(None);
        }
        let Ok(message) = serde_json::from_slice::<serde_json::Value>(&payload) else { continue };
        if message.get("id") == Some(&serde_json::json!(id)) {
            return Ok(Some(message));
        }
    }
    Ok(None)
}

/// A connection to the daemon, upgraded and past `initialize` with the file's token, ready
/// for a request; `None` for something that answered as no Troupe daemon with it would.
fn open(endpoint: &DaemonEndpoint, wait: Duration) -> std::io::Result<Option<(TcpStream, BufReader<TcpStream>)>> {
    let addr = SocketAddr::from(([127, 0, 0, 1], endpoint.port));
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_millis(300))?;
    stream.set_read_timeout(Some(wait))?;
    stream.set_write_timeout(Some(wait))?;

    // RFC 6455's own sample key: the accept it proves is not what is checked here, the
    // answer to `initialize` is.
    write!(
        stream,
        "GET /v1/socket HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
         Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\
         Authorization: Bearer {}\r\n\r\n",
        endpoint.port, endpoint.token
    )?;

    let mut reader = BufReader::new(stream.try_clone()?);
    let mut status = String::new();
    reader.read_line(&mut status)?;
    if !status.starts_with("HTTP/1.1 101") {
        return Ok(None);
    }
    loop {
        let mut header = String::new();
        if reader.read_line(&mut header)? == 0 {
            return Ok(None);
        }
        if header == "\r\n" {
            break;
        }
    }

    let initialize = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocol_version": "1",
            "client_info": { "name": "troupe-desktop", "version": env!("CARGO_PKG_VERSION") },
            "capabilities": {},
            "auth": { "token": endpoint.token },
        },
    });
    stream.write_all(&frame(0x1, initialize.to_string().as_bytes()))?;

    // What the daemon says before its answer is not the answer.
    let answered = answer_to(&mut reader, 1)?
        .is_some_and(|message| message.get("result").and_then(|r| r.get("protocol_version")).is_some());

    if answered {
        Ok(Some((stream, reader)))
    } else {
        let _ = stream.write_all(&frame(0x8, &[]));
        Ok(None)
    }
}

/// One frame from a client: final, masked, as RFC 6455 has a client send every frame.
fn frame(opcode: u8, payload: &[u8]) -> Vec<u8> {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(0);
    let mask = (nanos ^ std::process::id().rotate_left(16)).to_be_bytes();

    let mut out = vec![0x80 | opcode];
    match payload.len() {
        n if n < 126 => out.push(0x80 | n as u8),
        n if n <= 0xFFFF => {
            out.push(0x80 | 126);
            out.extend_from_slice(&(n as u16).to_be_bytes());
        }
        n => {
            out.push(0x80 | 127);
            out.extend_from_slice(&(n as u64).to_be_bytes());
        }
    }
    out.extend_from_slice(&mask);
    out.extend(payload.iter().enumerate().map(|(i, b)| b ^ mask[i % 4]));
    out
}

/// One frame from the server: its opcode and payload, unmasked. Anything over a mebibyte
/// is no answer to `initialize`, and is refused rather than read.
fn read_frame(reader: &mut impl Read) -> std::io::Result<(u8, Vec<u8>)> {
    let mut head = [0u8; 2];
    reader.read_exact(&mut head)?;
    let opcode = head[0] & 0x0F;
    let masked = head[1] & 0x80 != 0;
    let length = match head[1] & 0x7F {
        126 => {
            let mut n = [0u8; 2];
            reader.read_exact(&mut n)?;
            u64::from(u16::from_be_bytes(n))
        }
        127 => {
            let mut n = [0u8; 8];
            reader.read_exact(&mut n)?;
            u64::from_be_bytes(n)
        }
        n => u64::from(n),
    };
    if length > 1 << 20 {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "a frame too large to be an answer"));
    }
    let mut mask = [0u8; 4];
    if masked {
        reader.read_exact(&mut mask)?;
    }
    let mut payload = vec![0u8; length as usize];
    reader.read_exact(&mut payload)?;
    if masked {
        for (i, b) in payload.iter_mut().enumerate() {
            *b ^= mask[i % 4];
        }
    }
    Ok((opcode, payload))
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

/// The command that starts a daemon: detached from this process's console and streams,
/// because the daemon outlives the window that started it and its output is its own log,
/// not ours.
///
/// On Windows it is also started with no console window. The app has no console, so a
/// console program it starts is given a new one, and `troupe-daemon.cmd` is a batch file
/// run by `cmd.exe`: without `CREATE_NO_WINDOW` that is a black window standing open for
/// as long as the daemon runs.
fn daemon_command(program: &str, args: &[&str]) -> Command {
    let mut command = Command::new(program);
    command.args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }

    command
}

fn spawn_any(binary: Option<String>) -> Result<String, String> {
    let mut tried = Vec::new();
    for (program, args) in candidates(binary) {
        let attempt = daemon_command(&program, &args).spawn();
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
///
/// This is what the app calls first, at launch and at Find, and not `daemon_endpoint`: a
/// read returns the dead port of a daemon that was killed, which only this replaces.
///
/// Async, and the wait on a thread of its own: a command that is not runs on the window's
/// thread, and the window drew nothing for as long as a daemon took to start.
#[tauri::command]
pub async fn daemon_start(binary: Option<String>) -> Result<Option<DaemonEndpoint>, String> {
    tauri::async_runtime::spawn_blocking(move || start_with(read_endpoint, || spawn_any(binary), Duration::from_secs(30)))
        .await
        .map_err(|e| format!("starting the daemon stopped short: {e}"))?
}

/// `daemon_start` with where the file is read from and how a daemon is started given to
/// it, so a test can leave a stale file somewhere of its own and start something there.
fn start_with(
    read: impl Fn() -> Option<DaemonEndpoint>,
    spawn: impl FnOnce() -> Result<String, String>,
    wait: Duration,
) -> Result<Option<DaemonEndpoint>, String> {
    if let Some(running) = read() {
        if alive(&running) {
            return Ok(Some(running));
        }
    }

    let started = spawn()?;

    // Whatever the file says once something answers on it: a new daemon rewrites the
    // file, and one that happened to get the old port back answers on the old one.
    let deadline = Instant::now() + wait;
    while Instant::now() < deadline {
        if let Some(endpoint) = read() {
            if alive(&endpoint) {
                return Ok(Some(endpoint));
            }
        }
        std::thread::sleep(Duration::from_millis(200));
    }

    Err(format!("`{started}` started but did not publish a working endpoint within {} seconds", wait.as_secs()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::net::TcpListener;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("troupe-desktop-daemon-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("daemon.json")
    }

    /// What a daemon publishes: its loopback WebSocket among its transports.
    fn publish(file: &Path, port: u16, token: &str) {
        let json = serde_json::json!({ "ws": { "port": port, "token": token }, "tcp": { "port": 1, "token": "x" } });
        std::fs::write(file, json.to_string()).unwrap();
    }

    /// A port nothing listens on any more: one the kernel gave out and was handed back.
    fn closed_port() -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.local_addr().unwrap().port()
    }

    /// A daemon as far as `alive` can tell: the WebSocket upgrade on `/v1/socket`, then
    /// `initialize` answered with a result for its token and refused for any other. On a
    /// thread of its own for as long as the test runs; its port is where it listens.
    fn fake_daemon(token: &str) -> u16 {
        fake_daemon_with(token, serde_json::json!({ "linked": false }))
    }

    /// The same, answering `identity.get` after `initialize` with `identity`.
    fn fake_daemon_with(token: &str, identity: serde_json::Value) -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let token = token.to_string();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { continue };
                let _ = answer_as_daemon(stream, &token, &identity);
            }
        });
        port
    }

    fn send_text(stream: &mut TcpStream, text: serde_json::Value) -> std::io::Result<()> {
        let bytes = text.to_string().into_bytes();
        let mut frame = vec![0x81, bytes.len() as u8];
        if bytes.len() >= 126 {
            frame = vec![0x81, 126];
            frame.extend_from_slice(&(bytes.len() as u16).to_be_bytes());
        }
        frame.extend_from_slice(&bytes);
        stream.write_all(&frame)
    }

    fn answer_as_daemon(mut stream: TcpStream, token: &str, identity: &serde_json::Value) -> std::io::Result<()> {
        let mut reader = BufReader::new(stream.try_clone()?);
        let mut request = String::new();
        reader.read_line(&mut request)?;
        loop {
            let mut header = String::new();
            if reader.read_line(&mut header)? == 0 || header == "\r\n" {
                break;
            }
        }
        if !request.starts_with("GET /v1/socket ") {
            return stream.write_all(b"HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n");
        }
        stream.write_all(b"HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\n\r\n")?;

        let (_opcode, payload) = read_frame(&mut reader)?;
        let asked: serde_json::Value = serde_json::from_slice(&payload)?;
        let answer = if asked["params"]["auth"]["token"] == token {
            serde_json::json!({ "jsonrpc": "2.0", "id": asked["id"], "result": { "protocol_version": "1", "server_info": { "name": "troupe" } } })
        } else {
            serde_json::json!({ "jsonrpc": "2.0", "id": asked["id"], "error": { "code": -32001, "message": "unauthenticated" } })
        };
        // A notification first, as a daemon may send one before it answers.
        for text in [serde_json::json!({ "jsonrpc": "2.0", "method": "hello" }), answer] {
            send_text(&mut stream, text)?;
        }

        // Then `identity.get`, where the client asks it.
        let (opcode, payload) = read_frame(&mut reader)?;
        if opcode == 0x1 {
            let asked: serde_json::Value = serde_json::from_slice(&payload)?;
            if asked["method"] == "identity.get" {
                send_text(&mut stream, serde_json::json!({ "jsonrpc": "2.0", "id": asked["id"], "result": identity }))?;
            }
        }
        Ok(())
    }

    /// Something else on the port: a web server, which accepts and answers, but not as a daemon.
    fn stranger() -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let mut buf = [0u8; 1024];
                let _ = stream.read(&mut buf);
                let _ = stream.write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok");
            }
        });
        port
    }

    // Issue #706: a daemon that was killed leaves its file behind, naming its port.
    #[test]
    fn a_daemon_json_naming_a_closed_port_has_a_daemon_started_over_it() {
        let file = scratch("stale");
        let dead = closed_port();
        publish(&file, dead, "the-old-token");

        // `troupe-daemon run`, as far as the file can tell: a new port, a new token.
        let daemon = RefCell::new(None);
        let found = start_with(
            || read_endpoint_at(&file),
            || {
                let port = fake_daemon("the-new-token");
                publish(&file, port, "the-new-token");
                *daemon.borrow_mut() = Some(port);
                Ok("troupe-daemon run".into())
            },
            Duration::from_secs(5),
        )
        .unwrap()
        .expect("an endpoint");

        let started = daemon.borrow().expect("a daemon was started");
        assert_ne!(found.port, dead);
        assert_eq!(found.port, started);
        assert_eq!(found.token, "the-new-token");
    }

    // A port the dead daemon's file names, taken since by another program: it accepts, and
    // read as a running daemon, nothing was started and the app dialled a stranger.
    #[test]
    fn a_daemon_json_naming_a_port_another_program_took_has_a_daemon_started_over_it() {
        let file = scratch("taken");
        let taken = stranger();
        publish(&file, taken, "the-old-token");

        let daemon = RefCell::new(None);
        let found = start_with(
            || read_endpoint_at(&file),
            || {
                let port = fake_daemon("the-new-token");
                publish(&file, port, "the-new-token");
                *daemon.borrow_mut() = Some(port);
                Ok("troupe-daemon run".into())
            },
            Duration::from_secs(5),
        )
        .unwrap()
        .expect("an endpoint");

        assert_eq!(Some(found.port), *daemon.borrow());
        assert_ne!(found.port, taken);
        assert_eq!(found.token, "the-new-token");
    }

    #[test]
    fn identity_get_is_asked_of_the_daemon_over_its_socket() {
        let identity = serde_json::json!({ "linked": true, "plane_key": { "fingerprint": "SHA256:x" } });
        let port = fake_daemon_with("the-token", identity.clone());
        let at = |token: &str| DaemonEndpoint { transport: "ws".into(), port, token: token.into() };

        assert_eq!(super::identity(&at("the-token")).unwrap(), identity);
        assert!(super::identity(&at("another-token")).unwrap_err().contains("did not answer as a Troupe daemon"));
    }

    #[test]
    fn alive_is_a_troupe_daemon_that_takes_the_files_token() {
        let port = fake_daemon("the-token");
        let at = |token: &str| DaemonEndpoint { transport: "ws".into(), port, token: token.into() };
        assert!(alive(&at("the-token")));
        assert!(!alive(&at("another-token")), "a daemon that refuses the file's token is not the file's daemon");

        let elsewhere = DaemonEndpoint { transport: "ws".into(), port: stranger(), token: "the-token".into() };
        assert!(!alive(&elsewhere), "a port that accepts is not a daemon");
        assert!(listening(&elsewhere));
    }

    // A command that is not async runs on the window's thread, which then draws nothing
    // until it returns: up to thirty seconds while a daemon starts.
    #[test]
    fn daemon_start_is_async_so_the_window_keeps_drawing() {
        fn a_future<F: std::future::Future>(_: &F) {}
        let starting = daemon_start(Some("no-such-troupe-daemon".into()));
        a_future(&starting);
    }

    #[test]
    fn a_daemon_that_answers_is_returned_and_nothing_is_started() {
        let file = scratch("alive");
        let port = fake_daemon("the-token");
        publish(&file, port, "the-token");

        let found = start_with(|| read_endpoint_at(&file), || panic!("started a second daemon"), Duration::from_secs(5))
            .unwrap()
            .expect("an endpoint");

        assert_eq!((found.port, found.token.as_str()), (port, "the-token"));
    }

    #[cfg(windows)]
    #[link(name = "kernel32")]
    extern "system" {
        fn GetConsoleProcessList(list: *mut u32, count: u32) -> u32;
    }

    /// The processes attached to this test's console, or `None` where it has none.
    #[cfg(windows)]
    fn on_this_console() -> Option<Vec<u32>> {
        let mut list = vec![0u32; 256];
        // SAFETY: the buffer holds `list.len()` entries and the call writes no more.
        let count = unsafe { GetConsoleProcessList(list.as_mut_ptr(), list.len() as u32) } as usize;
        if count == 0 || count > list.len() {
            return None;
        }
        list.truncate(count);
        Some(list)
    }

    // A daemon started from the app had a console window of its own standing open: the
    // `.cmd` shim is `cmd.exe`, and a console program started without `CREATE_NO_WINDOW`
    // shares its parent's console or, from the app, which has none, gets a new one.
    #[cfg(windows)]
    #[test]
    fn the_daemon_is_started_with_no_console_window() {
        let Some(_) = on_this_console() else {
            eprintln!("this test has no console to compare with; nothing to check");
            return;
        };

        let mut child = daemon_command("cmd.exe", &["/d", "/c", "ping -n 4 127.0.0.1 >nul"]).spawn().unwrap();
        std::thread::sleep(Duration::from_millis(300));
        let attached = on_this_console().unwrap_or_default();
        let _ = child.kill();
        let _ = child.wait();

        assert!(
            !attached.contains(&child.id()),
            "the daemon's command was started on this process's console rather than with none of its own"
        );
    }

    #[test]
    fn no_file_has_a_daemon_started() {
        let file = scratch("absent");
        let found = start_with(
            || read_endpoint_at(&file),
            || {
                publish(&file, fake_daemon("the-token"), "the-token");
                Ok("troupe-daemon run".into())
            },
            Duration::from_secs(5),
        )
        .unwrap();

        assert_eq!(found.map(|e| e.token), Some("the-token".to_string()));
    }
}
