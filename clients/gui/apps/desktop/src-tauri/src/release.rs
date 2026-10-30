// A release's signed manifest, read as the terminal and the daemon read it (#66,
// Decisions 865 and 874).
//
// A release carries `manifest.json`, which names every file it publishes with its size and
// sha256, and `manifest.json.minisig`, signed with the release key CI holds. This build
// trusts the keys `apps/troupe_core/priv/release-keys.txt` held when it was compiled, and
// no others: nothing read at run time adds one (Decision 865). What this file decides is
// whether a release is one of those keys' and what in it is for this computer; fetching
// and installing are `update.rs`'s.
//
// It is the Elixir verifier's twin (`Troupe.Release.Minisign` and `Troupe.Release.Manifest`),
// down to the rule for a key rotation: a `.minisig` may hold several signature blocks, one
// per key; at least one must be by a key this build trusts, every block by a trusted key
// must hold, and a block by a key it does not know is passed over. The shared test vectors
// in `test/fixtures/release/` hold the two to the same answers (the tests below).

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use minisign_verify::{PublicKey, Signature};
use semver::Version;
use serde::Deserialize;
use sha2::{Digest, Sha256};

/// The release keys this build trusts, as the repository held them when it was compiled.
pub const RELEASE_KEYS: &str = include_str!("../../../../../../apps/troupe_core/priv/release-keys.txt");

/// The release this build is, as releases are numbered (`0.15.0-beta`). The bundle's own
/// version drops the pre-release part, which Windows installers refuse, so it is not the
/// one to compare.
const VERSION_FILE: &str = include_str!("../../../../../../VERSION");

/// This build's release version.
pub fn current_version() -> &'static str {
    VERSION_FILE.trim()
}

/// A manifest and its signature are a few kilobytes; anything much bigger is not one.
pub const SMALL: usize = 1_048_576;

/// One key this build trusts.
#[derive(Clone, Debug)]
pub struct TrustedKey {
    /// The base64 line minisign writes, `RW...`.
    pub line: String,
    pub id: [u8; 8],
    key: PublicKey,
}

impl TrustedKey {
    /// The key's id as minisign prints it.
    pub fn id_text(&self) -> String {
        key_id_text(&self.id)
    }

    /// The key as Tauri's updater takes it: the `.pub` file, base64-encoded.
    pub fn tauri_pubkey(&self) -> String {
        STANDARD.encode(format!("untrusted comment: minisign public key {}\n{}\n", self.id_text(), self.line))
    }
}

/// minisign's key id: the eight bytes read as a little-endian number, in hexadecimal.
pub fn key_id_text(id: &[u8; 8]) -> String {
    format!("{:016X}", u64::from_le_bytes(*id))
}

/// The keys in a list of them, as `release-keys.txt` holds them: a base64 line each, `#`
/// starting a comment, the first the current key.
pub fn parse_key_list(text: &str) -> Result<Vec<TrustedKey>, String> {
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(|line| parse_public_key(line).map_err(|why| format!("{line} {why}")))
        .collect()
}

/// A public key from its base64 line (`RW...`), or from a `.pub` file whole.
pub fn parse_public_key(text: &str) -> Result<TrustedKey, String> {
    let line = text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with("untrusted comment:"))
        .last()
        .ok_or("is empty: no minisign public key in it")?;
    let bytes = STANDARD.decode(line).map_err(|_| "is not minisign's: a line is not base64")?;
    let key = PublicKey::from_base64(line).map_err(|_| "is not a minisign public key: it does not decode to an Ed25519 key")?;
    if bytes.len() != 42 {
        return Err("is not a minisign public key: it does not decode to an Ed25519 key".into());
    }
    let mut id = [0u8; 8];
    id.copy_from_slice(&bytes[2..10]);
    Ok(TrustedKey { line: line.to_string(), id, key })
}

/// The keys this build trusts.
pub fn trusted_keys() -> Vec<TrustedKey> {
    // A list that does not parse is a build that trusts nothing, which installs nothing.
    parse_key_list(RELEASE_KEYS).unwrap_or_default()
}

/// One signature block of a `.minisig`, and the id of the key that made it.
struct Block {
    id: [u8; 8],
    signature: Signature,
}

