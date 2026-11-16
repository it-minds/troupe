// The app's own links, `troupe://` (#959).
//
// Each installer registers the scheme from tauri.conf.json: the setup and the MSI write it
// under the user's classes on Windows, the app bundle declares it on macOS, and the .deb's
// desktop file names it on Linux. An AppImage has no installer, so an AppImage registers
// it itself at start (the plugin's `register_all`, which writes a desktop file pointing at
// the AppImage); nothing else registers at run time, so a developer's build never takes
// the scheme from the app a person installed.
//
// A link reaches the app two ways: it started the app, or the single-instance plugin
// handed it over from a second launch (its `deep-link` feature). Either way it is kept
// here and the page is told one came; the page takes what is kept (`deep_link_take`), so a
// link that arrived before the page was listening is not lost, and none is read twice.
//
// Nothing here reads a link beyond its scheme and its length. What it may say, and what
// the app does with a plane it is not signed in to, is the page's (`@troupe/client`'s
// `parseAppLink`): the shell passes the text on, takes no token or credential from it, and
// makes no request because of it.

use std::sync::Mutex;

use tauri::{App, AppHandle, Emitter, Manager, State};
use tauri_plugin_deep_link::DeepLinkExt;

/// What the page listens for: links are waiting to be taken.
pub const LINKS_WAITING: &str = "troupe://links-waiting";

/// No link Troupe writes is longer; anything longer is not passed on.
const MAX_LINK: usize = 2048;

/// The links that came and the page has not taken yet.
#[derive(Default)]
pub struct Links(Mutex<Vec<String>>);

/// Whether `text` is a link to hand the page: our scheme, and no longer than ours are.
pub fn ours(text: &str) -> bool {
    text.len() <= MAX_LINK && text.get(..9).is_some_and(|s| s.eq_ignore_ascii_case("troupe://"))
}

fn keep(app: &AppHandle, urls: impl IntoIterator<Item = String>) {
    let came: Vec<String> = urls.into_iter().filter(|u| ours(u)).collect();
    if came.is_empty() {
        return;
    }
    if let Ok(mut held) = app.state::<Links>().0.lock() {
        held.extend(came);
    }
    let _ = app.emit_to("main", LINKS_WAITING, ());
    crate::notify::bring_forward(app);
}

/// Hear the links: the one the app was started with, and every one after.
pub fn setup(app: &mut App) {
    #[cfg(target_os = "linux")]
    if std::env::var_os("APPIMAGE").is_some() {
        if let Err(e) = app.deep_link().register_all() {
            eprintln!("troupe: could not register the troupe:// scheme: {e}");
        }
    }
    let handle = app.handle().clone();
    if let Ok(Some(urls)) = app.deep_link().get_current() {
        keep(&handle, urls.into_iter().map(|u| u.to_string()));
    }
    let heard = handle.clone();
    app.deep_link().on_open_url(move |event| keep(&heard, event.urls().into_iter().map(|u| u.to_string())));
}

/// The links waiting, taken: each is handed to the page once.
#[tauri::command]
pub fn deep_link_take(links: State<'_, Links>) -> Vec<String> {
    links.0.lock().map(|mut held| std::mem::take(&mut *held)).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::ours;

    #[test]
    fn only_our_scheme_and_only_as_long_as_ours_are_passed_on() {
        assert!(ours("troupe://open"));
        assert!(ours("TROUPE://session/s-1?plane=https%3A%2F%2Fexample.org"));
        assert!(!ours("https://example.org"));
        assert!(!ours("troupe:open"));
        assert!(!ours("troupe"));
        assert!(!ours(&format!("troupe://open?plane={}", "a".repeat(2100))));
    }
}
