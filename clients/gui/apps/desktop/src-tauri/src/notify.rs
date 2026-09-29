// Notifications whose click is heard, and one copy of the app to hear it.
//
// The notification plugin shows a toast and lets go of it: on a desktop it cannot say
// that one was clicked (its `onAction` is fed by the phone plugins only; Decision 714).
// On Windows the shell shows the toast itself instead, through the WinRT toast the
// plugin's own library uses underneath, with a handler for `Activated` that knows which
// session the toast was about: a click tells the page to open it and brings the window
// forward. Elsewhere `notify_show` answers false and the page uses the plugin, and the
// window coming back soon after a notification is taken as the answer (`notify.ts`).
//
// A second copy of the app, from the Start menu or from a click Windows turns into a
// launch, hands its arguments to the one running and exits (the single-instance plugin,
// registered in `lib.rs`). The running copy comes forward, and a `--session=<id>` among
// those arguments is opened as a click on its notification would be.

use tauri::{AppHandle, Emitter, Manager};

/// What the page listens for, with the id of a session to open.
pub const OPEN_SESSION: &str = "troupe://open-session";

/// The session a launch names, as `--session=<id>`.
pub fn session_argument<S: AsRef<str>>(args: &[S]) -> Option<String> {
    args.iter()
        .filter_map(|a| a.as_ref().strip_prefix("--session="))
        .find(|id| !id.is_empty())
        .map(str::to_string)
}

/// The main window to the front, however it was left: minimised, hidden or behind.
pub fn bring_forward(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

/// Open a session asked for from outside the page. The page hears which one before the
/// window comes forward, so that coming forward is not taken for the answer to some other
/// notification.
pub fn open_session(app: &AppHandle, session: &str) {
    let _ = app.emit_to("main", OPEN_SESSION, session);
    bring_forward(app);
}

/// A second launch, handed over by the single-instance plugin before that copy exits.
/// A debug build does not register the plugin (`lib.rs`).
#[cfg_attr(debug_assertions, allow(dead_code))]
pub fn second_launch(app: &AppHandle, args: Vec<String>) {
    match session_argument(&args) {
        Some(session) => open_session(app, &session),
        None => bring_forward(app),
    }
}

/// Show a notification about `session`, a click on which opens it. False where this shell
/// cannot hear the click, which leaves the notification to the plugin.
#[tauri::command]
pub async fn notify_show(app: AppHandle, title: String, body: String, session: String) -> Result<bool, String> {
    #[cfg(windows)]
    {
        toast::show(app, &title, &body, session)?;
        Ok(true)
    }
    #[cfg(not(windows))]
    {
        let _ = (app, title, body, session);
        Ok(false)
    }
}

#[cfg(windows)]
mod toast {
    use std::path::Path;

    use tauri::AppHandle;
    use tauri_winrt_notification::{Duration, Toast};

    /// The toast the plugin would have shown, silent and short like the plugin's, and heard.
    pub fn show(app: AppHandle, title: &str, body: &str, session: String) -> Result<(), String> {
        let exe = tauri::utils::platform::current_exe().map_err(|e| e.to_string())?;
        let id = app_id(&app.config().identifier, exe.parent().unwrap_or(&exe));
        Toast::new(&id)
            .title(title)
            .text1(body)
            .sound(None)
            .duration(Duration::Short)
            .on_activated(move |_| {
                super::open_session(&app, &session);
                Ok(())
            })
            .show()
            .map_err(|e| format!("could not show the notification: {e}"))
    }

    /// Who the toast is from. An installed build is its bundle identifier, which its
    /// installer wrote on the Start menu shortcut; Windows drops a toast from an id no
    /// shortcut carries, so a build run from `target` borrows PowerShell's, as the
    /// plugin does.
    pub fn app_id(identifier: &str, exe_dir: &Path) -> String {
        let built = [Path::new("target").join("debug"), Path::new("target").join("release")];
        if built.iter().any(|dir| exe_dir.ends_with(dir)) {
            Toast::POWERSHELL_APP_ID.to_string()
        } else {
            identifier.to_string()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::session_argument;

    #[test]
    fn a_launch_names_a_session_with_its_argument() {
        let args = ["C:\\Programs\\troupe-desktop\\troupe-desktop.exe", "--session=s-7"];
        assert_eq!(session_argument(&args).as_deref(), Some("s-7"));
    }

    #[test]
    fn a_launch_without_one_names_none() {
        assert_eq!(session_argument(&["troupe-desktop.exe"]), None);
        assert_eq!(session_argument(&["troupe-desktop.exe", "--session="]), None);
        assert_eq!(session_argument(&["troupe-desktop.exe", "--session", "s-7"]), None);
    }

    #[cfg(windows)]
    #[test]
    fn an_installed_build_speaks_as_itself_and_one_run_from_target_borrows_powershells() {
        use super::toast::app_id;
        use std::path::Path;
        use tauri_winrt_notification::Toast;

        let id = "com.objective-mj.troupe";
        let installed = Path::new("C:\\Users\\ada\\AppData\\Local\\Programs\\troupe-desktop");
        assert_eq!(app_id(id, installed), id);
        for built in ["C:\\src\\troupe\\target\\release", "C:\\src\\troupe\\target\\debug"] {
            assert_eq!(app_id(id, Path::new(built)), Toast::POWERSHELL_APP_ID);
        }
    }
}
