// The main window's size and place, kept from one launch to the next by the window-state
// plugin rather than code of our own: it saves them when the window closes and when the
// app exits, and puts them back as the window is made.
//
//   first launch      nothing is saved, so the window is where `tauri.conf.json` puts it:
//                     its default size, centred on the screen it opens on
//   later launches    the size and place it was closed at, and maximised if it was;
//                     the place only when a screen that exists still holds a corner of
//                     the window, so one closed on a screen that has since gone (a laptop
//                     off its dock) opens where the first launch did, on the screen it
//                     starts on, at the size it was closed at
//
// Kept in `.window-state.json` in the app's own directory under its identifier (the
// plugin's file, beside nothing secret: it is not in the credential store and the page
// cannot read it). Only `main`: an artifact's window is made where its opener asks and
// is not written down. Whether it was visible, its decorations and full screen are not
// kept, since the shell sets those and a window restored hidden would be a lost one.

use tauri::Runtime;
use tauri_plugin_window_state::{Builder, StateFlags};

/// The one window whose size and place are kept.
const MAIN: &str = "main";

/// What is kept of it.
pub(crate) fn kept() -> StateFlags {
    StateFlags::SIZE | StateFlags::POSITION | StateFlags::MAXIMIZED
}

pub(crate) fn remembered(label: &str) -> bool {
    label == MAIN
}

pub(crate) fn plugin<R: Runtime>() -> tauri::plugin::TauriPlugin<R> {
    Builder::new()
        .with_state_flags(kept())
        .with_filter(remembered)
        .build()
}

#[cfg(test)]
mod tests {
    use super::{kept, remembered};
    use tauri_plugin_window_state::StateFlags;

    fn main_window() -> serde_json::Value {
        let config: serde_json::Value =
            serde_json::from_str(include_str!("../tauri.conf.json")).expect("tauri.conf.json parses");
        config["app"]["windows"]
            .as_array()
            .expect("windows")
            .iter()
            .find(|window| window["label"] == super::MAIN)
            .cloned()
            .expect("a main window")
    }

    // With nothing saved, the plugin leaves the window where the config made it, and it
    // leaves the place there too when the screen the window was saved on is gone:
    // centred, not where the system cascades a new window.
    #[test]
    fn the_first_launch_opens_centred_at_the_default_size() {
        let window = main_window();
        assert_eq!(window["center"], true);
        assert_eq!((window["width"].as_u64(), window["height"].as_u64()), (Some(1100), Some(760)));
    }

    #[test]
    fn the_size_place_and_maximised_state_are_kept_and_nothing_else() {
        let flags = kept();
        assert!(flags.contains(StateFlags::SIZE | StateFlags::POSITION | StateFlags::MAXIMIZED));
        assert!(!flags.intersects(StateFlags::VISIBLE | StateFlags::DECORATIONS | StateFlags::FULLSCREEN));
    }

    #[test]
    fn only_the_main_window_is_remembered() {
        assert!(remembered("main"));
        assert!(!remembered(&crate::artifact_window::label("art-1a2b")));
    }
}
