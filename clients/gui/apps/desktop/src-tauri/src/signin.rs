// The machine's sign-in: `credentials.json` in the Troupe config directory, the file
// `troupe login` writes and `troupe` reads (TUI Decision 71), shared by the desktop app
// so that one sign-in serves the terminal client, this app and, through either, the
// daemon (Decision 958).
//
// The file is the TUI's, in its shape: `current`, the plane opened by default, and one
// entry per plane under `planes`, holding the identity provider's refresh token beside
// the labels the TUI keeps (`issuer`, `client_id`, `sub`, `name`, `saved_at`). This
// module reads and writes the token and `current`, and leaves the rest of an entry as it
// finds it. It is readable by its owner and nobody else: `0600` on unix, and on Windows
// an ACL naming only the current user, as the TUI writes it.
//
// Providers rotate the refresh token on every use and refuse the old one from then on,
// so two clients sharing one token must not refresh it at the same moment: the one that
// went second would spend a token the first had just retired, and a provider that
// detects the reuse may revoke both. `credentials.lock` beside the file is the mutex, held
// while a refresh runs (`signin_lock`, `signin_unlock`), by the TUI and by this app. A
// lock left behind by a process that died goes stale after a minute.

use serde_json::{json, Map, Value};
use std::fs::{self, OpenOptions};
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime};

/// Where the TUI keeps its config (`Troupe.Paths.config_dir/0`): `TROUPE_CONFIG_HOME`,
/// else `%APPDATA%\troupe` on Windows and `$XDG_CONFIG_HOME/troupe`, else
/// `~/.config/troupe`, elsewhere.
pub fn config_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("TROUPE_CONFIG_HOME").filter(|d| !d.is_empty()) {
        return Some(PathBuf::from(dir));
    }
    let home = if cfg!(windows) {
        std::env::var_os("APPDATA").map(PathBuf::from)
    } else {
        std::env::var_os("XDG_CONFIG_HOME").filter(|d| !d.is_empty()).map(PathBuf::from)
    }
    .or_else(|| {
        std::env::var_os("HOME")
            .or_else(|| std::env::var_os("USERPROFILE"))
            .map(|h| PathBuf::from(h).join(".config"))
    })?;
    Some(home.join("troupe"))
}

fn credentials_path() -> Result<PathBuf, String> {
    config_dir().map(|d| d.join("credentials.json")).ok_or_else(|| "no home directory to keep the sign-in in".to_string())
}

fn lock_path() -> Result<PathBuf, String> {
    config_dir().map(|d| d.join("credentials.lock")).ok_or_else(|| "no home directory to keep the sign-in in".to_string())
}

/// The plane as the TUI keys it (`Troupe.Remote.Discovery.base/1`): trimmed, no trailing
/// slash, `https://` where no scheme was written.
pub fn plane_key(url: &str) -> String {
    let trimmed = url.trim().trim_end_matches('/');
    let trimmed = trimmed.strip_suffix("/.well-known/troupe").unwrap_or(trimmed);
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        trimmed.to_string()
    } else {
        format!("https://{trimmed}")
    }
}

fn read_file(path: &PathBuf) -> Map<String, Value> {
    fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .and_then(|v| match v {
            Value::Object(map) => Some(map),
            _ => None,
        })
        .unwrap_or_default()
}

fn write_file(path: &PathBuf, data: &Map<String, Value>) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("could not make {}: {e}", dir.display()))?;
    }
    fs::write(path, serde_json::to_vec(&Value::Object(data.clone())).map_err(|e| e.to_string())?)
        .map_err(|e| format!("could not write {}: {e}", path.display()))?;
    restrict(path);
    Ok(())
}

/// Only the owner may read it. On unix the mode says so; on Windows `chmod` means
/// nothing, so the inherited ACL is replaced with one naming the current user, as the
/// TUI does. A failure to restrict is not a failure to save: losing the sign-in would be
/// worse, and the TUI says so where it can.
fn restrict(path: &PathBuf) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    }
    #[cfg(windows)]
    {
        if let Some(user) = std::env::var_os("USERNAME") {
            let _ = std::process::Command::new("icacls")
                .arg(path)
                .arg("/inheritance:r")
                .arg("/grant:r")
                .arg(format!("{}:F", user.to_string_lossy()))
                .output();
        }
    }
}

