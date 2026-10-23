// A plane's signed version policy, checked by the shell before an update takes anything
// from it (#657).
//
// A plane signs what it tells people's machines with an Ed25519 key of its own, which this
// computer pinned at sign-in and the daemon keeps (`identity.get`'s `plane_key`). The page
// hands the shell the plane's `signed` answer as the plane sent it; the shell asks the
// daemon for the pinned key itself, checks the signature over the document's bytes, and
// only then reads the document: each component's policy, and where releases are. The page
// can hand over no URL of its own, and a URL the pinned key did not sign is refused.
//
// The twin of `Troupe.Protocol.PlaneSignature` and of the page's `planeSignature.ts`, held
// to the same vector: plain Ed25519 (RFC 8032) over the canonical JSON text, the key's
// fingerprint `SHA256:` and the unpadded base64 of its SHA-256.

use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine;
use ring::signature::{UnparsedPublicKey, ED25519};
use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::release::Policy;

/// The `signed` an answer carries.
#[derive(Clone, Debug, Deserialize)]
pub struct Signed {
    pub algorithm: String,
    #[serde(default)]
    pub fingerprint: Option<String>,
    pub document: String,
    pub signature: String,
}

/// The key this computer pinned for a plane, as the daemon keeps it: its fingerprint is
/// worked out from the key again, not read.
#[derive(Clone, Debug, Deserialize)]
pub struct PinnedKey {
    pub public_key: String,
    #[serde(default)]
    pub plane_url: String,
}

/// What the plane signed: each component's policy, and where releases are, if not GitHub.
#[derive(Debug, PartialEq)]
pub struct Word {
    pub versions: HashMap<String, Policy>,
    pub release_url: Option<String>,
}

#[derive(Deserialize)]
struct Document {
    kind: Option<String>,
    expires_at: Option<String>,
    body: Option<Body>,
}

#[derive(Deserialize)]
struct Body {
    #[serde(default)]
    versions: HashMap<String, Policy>,
    #[serde(default)]
    release: Option<Release>,
}

#[derive(Deserialize)]
struct Release {
    #[serde(default)]
    url: Option<String>,
}

/// A key's fingerprint, as the plane writes it.
pub fn fingerprint(public_key: &[u8]) -> String {
    format!("SHA256:{}", base64::engine::general_purpose::STANDARD_NO_PAD.encode(Sha256::digest(public_key)))
}

/// The same plane however its URL was spelled: the clients agree on all but a trailing slash.
pub fn same_plane(a: &str, b: &str) -> bool {
    a.trim_end_matches('/') == b.trim_end_matches('/')
}

/// The pinned key for `plane` among what the daemon said to `identity.get`, or why there is none.
pub fn pinned_for(identity: &serde_json::Value, plane: &str) -> Result<PinnedKey, String> {
    let held: Option<PinnedKey> = identity.get("plane_key").and_then(|k| serde_json::from_value(k.clone()).ok());
    match held {
        Some(key) if same_plane(&key.plane_url, plane) => Ok(key),
        _ => Err(format!(
            "the version policy from {} is signed, and this computer holds no key for that plane to check it by \
             (sign in again to pin it): the update does not follow it; nothing is installed",
            plane.trim_end_matches('/')
        )),
    }
}

