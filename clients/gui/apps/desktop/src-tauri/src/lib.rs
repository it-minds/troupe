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
//
// Each one is reached through `TroupeShell` in `src/shell.ts`, which the shell installs
// on `window.troupe` at startup. Nothing else in the bundle knows this process exists.
//
mod daemon;
mod notify;
mod secrets;

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
        .invoke_handler(tauri::generate_handler![
            secrets::secret_get,
            secrets::secret_set,
            secrets::secret_delete,
            daemon::daemon_endpoint,
            daemon::daemon_start,
            notify::notify_show
        ])
        .run(tauri::generate_context!())
        .expect("the Troupe desktop shell failed to start");
}
