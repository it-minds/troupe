// The desktop shell. It holds no application logic: the GUI is the same web bundle a
// browser loads, and this process exists to give it the three things a tab cannot have.
//
//   the credential store   where the identity provider's refresh token lives, and the
//                          only thing the GUI keeps across launches
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
//
// Each one is reached through `TroupeShell` in `src/shell.ts`, which the shell installs
// on `window.troupe` at startup. Nothing else in the bundle knows this process exists.
//
mod agent_file;
mod daemon;
mod notify;
mod plane_word;
mod release;
mod secrets;
mod update;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = tauri::Builder::default();
    // First, as the plugin asks: a second copy hands its arguments over and exits before
    // anything else of it starts. Not in a debug build, which is a developer's second copy
    // on purpose, beside the installed app of the same identifier.
    #[cfg(all(desktop, not(debug_assertions)))]
    let builder = builder.plugin(tauri_plugin_single_instance::init(|app, args, _cwd| notify::second_launch(app, args)));
    builder
        .plugin(tauri_plugin_http::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        // Driven from `update.rs` alone, with the key and the release it checked; the
        // page is granted none of the plugin's own commands.
        .plugin(tauri_plugin_updater::Builder::new().build())
        .manage(update::Updates::default())
        .invoke_handler(tauri::generate_handler![
            secrets::secret_get,
            secrets::secret_set,
            secrets::secret_delete,
            agent_file::agent_file_open,
            daemon::daemon_endpoint,
            daemon::daemon_start,
            notify::notify_show,
            update::update_check,
            update::update_download,
            update::update_install,
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
