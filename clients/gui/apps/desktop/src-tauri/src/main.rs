// Prevents a console window opening beside the app on Windows in a release build.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    troupe_desktop_lib::run()
}