fn blocks(text: &str) -> Result<Vec<Block>, String> {
    let lines: Vec<&str> = text.lines().map(|l| l.trim_end_matches('\r')).filter(|l| !l.is_empty()).collect();
    if lines.is_empty() {
        return Err("has no signature: its .minisig is empty".into());
    }
    if lines.len() % 4 != 0 {
        return Err("has a signature file that is not a minisign signature: a signature is four lines".into());
    }
    lines
        .chunks(4)
        .map(|chunk| {
            let not_one = || "has a signature file that is not a minisign signature".to_string();
            if !chunk[0].starts_with("untrusted comment: ") || !chunk[2].starts_with("trusted comment: ") {
                return Err(format!(
                    "{}: the lines are not an untrusted comment, a signature, a trusted comment and a signature",
                    not_one()
                ));
            }
            let bytes = STANDARD.decode(chunk[1]).map_err(|_| not_one())?;
            if bytes.len() != 74 || !(bytes[0] == b'E' && (bytes[1] == b'D' || bytes[1] == b'd')) {
                return Err(format!("{}: not an Ed25519 one", not_one()));
            }
            let signature = Signature::decode(&chunk.join("\n")).map_err(|_| not_one())?;
            let mut id = [0u8; 8];
            id.copy_from_slice(&bytes[2..10]);
            Ok(Block { id, signature })
        })
        .collect()
}

/// The key that made the first block of a signature: what Tauri's updater checks, since
/// it reads the first block alone.
pub fn signer(minisig: &str) -> Result<[u8; 8], String> {
    blocks(minisig)?.first().map(|b| b.id).ok_or_else(|| "has no signature".into())
}

/// Check `message` against a `.minisig` with the keys this build trusts. The answer is the
/// ids of the trusted keys that signed it; a refusal is a sentence finishing "the manifest
/// ...".
pub fn verify(message: &[u8], minisig: &str, keys: &[TrustedKey]) -> Result<Vec<String>, String> {
    if keys.is_empty() {
        return Err("cannot be checked: this build trusts no release key, so it installs no release".into());
    }
    let blocks = blocks(minisig)?;
    let ours: Vec<(&Block, &TrustedKey)> =
        blocks.iter().filter_map(|b| keys.iter().find(|k| k.id == b.id).map(|k| (b, k))).collect();
    if ours.is_empty() {
        let signers: Vec<String> = blocks.iter().map(|b| key_id_text(&b.id)).collect();
        let trusted: Vec<String> = keys.iter().map(TrustedKey::id_text).collect();
        return Err(format!(
            "is signed by key {}, which this build does not trust (it trusts {})",
            signers.join(", "),
            trusted.join(", ")
        ));
    }
    // Each block against its own key, so a refusal here is a signature that does not hold.
    for (block, key) in &ours {
        if key.key.verify(message, &block.signature, true).is_err() {
            return Err(format!(
                "does not match its signature by key {}: it, or the signature's trusted comment, was changed after it was signed",
                key.id_text()
            ));
        }
    }
    Ok(ours.iter().map(|(_, k)| k.id_text()).collect())
}

/// One file a release publishes.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct Artifact {
    pub component: String,
    pub target: Option<String>,
    pub file: String,
    pub size: u64,
    pub sha256: String,
}

/// A release's manifest, format 1.
#[derive(Clone, Debug)]
pub struct Manifest {
    pub version: String,
    pub artifacts: Vec<Artifact>,
    /// What the release says it works with, signed with the rest; `None` in a manifest
    /// from before releases said, which is not known to support any plane.
    pub supports: Option<Supports>,
}

/// The plane versions a release's clients work with, as a requirement, and the protocol
/// version they speak.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct Supports {
    pub plane: String,
    pub protocol: String,
}

#[derive(Deserialize)]
struct ManifestJson {
    format: serde_json::Value,
    version: String,
    artifacts: Vec<serde_json::Value>,
    #[serde(default)]
    supports: Option<serde_json::Value>,
}