/// The plane entry's refresh token, or none when the machine is not signed in there.
pub fn get(plane_url: &str) -> Result<Option<String>, String> {
    let data = read_file(&credentials_path()?);
    let key = plane_key(plane_url);
    let token = data
        .get("planes")
        .and_then(Value::as_object)
        .and_then(|planes| planes.get(&key))
        .and_then(|entry| entry.get("refresh_token"))
        .and_then(Value::as_str)
        .filter(|t| !t.is_empty())
        .map(str::to_string);
    Ok(token)
}

/// Record the plane's refresh token and make the plane the current one, keeping whatever
/// else its entry holds.
pub fn set(plane_url: &str, refresh_token: &str) -> Result<(), String> {
    let path = credentials_path()?;
    let mut data = read_file(&path);
    let key = plane_key(plane_url);
    let mut planes = data.remove("planes").and_then(|v| match v {
        Value::Object(m) => Some(m),
        _ => None,
    }).unwrap_or_default();
    let mut entry = planes.remove(&key).and_then(|v| match v {
        Value::Object(m) => Some(m),
        _ => None,
    }).unwrap_or_default();
    entry.insert("refresh_token".into(), json!(refresh_token));
    entry.insert("saved_at".into(), json!(now_ms()));
    planes.insert(key.clone(), Value::Object(entry));
    data.insert("planes".into(), Value::Object(planes));
    data.insert("current".into(), json!(key));
    write_file(&path, &data)
}

/// Forget the plane. `current` moves to another plane the machine is signed in to, or
/// to none.
pub fn clear(plane_url: &str) -> Result<(), String> {
    let path = credentials_path()?;
    if !path.exists() {
        return Ok(());
    }
    let mut data = read_file(&path);
    let key = plane_key(plane_url);
    let mut planes = data.remove("planes").and_then(|v| match v {
        Value::Object(m) => Some(m),
        _ => None,
    }).unwrap_or_default();
    planes.remove(&key);
    let current = match data.get("current").and_then(Value::as_str) {
        Some(c) if c == key => planes.keys().next().cloned().map(Value::String).unwrap_or(Value::Null),
        Some(c) => Value::String(c.to_string()),
        None => Value::Null,
    };
    data.insert("planes".into(), Value::Object(planes));
    data.insert("current".into(), current);
    write_file(&path, &data)
}

/// The plane the machine is signed in to by default: `current`, when it has a token.
pub fn current() -> Result<Option<String>, String> {
    let data = read_file(&credentials_path()?);
    let current = match data.get("current").and_then(Value::as_str) {
        Some(c) if !c.is_empty() => c.to_string(),
        _ => return Ok(None),
    };
    Ok(get(&current)?.map(|_| current))
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// How long a refresh is waited for before the lock is taken anyway: longer than any
/// token endpoint takes to answer, shorter than a person's patience.
const LOCK_WAIT: Duration = Duration::from_secs(15);
/// A lock older than this was left by a process that died holding it.
const LOCK_STALE: Duration = Duration::from_secs(60);

/// Take the machine-wide refresh lock. Blocks until the other holder lets go, or the
/// lock is stale, or the wait is up: a lock that cannot be taken is taken anyway, since
/// a sign-in that cannot be renewed is the worse outcome.
pub fn lock() -> Result<(), String> {
    let path = lock_path()?;
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("could not make {}: {e}", dir.display()))?;
    }
    let started = Instant::now();
    loop {
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(_) => return Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                let stale = fs::metadata(&path)
                    .and_then(|m| m.modified())
                    .ok()
                    .and_then(|m| SystemTime::now().duration_since(m).ok())
                    .map(|age| age > LOCK_STALE)
                    .unwrap_or(false);
                if stale || started.elapsed() > LOCK_WAIT {
                    let _ = fs::remove_file(&path);
                    continue;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(e) => return Err(format!("could not take {}: {e}", path.display())),
        }
    }
}

pub fn unlock() -> Result<(), String> {
    let path = lock_path()?;
    match fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(format!("could not let go of {}: {e}", path.display())),
    }
}

#[tauri::command]
pub fn signin_get(plane_url: String) -> Result<Option<String>, String> {
    get(&plane_url)
}

#[tauri::command]
pub fn signin_set(plane_url: String, refresh_token: String) -> Result<(), String> {
    set(&plane_url, &refresh_token)
}

