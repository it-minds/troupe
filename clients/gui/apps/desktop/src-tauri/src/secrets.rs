// The operating system's credential store: Windows Credential Manager, the macOS
// Keychain, the Secret Service on Linux.
//
// Windows Credential Manager, the macOS Keychain, the Secret Service on Linux. A Linux
// box with no keyring agent running has no store at all; `Unavailable` says so instead
// of falling back to a file. Up to release 0.30 the identity provider's refresh token
// lived here and nowhere else; it now lives in the TUI's `credentials.json`
// (src/signin.rs), one sign-in for the terminal client, this app and the daemon, and
// these commands remain so that a sign-in an earlier release kept here is moved there at
// the next launch, and cleared once it is. Nothing writes here any more.
//
// Credential Manager holds at most 2560 bytes in one entry, which the keyring crate
// wrote a password into as UTF-16: 1280 units. From release 0.25 a longer value was kept
// in parts, in the layout the daemon's `Troupe.Keyring.OS` keeps one in on Windows too:
// `<target>/0`, `<target>/1`, ... hold the value's pieces in order, and `<target>` itself
// holds `troupe-parts:<n>`, their count. A value that fit, and did not itself begin with
// that marker, is one entry. Both read back whole, and a delete takes every part.

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

/// What `<target>` holds when the value is in parts: this, then the number of parts.
const INDEX: &str = "troupe-parts:";

/// One value's entries: `None` is `<target>`, `Some(i)` its part `i`.
trait Store {
    fn get(&self, part: Option<usize>) -> Result<Option<String>, String>;
    fn delete(&self, part: Option<usize>) -> Result<(), String>;
}

/// The platform's store, for one service and key.
struct Os<'a> {
    service: &'a str,
    key: &'a str,
}

impl Os<'_> {
    // On Windows the target is all Credential Manager knows an entry by: the crate's own
    // `<key>.<service>` for the value, and that with `/<i>` for a part.
    #[cfg(windows)]
    fn entry(&self, part: Option<usize>) -> Result<Entry, String> {
        let target = match part {
            None => format!("{}.{}", self.key, self.service),
            Some(i) => format!("{}.{}/{i}", self.key, self.service),
        };
        Entry::new_with_target(&target, self.service, self.key)
            .map_err(|e| format!("credential store unavailable: {e}"))
    }

    #[cfg(not(windows))]
    fn entry(&self, part: Option<usize>) -> Result<Entry, String> {
        let user = match part {
            None => self.key.to_string(),
            Some(i) => format!("{}/{i}", self.key),
        };
        Entry::new(self.service, &user).map_err(|e| format!("credential store unavailable: {e}"))
    }
}

impl Store for Os<'_> {
    fn get(&self, part: Option<usize>) -> Result<Option<String>, String> {
        match self.entry(part)?.get_password() {
            Ok(v) => Ok(Some(v)),
            Err(KeyringError::NoEntry) => Ok(None),
            Err(e) => Err(format!("could not read from the credential store: {e}")),
        }
    }

    fn delete(&self, part: Option<usize>) -> Result<(), String> {
        match self.entry(part)?.delete_credential() {
            Ok(()) | Err(KeyringError::NoEntry) => Ok(()),
            Err(e) => Err(format!("could not clear the credential store: {e}")),
        }
    }
}

/// The number of parts `<target>`'s value says the value is in, if it is an index.
fn parts_of(value: &str) -> Option<usize> {
    value.strip_prefix(INDEX).and_then(|n| n.parse().ok())
}

fn read(store: &impl Store) -> Result<Option<String>, String> {
    let Some(value) = store.get(None)? else { return Ok(None) };
    let Some(n) = parts_of(&value) else { return Ok(Some(value)) };
    let mut joined = String::new();
    for i in 0..n {
        match store.get(Some(i))? {
            Some(part) => joined.push_str(&part),
            None => return Err(format!("could not read from the credential store: part {i} of {n} is missing")),
        }
    }
    Ok(Some(joined))
}

fn delete(store: &impl Store) -> Result<(), String> {
    if let Some(n) = store.get(None)?.as_deref().and_then(parts_of) {
        for i in 0..n {
            store.delete(Some(i))?;
        }
    }
    store.delete(None)
}

#[tauri::command]
pub fn secret_get(app: AppHandle, key: String) -> Result<Option<String>, String> {
    read(&Os { service: service(app.config()), key: &key })
}

#[tauri::command]
pub fn secret_delete(app: AppHandle, key: String) -> Result<(), String> {
    delete(&Os { service: service(app.config()), key: &key })
}

#[cfg(test)]
mod tests {
    use super::{delete, read, service, Store, INDEX};
    use std::cell::RefCell;
    use std::collections::BTreeMap;
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

    /// A store in memory, filled as an earlier release left the platform's.
    struct Memory {
        entries: RefCell<BTreeMap<Option<usize>, String>>,
    }

    impl Memory {
        fn new() -> Self {
            Memory { entries: RefCell::new(BTreeMap::new()) }
        }

        fn put(&self, part: Option<usize>, value: &str) {
            self.entries.borrow_mut().insert(part, value.to_string());
        }