/// The version policy `signed` says, checked against `pinned` as the plane at `plane`
/// signed it, as `client_versions`, and not past its time; or why it is not taken, as a
/// sentence.
pub fn verify(signed: &Signed, pinned: &PinnedKey, plane: &str, now: SystemTime) -> Result<Word, String> {
    let plane = plane.trim_end_matches('/');
    let refused = |why: String| format!("the version policy from {plane} {why}: the update does not follow it; nothing is installed");
    let b64 = base64::engine::general_purpose::STANDARD;

    let malformed = || refused("carries a signature this computer cannot read".into());
    if signed.algorithm != "ed25519" {
        return Err(malformed());
    }
    let signature = b64.decode(&signed.signature).ok().filter(|s| s.len() == 64).ok_or_else(malformed)?;
    let public_key = b64.decode(&pinned.public_key).ok().filter(|k| k.len() == 32).ok_or_else(malformed)?;
    // The pinned key's fingerprint worked out again from the key, rather than believed.
    let held = fingerprint(&public_key);

    // The signature is checked against the pinned key whatever the answer says it is by;
    // the fingerprint it names is read only to say which other key signed it.
    if UnparsedPublicKey::new(&ED25519, &public_key).verify(signed.document.as_bytes(), &signature).is_err() {
        return Err(match signed.fingerprint.as_deref() {
            Some(named) if named != held => refused(format!(
                "is signed by the key {named}, not by {held}, the key this computer pinned for that plane, and is not \
                 taken until you accept the new key"
            )),
            _ => refused("does not match its signature: it was changed after the plane signed it".into()),
        });
    }

    let document: Document = serde_json::from_str(&signed.document).map_err(|_| malformed())?;
    match document.kind.as_deref() {
        Some("client_versions") => {}
        Some(other) => return Err(refused(format!("is signed as {other}, which is something else"))),
        None => return Err(malformed()),
    }
    let expires = document.expires_at.as_deref().and_then(unix_seconds).ok_or_else(malformed)?;
    let now = now.duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    if now >= expires {
        return Err(refused(format!("was the plane's word until {}", document.expires_at.unwrap_or_default())));
    }
    let body = document.body.ok_or_else(malformed)?;
    let release_url = body.release.and_then(|r| r.url).map(|u| u.trim().trim_end_matches('/').to_string()).filter(|u| !u.is_empty());
    Ok(Word { versions: body.versions, release_url })
}