#[tauri::command]
pub fn signin_clear(plane_url: String) -> Result<(), String> {
    clear(&plane_url)
}

#[tauri::command]
pub fn signin_current() -> Result<Option<String>, String> {
    current()
}

#[tauri::command]
pub fn signin_lock() -> Result<(), String> {
    lock()
}

#[tauri::command]
pub fn signin_unlock() -> Result<(), String> {
    unlock()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // The tests point `TROUPE_CONFIG_HOME` at a scratch directory, which is process-wide.
    static ENV: Mutex<()> = Mutex::new(());

    fn scratch() -> (std::sync::MutexGuard<'static, ()>, PathBuf) {
        let guard = ENV.lock().unwrap_or_else(|e| e.into_inner());
        let dir = std::env::temp_dir().join(format!("troupe-signin-{}-{}", std::process::id(), now_ms()));
        fs::create_dir_all(&dir).unwrap();
        std::env::set_var("TROUPE_CONFIG_HOME", &dir);
        (guard, dir)
    }

    #[test]
    fn planes_are_keyed_as_the_tui_keys_them() {
        assert_eq!(plane_key("https://plane.example/"), "https://plane.example");
        assert_eq!(plane_key(" plane.example "), "https://plane.example");
        assert_eq!(plane_key("http://localhost:4000/.well-known/troupe"), "http://localhost:4000");
    }

    #[test]
    fn a_sign_in_is_written_in_the_tuis_shape_and_read_back() {
        let (_guard, dir) = scratch();
        assert_eq!(get("https://plane.example").unwrap(), None);
        assert_eq!(current().unwrap(), None);

        set("https://plane.example/", "refresh-1").unwrap();
        assert_eq!(get("https://plane.example").unwrap(), Some("refresh-1".into()));
        assert_eq!(current().unwrap(), Some("https://plane.example".into()));

        let json: Value = serde_json::from_str(&fs::read_to_string(dir.join("credentials.json")).unwrap()).unwrap();
        assert_eq!(json["current"], "https://plane.example");
        assert_eq!(json["planes"]["https://plane.example"]["refresh_token"], "refresh-1");
        assert!(json["planes"]["https://plane.example"]["saved_at"].is_u64());

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(dir.join("credentials.json")).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
    }

    #[test]
    fn the_tuis_labels_survive_a_rotation_and_a_sign_out_keeps_the_other_plane() {
        let (_guard, dir) = scratch();
        fs::write(
            dir.join("credentials.json"),
            r#"{"current":"https://a.example","planes":{"https://a.example":{"refresh_token":"a-1","issuer":"https://idp","client_id":"troupe","sub":"alice"},"https://b.example":{"refresh_token":"b-1"}}}"#,
        )
        .unwrap();

        set("https://a.example", "a-2").unwrap();
        let json: Value = serde_json::from_str(&fs::read_to_string(dir.join("credentials.json")).unwrap()).unwrap();
        assert_eq!(json["planes"]["https://a.example"]["refresh_token"], "a-2");
        assert_eq!(json["planes"]["https://a.example"]["sub"], "alice");
        assert_eq!(json["planes"]["https://a.example"]["client_id"], "troupe");

        clear("https://a.example").unwrap();
        assert_eq!(get("https://a.example").unwrap(), None);
        assert_eq!(get("https://b.example").unwrap(), Some("b-1".into()));
        assert_eq!(current().unwrap(), Some("https://b.example".into()));

        clear("https://b.example").unwrap();
        assert_eq!(current().unwrap(), None);
    }

    #[test]
    fn the_lock_is_taken_once_at_a_time_and_a_stale_one_is_broken() {
        let (_guard, dir) = scratch();
        lock().unwrap();
        assert!(dir.join("credentials.lock").exists());
        unlock().unwrap();
        assert!(!dir.join("credentials.lock").exists());
        unlock().unwrap();

        // Left by a process that died: older than the stale limit, so taken at once.
        fs::write(dir.join("credentials.lock"), "").unwrap();
        let old = SystemTime::now() - LOCK_STALE - Duration::from_secs(5);
        let file = OpenOptions::new().write(true).open(dir.join("credentials.lock")).unwrap();
        file.set_modified(old).unwrap();
        let started = Instant::now();
        lock().unwrap();
        assert!(started.elapsed() < Duration::from_secs(5));
        unlock().unwrap();
    }
}