        /// `value` as an earlier release kept it past one entry: its pieces of `units`
        /// characters, then the index naming how many.
        fn put_in_parts(&self, value: &str, units: usize) {
            let chars: Vec<char> = value.chars().collect();
            let parts: Vec<String> = chars.chunks(units).map(|c| c.iter().collect()).collect();
            for (i, part) in parts.iter().enumerate() {
                self.put(Some(i), part);
            }
            self.put(None, &format!("{INDEX}{}", parts.len()));
        }
    }

    impl Store for Memory {
        fn get(&self, part: Option<usize>) -> Result<Option<String>, String> {
            Ok(self.entries.borrow().get(&part).cloned())
        }
        fn delete(&self, part: Option<usize>) -> Result<(), String> {
            self.entries.borrow_mut().remove(&part);
            Ok(())
        }
    }

    fn token(len: usize) -> String {
        (0..len).map(|i| char::from(b'a' + (i % 26) as u8)).collect()
    }

    #[test]
    fn a_value_an_earlier_release_kept_in_parts_reads_whole_and_is_cleared_whole() {
        let store = Memory::new();
        let value = token(4096);
        store.put_in_parts(&value, 1280);
        assert_eq!(store.entries.borrow().len(), 5);

        assert_eq!(read(&store).unwrap().as_deref(), Some(value.as_str()));
        delete(&store).expect("cleared");
        assert!(store.entries.borrow().is_empty(), "a part was left behind");
        assert_eq!(read(&store).unwrap(), None);
    }

    #[test]
    fn a_value_kept_in_one_entry_reads_as_it_is() {
        let store = Memory::new();
        store.put(None, "rt-from-0.24");
        assert_eq!(read(&store).unwrap().as_deref(), Some("rt-from-0.24"));
        delete(&store).expect("cleared");
        assert_eq!(read(&store).unwrap(), None);
    }

    // A value that itself began with the marker was always kept in parts.
    #[test]
    fn a_value_that_looks_like_an_index_reads_as_itself() {
        let store = Memory::new();
        let odd = format!("{INDEX}2");
        store.put_in_parts(&odd, 1280);
        assert_eq!(read(&store).unwrap(), Some(odd));
    }

    #[test]
    fn a_missing_part_is_an_error_not_half_a_token() {
        let store = Memory::new();
        store.put_in_parts(&token(3000), 1280);
        store.delete(Some(1)).unwrap();
        assert!(read(&store).unwrap_err().contains("part 1 of 3 is missing"));
    }

    // Credential Manager itself, under a service of this test's own that it removes again:
    // a four-kilobyte value in the parts an earlier release wrote, read whole, cleared whole.
    #[cfg(windows)]
    #[test]
    fn credential_manager_reads_a_four_kilobyte_token_in_parts_and_clears_it_whole() {
        use super::Os;
        let service = format!("troupe-c41-test-{}", std::process::id());
        let store = Os { service: &service, key: "refresh:https://plane.example.test" };
        let value = token(4096);
        let put = |part: Option<usize>, v: &str| store.entry(part).and_then(|e| e.set_password(v).map_err(|e| e.to_string()));

        let chars: Vec<char> = value.chars().collect();
        let kept = chars
            .chunks(1280)
            .enumerate()
            .try_for_each(|(i, c)| put(Some(i), &c.iter().collect::<String>()))
            .and_then(|()| put(None, &format!("{INDEX}4")));
        let back = read(&store);
        let cleared = delete(&store);
        let after = read(&store);
        let left: Vec<_> = (0..5).filter(|i| store.get(Some(*i)).unwrap().is_some()).collect();

        kept.expect("kept");
        assert_eq!(back.unwrap().as_deref(), Some(value.as_str()));
        cleared.expect("cleared");
        assert_eq!(after.unwrap(), None);
        assert!(left.is_empty(), "parts {left:?} were left in Credential Manager");
    }

    // The keychain on a Mac and the Secret Service on Linux, under a service of this
    // test's own that it removes again: a value an earlier release kept, read and deleted.
    // Skipped, and said, on a machine with no store; CI's keyring job sets
    // `TROUPE_KEYRING_REQUIRE`, so a store that did not come up there fails instead.
    #[cfg(not(windows))]
    #[test]
    fn the_platform_store_reads_a_four_kilobyte_token_and_clears_it() {
        use super::Os;
        let service = format!("troupe-e41-test-{}", std::process::id());
        let store = Os { service: &service, key: "refresh:https://plane.example.test" };

        if let Err(e) = store.get(None) {
            let required = matches!(std::env::var("TROUPE_KEYRING_REQUIRE").as_deref(), Ok("1") | Ok("true"));
            assert!(!required, "this job starts a credential store, and it answered: {e}");
            eprintln!("SKIPPED: no credential store on this machine ({e})");
            return;
        }

        let value = token(4096);
        let kept = store.entry(None).and_then(|e| e.set_password(&value).map_err(|e| e.to_string()));
        let back = read(&store);
        let cleared = delete(&store);
        let after = read(&store);
        // Whatever failed above, nothing of the test's stays in the person's store.
        let _ = store.delete(None);

        kept.expect("kept");
        assert_eq!(back.unwrap().as_deref(), Some(value.as_str()));
        cleared.expect("cleared");
        assert_eq!(after.unwrap(), None);
    }
}
