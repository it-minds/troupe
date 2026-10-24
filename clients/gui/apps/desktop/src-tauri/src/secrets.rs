// The operating system's credential store, and the only thing the GUI is allowed to
// keep across launches: the identity provider's refresh token.
//
// Windows Credential Manager, the macOS Keychain, the Secret Service on Linux. A Linux
// box with no keyring agent running has no store at all; `Unavailable` says so instead
// of falling back to a file, because a refresh token on disk is exactly what the spec
// forbids. The app signs in again each launch there and tells the person why.
//
// Credential Manager holds at most 2560 bytes in one entry, which the keyring crate
// writes a password into as UTF-16: 1280 units. A longer value is kept in parts, in the
// layout the daemon's `Troupe.Keyring.OS` keeps one in on Windows too: `<target>/0`,
// `<target>/1`, ... hold the value's pieces in order, and `<target>` itself holds
// `troupe-parts:<n>`, their count. A value that fits, and does not itself begin with
// that marker, is one entry as it always was, so a sign-in an earlier release kept
// still reads. Elsewhere a value is one entry whatever its length.

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

/// The most of a value one entry holds, in UTF-16 units: Credential Manager's 2560 bytes.
#[cfg(windows)]
const PART_UNITS: usize = 1280;
#[cfg(not(windows))]
const PART_UNITS: usize = usize::MAX;

/// One value's entries: `None` is `<target>`, `Some(i)` its part `i`.
trait Store {
    fn get(&self, part: Option<usize>) -> Result<Option<String>, String>;
    fn set(&self, part: Option<usize>, value: &str) -> Result<(), String>;
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

    fn set(&self, part: Option<usize>, value: &str) -> Result<(), String> {
        self.entry(part)?
            .set_password(value)
            .map_err(|e| format!("could not write to the credential store: {e}"))
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

/// `value` in pieces of at most `units` UTF-16 units, never splitting a character.
fn split(value: &str, units: usize) -> Vec<String> {
    let mut parts = vec![String::new()];
    let mut used = 0;
    for c in value.chars() {
        if used + c.len_utf16() > units {
            parts.push(String::new());
            used = 0;
        }
        parts.last_mut().expect("one part at least").push(c);
        used += c.len_utf16();
    }
    parts
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

fn write(store: &impl Store, value: &str, units: usize) -> Result<(), String> {
    let had = store.get(None)?.as_deref().and_then(parts_of).unwrap_or(0);
    let fits = value.encode_utf16().count() <= units && !value.starts_with(INDEX);
    let parts = if fits { Vec::new() } else { split(value, units) };
    for (i, part) in parts.iter().enumerate() {
        store.set(Some(i), part)?;
    }
    // The index after its parts, so a reader never finds it naming one not written yet.
    let head = if fits { value.to_string() } else { format!("{INDEX}{}", parts.len()) };
    store.set(None, &head)?;
    for i in parts.len()..had {
        store.delete(Some(i))?;
    }
    Ok(())
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
pub fn secret_set(app: AppHandle, key: String, value: String) -> Result<(), String> {
    write(&Os { service: service(app.config()), key: &key }, &value, PART_UNITS)
}

#[tauri::command]
pub fn secret_delete(app: AppHandle, key: String) -> Result<(), String> {
    delete(&Os { service: service(app.config()), key: &key })
}

#[cfg(test)]
mod tests {
    use super::{delete, read, service, split, write, Store, INDEX};
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

    /// A store in memory that refuses an entry over `units` UTF-16 units, as Credential
    /// Manager does.
    struct Memory {
        units: usize,
        entries: RefCell<BTreeMap<Option<usize>, String>>,
    }

    impl Memory {
        fn new(units: usize) -> Self {
            Memory { units, entries: RefCell::new(BTreeMap::new()) }
        }
    }

    impl Store for Memory {
        fn get(&self, part: Option<usize>) -> Result<Option<String>, String> {
            Ok(self.entries.borrow().get(&part).cloned())
        }
        fn set(&self, part: Option<usize>, value: &str) -> Result<(), String> {
            if value.encode_utf16().count() > self.units {
                return Err("longer than platform limit".into());
            }
            self.entries.borrow_mut().insert(part, value.to_string());
            Ok(())
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
    fn a_value_past_one_entry_is_kept_in_parts_and_read_whole() {
        let store = Memory::new(1280);
        let value = token(4096);

        write(&store, &value, 1280).expect("kept");
        assert_eq!(store.get(None).unwrap().as_deref(), Some("troupe-parts:4"));
        assert_eq!(store.entries.borrow().len(), 5);
        assert_eq!(read(&store).unwrap().as_deref(), Some(value.as_str()));

        delete(&store).expect("cleared");
        assert!(store.entries.borrow().is_empty(), "a part was left behind");
        assert_eq!(read(&store).unwrap(), None);
    }

    #[test]
    fn a_short_value_is_one_entry_as_before_and_a_shorter_one_takes_the_parts_away() {
        let store = Memory::new(1280);
        write(&store, &token(4096), 1280).unwrap();
        write(&store, "rt-128", 1280).unwrap();
        assert_eq!(store.entries.borrow().len(), 1, "the longer value's parts stayed");
        assert_eq!(read(&store).unwrap().as_deref(), Some("rt-128"));

        // What an earlier release wrote: one entry, read as it is.
        let earlier = Memory::new(1280);
        earlier.set(None, "rt-from-0.24").unwrap();
        assert_eq!(read(&earlier).unwrap().as_deref(), Some("rt-from-0.24"));
    }

    #[test]
    fn a_value_that_looks_like_an_index_is_kept_in_parts_so_it_reads_as_itself() {
        let store = Memory::new(1280);
        let odd = format!("{INDEX}2");
        write(&store, &odd, 1280).unwrap();
        assert_eq!(read(&store).unwrap(), Some(odd));
    }

    #[test]
    fn a_part_never_splits_a_character() {
        let value = "é😀".repeat(500);
        let parts = split(&value, 1280);
        assert!(parts.iter().all(|p| p.encode_utf16().count() <= 1280));
        assert_eq!(parts.concat(), value);
    }

    #[test]
    fn a_missing_part_is_an_error_not_half_a_token() {
        let store = Memory::new(1280);
        write(&store, &token(3000), 1280).unwrap();
        store.delete(Some(1)).unwrap();
        assert!(read(&store).unwrap_err().contains("part 1 of 3 is missing"));
    }

    // Credential Manager itself, under a service of this test's own that it removes again.
    #[cfg(windows)]
    #[test]
    fn credential_manager_keeps_a_four_kilobyte_token_and_clears_it_whole() {
        use super::{Os, PART_UNITS};
        let service = format!("troupe-c41-test-{}", std::process::id());
        let store = Os { service: &service, key: "refresh:https://plane.example.test" };
        let value = token(4096);

        let kept = write(&store, &value, PART_UNITS);
        let back = read(&store);
        let parts: Vec<_> = (0..5).map(|i| store.get(Some(i)).unwrap()).collect();
        let cleared = delete(&store);
        let after = read(&store);
        let left: Vec<_> = (0..5).filter(|i| store.get(Some(*i)).unwrap().is_some()).collect();

        kept.expect("kept");
        assert_eq!(back.unwrap().as_deref(), Some(value.as_str()));
        assert_eq!(parts.iter().filter(|p| p.is_some()).count(), 4);
        cleared.expect("cleared");
        assert_eq!(after.unwrap(), None);
        assert!(left.is_empty(), "parts {left:?} were left in Credential Manager");
    }
}
