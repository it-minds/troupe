// An artifact shown from its own host (troupe #62): a window of its own at the one-time
// address `artifact.open` answered, which the artifacts host redeems for a cookie of its own.
// The app never fetches an artifact's files into its own origin; the page runs on the
// artifacts host's origin, under that host's sandboxed policy, in a webview beside the app's.
//
// The window is granted nothing: the app's capability names the main window alone, so this
// one reaches no command of the shell's, and a remote page is given no IPC in any case. It
// stays on the host it was opened at: a link to anywhere else, or a page's new window, goes
// to the person's own browser instead. One window per artifact; opening it again (another
// version, say) points the same window at the new address.

use tauri::{AppHandle, Manager, Url, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_opener::OpenerExt;

/// The address to open, or why it is not one: https anywhere, http only to this machine
/// (a development plane's artifacts host), and nothing with a user name or password in it.
pub(crate) fn artifact_address(url: &str) -> Result<Url, String> {
    let parsed = Url::parse(url).map_err(|e| format!("{url} is not an address: {e}"))?;
    let loopback = matches!(parsed.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
    let scheme_ok = parsed.scheme() == "https" || (parsed.scheme() == "http" && loopback);
    if !scheme_ok || parsed.host_str().is_none() {
        return Err(format!("{url} is not an artifacts host's address: only https, or http on this machine"));
    }
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err(format!("{url} names a user in it, which an artifacts host's address does not"));
    }
    Ok(parsed)
}

/// Whether `to` is on the host the window was opened at: scheme, host and port alike.
pub(crate) fn same_origin(from: &Url, to: &Url) -> bool {
    from.scheme() == to.scheme() && from.host_str() == to.host_str() && from.port_or_known_default() == to.port_or_known_default()
}

/// A window's label from the artifact's id: letters, digits and dashes only.
pub(crate) fn label(key: &str) -> String {
    let clean: String = key.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' }).take(64).collect();
    format!("artifact-{clean}")
}

#[tauri::command]
pub fn artifact_window_open(app: AppHandle, url: String, title: String, key: String) -> Result<(), String> {
    let address = artifact_address(&url)?;
    let label = label(&key);
    let title = if title.trim().is_empty() { "Artifact".to_string() } else { title.chars().take(200).collect() };

    if let Some(window) = app.get_webview_window(&label) {
        window.navigate(address).map_err(|e| format!("the artifact's window did not open it: {e}"))?;
        let _ = window.set_title(&title);
        let _ = window.set_focus();
        return Ok(());
    }

    let home = address.clone();
    let away = app.clone();
    let popup = app.clone();
    WebviewWindowBuilder::new(&app, label, WebviewUrl::External(address))
        .title(title)
        .inner_size(1000.0, 760.0)
        .min_inner_size(480.0, 360.0)
        .on_navigation(move |to| {
            if same_origin(&home, to) {
                return true;
            }
            elsewhere(&away, to);
            false
        })
        .on_new_window(move |to, _features| {
            elsewhere(&popup, &to);
            tauri::webview::NewWindowResponse::Deny
        })
        .build()
        .map(|_| ())
        .map_err(|e| format!("the artifact's window did not open: {e}"))
}

/// A link off the artifacts host, in the person's own browser; anything but a web or mail
/// address is dropped.
fn elsewhere(app: &AppHandle, to: &Url) {
    if matches!(to.scheme(), "https" | "http" | "mailto") {
        let _ = app.opener().open_url(to.as_str(), None::<&str>);
    }
}

#[cfg(test)]
mod tests {
    use super::{artifact_address, label, same_origin};

    #[test]
    fn an_artifacts_host_s_address_opens_and_nothing_else_does() {
        assert!(artifact_address("https://artifacts.example.test/enter?ticket=abc").is_ok());
        assert!(artifact_address("http://127.0.0.1:4003/enter?ticket=abc").is_ok());
        for refused in [
            "http://artifacts.example.test/enter",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "tauri://localhost/",
            "https://ada:secret@artifacts.example.test/",
            "not an address",
        ] {
            assert!(artifact_address(refused).is_err(), "{refused}");
        }
    }

    #[test]
    fn the_window_stays_on_the_host_it_was_opened_at() {
        let home = artifact_address("https://artifacts.example.test/enter?ticket=abc").unwrap();
        let page = artifact_address("https://artifacts.example.test/a/art-1/v2/").unwrap();
        let other = artifact_address("https://plane.example.test/rpc").unwrap();
        let port = artifact_address("https://artifacts.example.test:8443/a/").unwrap();
        assert!(same_origin(&home, &page));
        assert!(!same_origin(&home, &other));
        assert!(!same_origin(&home, &port));
    }

    #[test]
    fn a_label_is_one_a_window_may_have() {
        assert_eq!(label("art-1a2b"), "artifact-art-1a2b");
        assert_eq!(label("a/b c"), "artifact-a-b-c");
    }

    // The command is registered with the shell, and the capability that grants the shell's
    // commands names the main window alone, so an artifact's window is granted none of them.
    #[test]
    fn the_command_is_registered_and_its_window_is_granted_nothing() {
        let lib = include_str!("lib.rs");
        let handler = &lib[lib.find("generate_handler![").expect("a handler list")..];
        let handler = &handler[..handler.find(']').expect("its end")];
        assert!(handler.contains("artifact_window::artifact_window_open"), "{handler}");

        let capability: serde_json::Value = serde_json::from_str(include_str!("../capabilities/default.json")).unwrap();
        assert_eq!(capability["windows"], serde_json::json!(["main"]));
        assert!(capability.get("remote").is_none(), "no remote page is given IPC");
    }
}