/// A manifest from its bytes, checked for the shape a client relies on. A refusal is a
/// sentence finishing "the signed manifest ...".
pub fn decode_manifest(bytes: &[u8]) -> Result<Manifest, String> {
    let json: ManifestJson = serde_json::from_slice(bytes).map_err(|_| "is not a release manifest".to_string())?;
    if json.format != serde_json::json!(1) {
        return Err(format!(
            "is in format {}, which this build does not read (it reads 1); a newer desktop app does",
            json.format
        ));
    }
    let artifacts = json
        .artifacts
        .into_iter()
        .map(|entry| {
            let artifact: Artifact = serde_json::from_value(entry)
                .map_err(|_| "has an artifact without its component, target, file, size and sha256".to_string())?;
            if !plain_name(&artifact.file) || !sha256_hex(&artifact.sha256) {
                return Err(format!("names a file {:?} it cannot be about", artifact.file));
            }
            Ok(artifact)
        })
        .collect::<Result<Vec<_>, String>>()?;
    let supports = match json.supports {
        None | Some(serde_json::Value::Null) => None,
        Some(value) => {
            let supports: Supports =
                serde_json::from_value(value).map_err(|_| "has a supports without its plane and protocol".to_string())?;
            if requirement_holds(&supports.plane, "0.0.0").is_none() {
                return Err(format!("says it supports planes {:?}, which is not a requirement", supports.plane));
            }
            Some(supports)
        }
    };
    Ok(Manifest { version: json.version, artifacts, supports })
}

/// Whether `version` meets a requirement a manifest carries: comparisons joined by `and`,
/// each `>=`, `>`, `<=`, `<` or `==` and a version, ordered as SemVer orders them (a
/// pre-release before its release), as `Troupe.Release.Manifest.supports?/2` reads it.
/// `None` where the requirement or the version is not one that can be read.
pub fn requirement_holds(requirement: &str, version: &str) -> Option<bool> {
    let version = Version::parse(version).ok()?;
    let mut holds = true;
    for part in requirement.split(" and ") {
        let part = part.trim();
        let (op, rest) = [">=", "<=", "==", ">", "<"].iter().find_map(|op| part.strip_prefix(op).map(|rest| (*op, rest)))?;
        let rest = rest.trim();
        if rest.is_empty() || rest.contains(char::is_whitespace) {
            return None;
        }
        let bound = Version::parse(rest).ok()?;
        holds &= match op {
            ">=" => version >= bound,
            "<=" => version <= bound,
            "==" => version == bound,
            ">" => version > bound,
            _ => version < bound,
        };
    }
    Some(holds)
}

// A file name is where a client puts what it downloads: never a path.
fn plain_name(file: &str) -> bool {
    !file.is_empty() && file != "." && file != ".." && !file.contains('/') && !file.contains('\\')
}