/// Seconds since 1970 of a UTC time as the plane writes one, `2026-10-25T12:00:00Z`, with
/// any fraction of a second and `+00:00` read too. `None` for anything else.
fn unix_seconds(text: &str) -> Option<i64> {
    let (date, time) = text.split_once('T')?;
    let time = time.strip_suffix('Z').or_else(|| time.strip_suffix("+00:00"))?;
    let time = time.split('.').next()?;
    let mut d = date.splitn(3, '-').map(|p| p.parse::<i64>().ok());
    let (year, month, day) = (d.next()??, d.next()??, d.next()??);
    let mut t = time.splitn(3, ':').map(|p| p.parse::<i64>().ok());
    let (hour, minute, second) = (t.next()??, t.next()??, t.next()??);
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) || hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    // Days from the civil date (Howard Hinnant's algorithm).
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(days * 86_400 + hour * 3_600 + minute * 60 + second)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::{Ed25519KeyPair, KeyPair};
    use std::time::Duration;

    /// The shared vector: the key from a seed of 32 sevens, one answer signed at a fixed time.
    const VECTOR_KEY: &str = "6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iw=";
    const VECTOR_FINGERPRINT: &str = "SHA256:/oEsEvOrTOasXbaaw1L5BssbEe9D+zPiUu9/9VImOIk";
    const VECTOR_DOCUMENT: &str = r#"{"body":{"versions":{"desktop":{"recommended":"0.22.0-beta"}}},"expires_at":"2026-10-25T12:00:00Z","kind":"client_versions","plane":"https://plane.example.test","signed_at":"2026-10-18T12:00:00Z"}"#;
    const VECTOR_SIGNATURE: &str = "vvRwPMQ83kuULmIjIoq/wVj2eB4eOnmrmU9kuHHSg1t2waFkqnOuJhEL2QIV9Gnt+SahvTn37Y7NLLprK+RtDA==";
    const PLANE: &str = "https://plane.example.test";

    fn at(text: &str) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(unix_seconds(text).unwrap() as u64)
    }

    /// A key pinned for the plane, and its fingerprint.
    fn keypair(seed: u8) -> (Ed25519KeyPair, PinnedKey, String) {
        let pair = Ed25519KeyPair::from_seed_unchecked(&[seed; 32]).unwrap();
        let public = pair.public_key().as_ref().to_vec();
        let key = PinnedKey { public_key: base64::engine::general_purpose::STANDARD.encode(&public), plane_url: PLANE.into() };
        (pair, key, fingerprint(&public))
    }

    fn sign(pair: &Ed25519KeyPair, document: &str) -> Signed {
        Signed {
            algorithm: "ed25519".into(),
            fingerprint: Some(fingerprint(pair.public_key().as_ref())),
            document: document.into(),
            signature: base64::engine::general_purpose::STANDARD.encode(pair.sign(document.as_bytes()).as_ref()),
        }
    }

    fn document(kind: &str, release: &str) -> String {
        format!(
            r#"{{"body":{{"release":{{"url":{release}}},"versions":{{"desktop":{{"blocked":[],"minimum":null,"recommended":"0.24.0-beta"}}}}}},"expires_at":"2026-10-30T12:00:00Z","kind":"{kind}","plane":"{PLANE}","signed_at":"2026-10-23T12:00:00Z"}}"#
        )
    }

    #[test]
    fn the_shared_vector_holds() {
        let (_pair, key, held) = keypair(7);
        assert_eq!((key.public_key.as_str(), held.as_str()), (VECTOR_KEY, VECTOR_FINGERPRINT));

        let signed = Signed {
            algorithm: "ed25519".into(),
            fingerprint: Some(VECTOR_FINGERPRINT.into()),
            document: VECTOR_DOCUMENT.into(),
            signature: VECTOR_SIGNATURE.into(),
        };
        let word = verify(&signed, &key, PLANE, at("2026-10-18T12:00:00Z")).unwrap();
        assert_eq!(word.versions["desktop"].recommended.as_deref(), Some("0.22.0-beta"));
        assert_eq!(word.release_url, None);
    }

    #[test]
    fn a_signed_policy_names_where_releases_are() {
        let (pair, key, _held) = keypair(7);
        let signed = sign(&pair, &document("client_versions", r#""https://plane.example.test/downloads/""#));
        let word = verify(&signed, &key, "https://plane.example.test/", at("2026-10-23T12:00:00Z")).unwrap();
        assert_eq!(word.release_url.as_deref(), Some("https://plane.example.test/downloads"));
        assert_eq!(word.versions["desktop"].recommended.as_deref(), Some("0.24.0-beta"));
    }

    #[test]
    fn a_policy_the_pinned_key_did_not_sign_is_refused_with_a_sentence() {
        let (pair, key, held) = keypair(7);
        let (other_pair, _other, other) = keypair(9);
        let now = at("2026-10-23T12:00:00Z");
        let text = document("client_versions", r#""https://mirror.example.test""#);

        let by_another = sign(&other_pair, &text);
        let why = verify(&by_another, &key, PLANE, now).unwrap_err();
        assert!(why.contains(&format!("is signed by the key {other}, not by {held}")), "{why}");
        assert!(why.ends_with("nothing is installed"), "{why}");

        let mut edited = sign(&pair, &text);
        edited.document = edited.document.replace("mirror.example.test", "elsewhere.example.test");
        assert!(verify(&edited, &key, PLANE, now).unwrap_err().contains("was changed after the plane signed it"));

        let as_defaults = sign(&pair, &document("client_defaults", "null"));
        assert!(verify(&as_defaults, &key, PLANE, now).unwrap_err().contains("is signed as client_defaults"));

        let late = at("2026-10-30T12:00:00Z");
        assert!(verify(&sign(&pair, &text), &key, PLANE, late).unwrap_err().contains("was the plane's word until 2026-10-30T12:00:00Z"));

        let mut unreadable = sign(&pair, &text);
        unreadable.signature = "not base64".into();
        assert!(verify(&unreadable, &key, PLANE, now).unwrap_err().contains("cannot read"));
    }

    #[test]
    fn the_pin_is_the_daemon_s_for_that_plane() {
        let identity = serde_json::json!({ "plane_key": { "public_key": VECTOR_KEY, "fingerprint": VECTOR_FINGERPRINT, "plane_url": PLANE } });
        assert_eq!(pinned_for(&identity, "https://plane.example.test/").unwrap().public_key, VECTOR_KEY);
        assert!(pinned_for(&identity, "https://other.example.test").unwrap_err().contains("holds no key for that plane"));
        assert!(pinned_for(&serde_json::json!({ "linked": true }), PLANE).is_err());
    }

    #[test]
    fn times_are_read_as_the_plane_writes_them() {
        assert_eq!(unix_seconds("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(unix_seconds("2026-10-25T12:00:00Z"), Some(1_792_929_600));
        assert_eq!(unix_seconds("2026-10-25T12:00:00.123+00:00"), Some(1_792_929_600));
        assert_eq!(unix_seconds("2026-10-25 12:00:00"), None);
        assert_eq!(unix_seconds("2026-13-25T12:00:00Z"), None);
    }
}
