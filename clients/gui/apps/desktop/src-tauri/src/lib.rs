// The desktop shell. It holds no application logic: the GUI is the same web bundle a
// browser loads, and this process exists to give it the three things a tab cannot have.
//
//   the sign-in            the identity provider's refresh token, in the TUI's
//                          `credentials.json`, so one sign-in serves the terminal
//                          client, this app and the daemon (src/signin.rs); the OS
//                          credential store only to move an earlier sign-in out of
//   an opener              a webview does nothing with `target="_blank"`, and the
//                          device grant is unusable unless its link reaches a browser
//   an HTTP client         outside the webview, so a plane needs no CORS entry for
//                          `tauri://localhost`
//   the local daemon       reading `daemon.json` to find the port and token of the
//                          daemon on this computer, starting it if it is not running,
//                          and picking a directory to work in
//   notifications          WebView2 refuses a page's own, so a session that finishes or
//                          asks while nobody is looking is said through the OS's, and on
//                          Windows a click on one opens its session (src/notify.rs)
//   its own update         a release whose manifest the release key signed, checked
//                          here, installed by Tauri's updater, with the daemon beside the
//                          app swapped in first (src/update.rs, src/release.rs), from
//                          where a plane says releases are only as its pinned key signed
//                          it (src/plane_word.rs)
//   an agent's file        a person's or a repository's, in the editor the system opens
//                          Markdown with, and no other file (src/agent_file.rs)
//   an artifact's window   an artifact shown from its own host in a window of its own,
//                          granted nothing, never fetched into the app (src/artifact_window.rs)
//   its window's place     the main window opens at the size and place it was closed at,
//                          on a screen that still exists (src/window.rs)
//   its own links          `troupe://` opens the app, or brings it forward, at a session,
//                          an artifact or a plane's sign-in (src/deep_link.rs)
//
// Each one is reached through `TroupeShell` in `src/shell.ts`, which the shell installs
// on `window.troupe` at startup. Nothing else in the bundle knows this process exists.
//
mod agent_file;
mod artifact_window;
mod daemon;
mod deep_link;
mod file_save;
mod notify;
mod plane_word;
mod release;
mod secrets;
mod update;
mod signin;
mod window;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = tauri::Builder::default();
    // First, as the plugin asks: a second copy hands its arguments over and exits before
    // anything else of it starts. Not in a debug build, which is a developer's second copy
    // on purpose, beside the installed app of the same identifier.
    #[cfg(all(desktop, not(debug_assertions)))]
    let builder = builder.plugin(tauri_plugin_single_instance::init(|app, args, _cwd| notify::second_launch(app, args)));
    builder
        // After single-instance, as the plugin asks, so a second launch's link reaches
        // this copy; driven from `deep_link.rs`, and the page is granted none of its commands.
        .plugin(tauri_plugin_deep_link::init())
        .manage(deep_link::Links::default())
        .setup(|app| {
            deep_link::setup(app);
            Ok(())
        })
        .plugin(tauri_plugin_http::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        // Driven from `update.rs` alone, with the key and the release it checked; the
        // page is granted none of the plugin's own commands.
        .plugin(tauri_plugin_updater::Builder::new().build())
        // Kept and restored by the shell alone; the page is granted none of its commands.
        .plugin(window::plugin())
        .manage(update::Updates::default())
        .invoke_handler(tauri::generate_handler![
            secrets::secret_get,
            secrets::secret_set,
            secrets::secret_delete,
            agent_file::agent_file_open,
            artifact_window::artifact_window_open,
            signin::signin_get,
            signin::signin_set,
            signin::signin_clear,
            signin::signin_current,
            signin::signin_lock,
            signin::signin_unlock,
            daemon::daemon_endpoint,
            daemon::daemon_start,
            file_save::file_save,
            notify::notify_show,
            update::update_check,
            update::update_download,
            update::update_install,
            deep_link::deep_link_take,
            shell_platform
        ])
        .run(tauri::generate_context!())
        .expect("the Troupe desktop shell failed to start");
}

/// Where the app runs, in the daemon's words (`windows/x86_64`, `macos/aarch64`,
/// `linux/x86_64`): what the page's `initialize` to a plane gives as
/// `client_info.platform`, as the daemon's own does. Takes nothing and reads nothing.
#[tauri::command]
fn shell_platform() -> String {
    platform()
}

fn platform() -> String {
    format!("{}/{}", std::env::consts::OS, std::env::consts::ARCH)
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_platform_is_said_as_the_daemon_says_it() {
        let platform = super::platform();
        let (os, arch) = platform.split_once('/').expect("an os and an arch");
        assert!(["windows", "macos", "linux"].contains(&os), "{platform}");
        assert!(!arch.is_empty() && !arch.contains('/'), "{platform}");
    }
}