fn sha256_hex(hex: &str) -> bool {
    hex.len() == 64 && hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

impl Manifest {
    /// Whether the release supports a plane at `plane_version`: `None` where the manifest
    /// says nothing of planes or the plane's version cannot be read.
    pub fn supports_plane(&self, plane_version: Option<&str>) -> Option<bool> {
        requirement_holds(&self.supports.as_ref()?.plane, plane_version?)
    }

    /// The entry for a file, by name.
    pub fn file(&self, name: &str) -> Option<&Artifact> {
        self.artifacts.iter().find(|a| a.file == name)
    }

    /// The artifact of `component` built for `target`.
    pub fn find(&self, component: &str, target: &str) -> Option<&Artifact> {
        self.artifacts.iter().find(|a| a.component == component && a.target.as_deref() == Some(target))
    }

    /// The desktop app's update for this computer: the per-user setup on Windows, the app
    /// archive on macOS, the AppImage on Linux, which is what each installer puts there.
    pub fn desktop_update(&self, platform: &Platform) -> Option<&Artifact> {
        let (target, suffix) = match (platform.os, platform.arch) {
            ("windows", "x86_64") => ("windows_x86_64", "_x64-setup.exe"),
            ("macos", _) => ("macos_universal", "_universal.app.tar.gz"),
            ("linux", "x86_64") => ("linux_x86_64", "_amd64.AppImage"),
            _ => return None,
        };
        self.artifacts
            .iter()
            .find(|a| a.component == "desktop" && a.target.as_deref() == Some(target) && a.file.ends_with(suffix))
    }
}

/// Whether `bytes` are the artifact: its size first, then its sha256.
pub fn check_bytes(artifact: &Artifact, bytes: &[u8]) -> Result<(), String> {
    if bytes.len() as u64 != artifact.size {
        return Err(format!("{} is {} bytes, and the signed manifest says {}", artifact.file, bytes.len(), artifact.size));
    }
    let actual = sha256_of(bytes);
    if actual != artifact.sha256 {
        return Err(format!(
            "{} is not the file the signed manifest names (sha256 {actual}, not {})",
            artifact.file, artifact.sha256
        ));
    }
    Ok(())
}

pub fn sha256_of(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// This computer as a release names its builds.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Platform {
    pub os: &'static str,
    pub arch: &'static str,
}

impl Platform {
    pub fn this() -> Platform {
        let os = if cfg!(windows) {
            "windows"
        } else if cfg!(target_os = "macos") {
            "macos"
        } else {
            "linux"
        };
        let arch = if cfg!(target_arch = "aarch64") { "aarch64" } else { "x86_64" };
        Platform { os, arch }
    }

    /// The daemon's and the terminal's target here: `windows_x86_64`, `macos_aarch64`, ...
    pub fn target(&self) -> String {
        format!("{}_{}", self.os, self.arch)
    }
}

/// Whether `a` is older than `b` as SemVer orders them; false where either is not one.
pub fn older(a: &str, b: &str) -> bool {
    matches!((Version::parse(a), Version::parse(b)), (Ok(a), Ok(b)) if a < b)
}

/// Whether what is installed at `from` should be replaced by `to`, moving only forward. A
/// version SemVer cannot read is replaced, since nothing says it is newer.
pub fn wanted(from: &str, to: &str) -> bool {
    if from == to {
        return false;
    }
    match (Version::parse(from), Version::parse(to)) {
        (Ok(from), Ok(to)) => from < to,
        _ => true,
    }
}

/// A plane's policy for one kind of client (Decision 868): what may be installed. Its
/// recommended version is what an update asks for, read from the plane's signed answer.
#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
pub struct Policy {
    #[serde(default)]
    pub recommended: Option<String>,
    #[serde(default)]
    pub minimum: Option<String>,
    #[serde(default)]
    pub blocked: Vec<String>,
}

/// What a policy says to one version, as `Troupe.Protocol.ClientUpdate.judge/2` does.
#[derive(Debug, PartialEq)]
pub enum Judgement {
    Blocked,
    BelowMinimum,
    Served,
}

pub fn judge(policy: &Policy, version: &str) -> Judgement {
    if policy.blocked.iter().any(|b| b == version) {
        Judgement::Blocked
    } else if policy.minimum.as_deref().is_some_and(|m| older(version, m)) {
        Judgement::BelowMinimum
    } else {
        Judgement::Served
    }
}

/// The tag a release's `/releases/latest` redirect names, from its `Location`.
pub fn latest_tag(location: &str) -> Option<String> {
    let rest = location.split(['?', '#']).next()?;
    let tag = rest.rsplit_once("/releases/tag/v")?.1;
    (!tag.is_empty() && !tag.contains('/')).then(|| tag.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::{Path, PathBuf};

    fn fixtures() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../../../test/fixtures/release")
    }

    fn read(name: &str) -> Vec<u8> {
        std::fs::read(fixtures().join(name)).unwrap_or_else(|e| panic!("{name}: {e}"))
    }

    #[derive(Deserialize)]
    struct Vectors {
        signatures: Vec<SignatureCase>,
        artifacts: Vec<ArtifactCase>,
    }

    #[derive(Deserialize)]
    struct SignatureCase {
        name: String,
        signature: String,
        manifest: String,
        trusted: Vec<String>,
        expect: String,
    }

    #[derive(Deserialize)]
    struct ArtifactCase {
        name: String,
        file: String,
        artifact: String,
        manifest: String,
        expect: String,
    }

    fn vectors() -> Vectors {
        serde_json::from_slice(&read("vectors.json")).expect("vectors.json parses")
    }

    // The same cases the Elixir verifier answers in `vectors_test.exs`: a rotation read by
    // an old client, a new one and one trusting both; a changed manifest, another key, a
    // changed trusted comment, an empty and a broken .minisig, a client with no key.
    #[test]
    fn the_shared_signature_vectors() {
        let cases = vectors().signatures;
        assert!(cases.len() >= 12, "the vectors are all there");
        for case in cases {
            let keys: Vec<TrustedKey> = case
                .trusted
                .iter()
                .map(|f| parse_public_key(&String::from_utf8(read(f)).unwrap()).expect("a vector's key parses"))
                .collect();
            let signature = String::from_utf8(read(&case.signature)).unwrap();
            let got = verify(&read(&case.manifest), &signature, &keys);
            match case.expect.as_str() {
                "ok" => assert!(got.is_ok(), "{}: refused with {:?}", case.name, got),
                _ => assert!(got.is_err(), "{}: accepted", case.name),
            }
        }
    }

    #[test]
    fn the_shared_artifact_vectors() {
        for case in vectors().artifacts {
            let manifest = decode_manifest(&read(&case.manifest)).expect("the vector's manifest decodes");
            let artifact = manifest.file(&case.artifact).expect("the manifest names it");
            let got = check_bytes(artifact, &read(&case.file));
            match case.expect.as_str() {
                "ok" => assert!(got.is_ok(), "{}: refused with {:?}", case.name, got),
                _ => assert!(got.is_err(), "{}: accepted", case.name),
            }
        }
    }

    #[test]
    fn a_refusal_names_the_keys() {
        let other = parse_public_key(&String::from_utf8(read("keys/other.pub")).unwrap()).unwrap();
        let current = parse_public_key(&String::from_utf8(read("keys/current.pub")).unwrap()).unwrap();
        let signature = String::from_utf8(read("signatures/other.minisig")).unwrap();
        let why = verify(&read("manifest.json"), &signature, &[current.clone()]).unwrap_err();
        assert!(why.contains(&other.id_text()), "{why}");
        assert!(why.contains(&current.id_text()), "{why}");
        assert!(verify(&read("manifest.json"), &signature, &[]).unwrap_err().contains("trusts no release key"));
    }

    // The list this build is compiled with: the release key, first, as the terminal's.
    #[test]
    fn this_build_trusts_the_release_keys_file() {
        let keys = trusted_keys();
        assert!(!keys.is_empty(), "release-keys.txt holds no key");
        assert_eq!(parse_key_list(RELEASE_KEYS).unwrap().len(), keys.len());
    }

    // Tauri's updater reads the key as minisign's `.pub` file, base64-encoded, and
    // minisign-verify reads that back to the same key.
    #[test]
    fn a_key_as_the_updater_takes_it() {
        let key = parse_public_key(&String::from_utf8(read("keys/current.pub")).unwrap()).unwrap();
        let pub_file = String::from_utf8(STANDARD.decode(key.tauri_pubkey()).unwrap()).unwrap();
        assert!(pub_file.starts_with(&format!("untrusted comment: minisign public key {}\n", key.id_text())));
        assert!(PublicKey::decode(&pub_file).is_ok());
        let signature = String::from_utf8(read("signatures/current.minisig")).unwrap();
        assert_eq!(signer(&signature).unwrap(), key.id);
    }

    #[test]
    fn a_manifest_with_a_path_for_a_file_is_refused() {
        let bad = br#"{"format": 1, "version": "1.0.0", "artifacts": [{"component": "tui", "target": null, "file": "../x", "size": 1, "sha256": "00"}]}"#;
        assert!(decode_manifest(bad).unwrap_err().contains("cannot be about"));
        let later = br#"{"format": 2, "version": "1.0.0", "artifacts": []}"#;
        assert!(decode_manifest(later).unwrap_err().contains("format 2"));
    }

    fn artifact(component: &str, target: Option<&str>, file: &str) -> Artifact {
        Artifact { component: component.into(), target: target.map(Into::into), file: file.into(), size: 1, sha256: "0".repeat(64) }
    }

    #[test]
    fn a_requirement_is_read_as_the_terminal_reads_it() {
        assert_eq!(requirement_holds(">= 0.30.0-beta", "0.34.0-beta"), Some(true));
        assert_eq!(requirement_holds(">= 0.30.0-beta", "0.30.0"), Some(true));
        assert_eq!(requirement_holds(">= 0.30.0", "0.30.0-beta"), Some(false));
        assert_eq!(requirement_holds(">= 0.30.0-beta and < 0.40.0-beta", "0.40.0-beta"), Some(false));
        assert_eq!(requirement_holds(">=0.30.0-beta", "0.31.0-beta"), Some(true));
        assert_eq!(requirement_holds("~> 0.30", "0.31.0"), None);
        assert_eq!(requirement_holds(">= 0.30.0", "nightly"), None);
    }

    #[test]
    fn supports_is_read_where_it_is_and_unknown_where_it_is_not() {
        let sha = "a".repeat(64);
        let with = format!(
            r#"{{"format": 1, "version": "1.0.0", "supports": {{"plane": ">= 0.30.0-beta", "protocol": "1"}}, "artifacts": [{{"component": "tui", "target": null, "file": "x", "size": 1, "sha256": "{sha}"}}]}}"#
        );
        let manifest = decode_manifest(with.as_bytes()).unwrap();
        assert_eq!(manifest.supports, Some(Supports { plane: ">= 0.30.0-beta".into(), protocol: "1".into() }));
        assert_eq!(manifest.supports_plane(Some("0.34.0-beta")), Some(true));
        assert_eq!(manifest.supports_plane(Some("0.29.0")), Some(false));
        assert_eq!(manifest.supports_plane(None), None);

        let without = decode_manifest(br#"{"format": 1, "version": "1.0.0", "artifacts": []}"#).unwrap();
        assert_eq!(without.supports, None);
        assert_eq!(without.supports_plane(Some("0.34.0-beta")), None);

        let bad = decode_manifest(br#"{"format": 1, "version": "1.0.0", "supports": {"plane": "~> 1.0", "protocol": "1"}, "artifacts": []}"#);
        assert!(bad.unwrap_err().starts_with("says it supports planes"));
    }

    #[test]
    fn the_update_for_each_computer() {
        let manifest = Manifest {
            supports: None,
            version: "0.15.0-beta".into(),
            artifacts: vec![
                artifact("desktop", Some("windows_x86_64"), "Troupe_0.15.0_x64_en-US.msi"),
                artifact("desktop", Some("windows_x86_64"), "Troupe_0.15.0_x64-setup.exe.sig"),
                artifact("desktop", Some("windows_x86_64"), "Troupe_0.15.0_x64-setup.exe"),
                artifact("desktop", Some("macos_universal"), "Troupe_0.15.0_universal.dmg"),
                artifact("desktop", Some("macos_universal"), "Troupe_0.15.0_universal.app.tar.gz"),
                artifact("desktop", Some("linux_x86_64"), "Troupe_0.15.0_amd64.deb"),
                artifact("desktop", Some("linux_x86_64"), "Troupe_0.15.0_amd64.AppImage"),
                artifact("daemon", Some("windows_x86_64"), "troupe-daemon-0.15.0-beta-windows_x86_64.tar.gz"),
            ],
        };
        let file = |os, arch| manifest.desktop_update(&Platform { os, arch }).map(|a| a.file.as_str());
        assert_eq!(file("windows", "x86_64"), Some("Troupe_0.15.0_x64-setup.exe"));
        assert_eq!(file("macos", "aarch64"), Some("Troupe_0.15.0_universal.app.tar.gz"));
        assert_eq!(file("macos", "x86_64"), Some("Troupe_0.15.0_universal.app.tar.gz"));
        assert_eq!(file("linux", "x86_64"), Some("Troupe_0.15.0_amd64.AppImage"));
        assert_eq!(file("linux", "aarch64"), None);
        let daemon = manifest.find("daemon", &Platform { os: "windows", arch: "x86_64" }.target());
        assert_eq!(daemon.map(|a| a.file.as_str()), Some("troupe-daemon-0.15.0-beta-windows_x86_64.tar.gz"));
    }

    #[test]
    fn versions_move_forward_only() {
        assert!(wanted("0.14.0-beta", "0.15.0-beta"));
        assert!(wanted("0.15.0-beta", "0.15.0"));
        assert!(!wanted("0.15.0-beta", "0.15.0-beta"));
        assert!(!wanted("0.15.0-beta", "0.14.0-beta"));
        assert!(wanted("unknown version", "0.15.0-beta"));
        assert!(older("0.13.0-beta", "0.13.1-beta"));
        assert!(!older("dev", "0.13.1-beta"));
    }

    #[test]
    fn a_policy_judges_a_version_as_the_plane_does() {
        let policy = Policy {
            minimum: Some("0.14.0-beta".into()),
            blocked: vec!["0.14.1-beta".into()],
            ..Policy::default()
        };
        assert_eq!(judge(&policy, "0.14.1-beta"), Judgement::Blocked);
        assert_eq!(judge(&policy, "0.13.9"), Judgement::BelowMinimum);
        assert_eq!(judge(&policy, "0.15.0-beta"), Judgement::Served);
        assert_eq!(judge(&Policy::default(), "dev"), Judgement::Served);
    }

    #[test]
    fn the_latest_release_is_the_tag_its_redirect_names() {
        assert_eq!(latest_tag("https://github.com/o/r/releases/tag/v0.15.0-beta").as_deref(), Some("0.15.0-beta"));
        assert_eq!(latest_tag("https://github.com/o/r/releases"), None);
    }

    #[test]
    fn this_build_knows_its_release_version() {
        assert!(Version::parse(current_version()).is_ok(), "VERSION is {:?}", current_version());
    }
}
