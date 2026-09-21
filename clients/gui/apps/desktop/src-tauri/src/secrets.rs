// The operating system's credential store, and the only thing the GUI is allowed to
// keep across launches: the identity provider's refresh token.
//
// Windows Credential Manager, the macOS Keychain, the Secret Service on Linux. A Linux
// box with no keyring agent running has no store at all; `Unavailable` says so instead
// of falling back to a file, because a refresh token on disk is exactly what the spec
// forbids. The app signs in again each launch there and tells the person why.

use keyring::{Entry, Error as KeyringError};

const SERVICE: &str = "com.objective-mj.troupe";

fn entry(key: &str) -> Result<Entry, String> {
    Entry::new(SERVICE, key).map_err(|e| format!("credential store unavailable: {e}"))
}

#[tauri::command]
pub fn secret_get(key: String) -> Result<Option<String>, String> {
    match entry(&key)?.get_password() {
        Ok(v) => Ok(Some(v)),
        Err(KeyringError::NoEntry) => Ok(None),
        Err(e) => Err(format!("could not read from the credential store: {e}")),
    }
}

#[tauri::command]
pub fn secret_set(key: String, value: String) -> Result<(), String> {
    entry(&key)?
        .set_password(&value)
        .map_err(|e| format!("could not write to the credential store: {e}"))
}

#[tauri::command]
pub fn secret_delete(key: String) -> Result<(), String> {
    match entry(&key)?.delete_credential() {
        Ok(()) | Err(KeyringError::NoEntry) => Ok(()),
        Err(e) => Err(format!("could not clear the credential store: {e}")),
    }
}
