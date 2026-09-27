// The operating system's credential store, and the only thing the GUI is allowed to
// keep across launches: the identity provider's refresh token.
//
// Windows Credential Manager, the macOS Keychain, the Secret Service on Linux. A Linux
// box with no keyring agent running has no store at all; `Unavailable` says so instead
// of falling back to a file, because a refresh token on disk is exactly what the spec
// forbids. The app signs in again each launch there and tells the person why.

use keyring::{Entry, Error as KeyringError};
use tauri::{AppHandle, Config};

/// The name this build's entries are kept under: its bundle identifier. A build made
/// with another identifier, as a test build installed beside the real app is, keeps a
/// sign-in of its own instead of reading and rotating the real app's. The shipped
/// identifier is the fixed name every earlier release used, so an upgrade finds its
/// sign-in where it left it.
fn service(config: &Config) -> &str {
    &config.identifier
}

fn entry(app: &AppHandle, key: &str) -> Result<Entry, String> {
    Entry::new(service(app.config()), key)
        .map_err(|e| format!("credential store unavailable: {e}"))
}

#[tauri::command]
pub fn secret_get(app: AppHandle, key: String) -> Result<Option<String>, String> {
    match entry(&app, &key)?.get_password() {
        Ok(v) => Ok(Some(v)),
        Err(KeyringError::NoEntry) => Ok(None),
        Err(e) => Err(format!("could not read from the credential store: {e}")),
    }
}

#[tauri::command]
pub fn secret_set(app: AppHandle, key: String, value: String) -> Result<(), String> {
    entry(&app, &key)?
        .set_password(&value)
        .map_err(|e| format!("could not write to the credential store: {e}"))
}

#[tauri::command]
pub fn secret_delete(app: AppHandle, key: String) -> Result<(), String> {
    match entry(&app, &key)?.delete_credential() {
        Ok(()) | Err(KeyringError::NoEntry) => Ok(()),
        Err(e) => Err(format!("could not clear the credential store: {e}")),
    }
}

#[cfg(test)]
mod tests {
    use super::service;
    use tauri::Config;

    fn shipped() -> Config {
        serde_json::from_str(include_str!("../tauri.conf.json")).expect("tauri.conf.json parses")
    }

    // Earlier releases kept the sign-in under this name, fixed in the code. The shipped
    // identifier is the same string, which is why an upgrade needs no migration; if it
    // ever changes, the old entry has to be moved to the new name first.
    #[test]
    fn the_shipped_app_keeps_its_sign_in_where_earlier_releases_put_it() {
        assert_eq!(service(&shipped()), "com.objective-mj.troupe");
    }

    // What `tauri build --config '{"identifier": ...}'` makes: the same app under
    // another identifier, with a store of its own.
    #[test]
    fn a_build_with_another_identifier_keeps_its_own() {
        let mut renamed = shipped();
        renamed.identifier = "com.objective-mj.troupe.fix224".into();

        assert_eq!(service(&renamed), "com.objective-mj.troupe.fix224");
        assert_ne!(service(&renamed), service(&shipped()));
    }
}
