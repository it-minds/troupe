// The desktop shell. It holds no application logic: the GUI is the same web bundle a
// browser loads, and this process exists to give it four things a tab cannot have — an
// HTTP client outside the webview, a way to reach the real browser, a `troupe://` URL
// scheme, and exactly one instance of itself.
//
// …and the operating system's credential store, which is where the identity provider's
// refresh token lives and the only thing the GUI keeps across launches.
//
// Deliberately absent, until the local daemon lands (spec stage 2): reading
// `daemon.json`, spawning `troupe`, and a directory picker. Each is a command here and
// a member on the `Shell` interface in `src/shell.ts`.

mod secrets;

use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let mut builder = tauri::Builder::default();

    // Must be the first plugin registered: it decides whether this process lives at all.
    #[cfg(desktop)]
    {
        builder = builder.plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            // A second launch — often the OS delivering a deep link. The `deep-link`
            // feature of this plugin forwards the URL to the running instance for us;
            // all that is left is to put the window in front of the person.
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.unminimize();
                let _ = window.show();
                let _ = window.set_focus();
            }
        }));
    }

    builder
        .plugin(tauri_plugin_http::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_deep_link::init())
        .invoke_handler(tauri::generate_handler![
            secrets::secret_get,
            secrets::secret_set,
            secrets::secret_delete
        ])
        .setup(|_app| {
            // macOS registers the scheme from Info.plist at install time. Windows and
            // Linux need it written to the registry / desktop entry, and a development
            // build has never been installed, so do it at startup there.
            #[cfg(any(windows, target_os = "linux"))]
            {
                use tauri_plugin_deep_link::DeepLinkExt;
                // Failing here is not fatal: the app works, it just cannot be
                // preconfigured by a link until it has been installed properly.
                if let Err(e) = _app.deep_link().register_all() {
                    eprintln!("could not register the troupe:// scheme: {e}");
                }
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("the Troupe desktop shell failed to start");
}
