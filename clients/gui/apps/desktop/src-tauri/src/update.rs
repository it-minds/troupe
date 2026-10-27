// The desktop app's own update, and beside it the daemon's (#66, Decision 874), the
// terminal client's and the VS Code extension's, wherever the installers put those:
// an install picks its components once, and one update moves them all.
//
// Three commands, one step each, so that the page can ask the person between them:
//
//   update_check     finds the release to move to: the version a plane recommends, or the
//                    latest; checks its manifest against the release keys this build was
//                    compiled with (`release.rs`); and says what an update would replace.
//                    Nothing is downloaded but the manifest and the update's signature.
//   update_download  downloads the app's update, which Tauri's updater checks against the
//                    release key, and checks it again against the signed manifest's size
//                    and sha256; the daemon's release, checked and unpacked beside the one
//                    it replaces; the terminal client, checked and put beside the one it
//                    replaces; and the extension's `.vsix`, checked. Nothing in place is
//                    touched.
//   update_install   installs the extension with `code`, swaps the daemon's release and
//                    the terminal client in, as `troupe update` does (Decision 865), and
//                    hands the app's update to Tauri's updater, which restarts the app.
//
// A release that cannot be checked is refused with a sentence, and nothing changes. The
// page asks the daemon to stop between turns (`daemon.stop`) before it calls the last one,
// and the person to restart before that; this file restarts nothing on its own.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, State, Url};
use tauri_plugin_http::reqwest;
use tauri_plugin_updater::{Update, UpdaterExt};

use crate::daemon;
use crate::plane_word::{self, Signed};
use crate::release::{self, Artifact, Judgement, Manifest, Platform, Policy, TrustedKey};

/// Where releases are published, unless `TROUPE_REPO` or `TROUPE_RELEASE_URL` says otherwise.
const REPO: &str = "it-minds/troupe";

/// What the page hears while an update downloads: bytes received, and of how many.
pub const PROGRESS: &str = "troupe://update-progress";

/// The update found by the last check, carried to the download and the install.
#[derive(Default)]
pub struct Updates(Mutex<Option<Pending>>);

struct Pending {
    base: String,
    update: Update,
    app: Artifact,
    daemon: Option<DaemonStep>,
    tui: Option<TuiStep>,
    extension: Option<ExtensionStep>,
    bytes: Option<Vec<u8>>,
}

#[derive(Clone)]
struct DaemonStep {
    lib: PathBuf,
    artifact: Artifact,
    staged: bool,
}

/// The terminal client the installers put beside the daemon: where it is, and the release's
/// file for it, put beside it as `<path>.new` once staged.
#[derive(Clone)]
struct TuiStep {
    path: PathBuf,
    artifact: Artifact,
    staged: bool,
}

/// The VS Code extension `code` lists: the command line that installs it, and the
/// release's `.vsix`, kept in the temporary directory once staged.
#[derive(Clone)]
struct ExtensionStep {
    code: PathBuf,
    artifact: Artifact,
    vsix: PathBuf,
    staged: bool,
}

/// The VS Code extension's id, as `code --list-extensions` names it.
const EXTENSION: &str = "objective-mj.troupe";

/// What the page passes to a check: the version a plane recommends, and the plane's policy
/// for each kind of client, as `me.client_versions` answers it.
///
/// With the plane's `signed` answer beside it (#657), the shell reads the policy, the
/// version and where releases are from that alone, once the key this computer pinned for
/// the plane, which it asks the daemon for itself, holds for it: the page's `version` and
/// `versions` are then not read, and no field of the page's is a URL.
#[derive(Default, Deserialize)]
pub struct CheckParams {
    #[serde(default)]
    version: Option<String>,
    #[serde(default)]
    plane: Option<PlaneWord>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct PlaneWord {
    url: String,
    #[serde(default)]
    versions: HashMap<String, Policy>,
    #[serde(default)]
    signed: Option<Signed>,
    /// Where releases are, from a policy the pinned key signed: never the page's.
    #[serde(skip)]
    release: Option<String>,
}

impl PlaneWord {
    fn policy(&self, component: &str) -> Policy {
        self.versions.get(component).cloned().unwrap_or_default()
    }
}

/// What a check found.
#[derive(Debug, Serialize, PartialEq)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum Checked {
    /// Nothing newer: `version` is the release found, `current` this build.
    Current { version: String, current: String },
    Offer(Box<Offer>),
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Offer {
    pub version: String,
    pub current: String,
    /// The release the files come from.
    pub source: String,
    /// The daemon the installers put beside the app, replaced with it.
    pub daemon: Option<DaemonOffer>,
    /// Why the daemon here is left as it is, when one is and that is not because it is current.
    pub daemon_note: Option<String>,
    /// The terminal client the installers put here, replaced with it.
    pub tui: Option<ComponentOffer>,
    pub tui_note: Option<String>,
    /// The VS Code extension `code` lists, installed again from the release.
    pub extension: Option<ComponentOffer>,
    pub extension_note: Option<String>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct DaemonOffer {
    pub from: String,
    pub to: String,
    pub lib: String,
}

/// One more component an update replaces: from which version to which, and where it is.
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct ComponentOffer {
    pub from: String,
    pub to: String,
    pub at: String,
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
}

fn client(redirects: bool) -> Result<reqwest::Client, String> {
    let policy = if redirects { reqwest::redirect::Policy::limited(10) } else { reqwest::redirect::Policy::none() };
    reqwest::Client::builder()
        .redirect(policy)
        .timeout(Duration::from_secs(120))
        .user_agent(format!("troupe-desktop/{}", release::current_version()))
        .build()
        .map_err(|e| format!("could not set up a connection: {e}"))
}

/// Fetch `url`, or `None` where it is not there.
async fn get(client: &reqwest::Client, url: &str, limit: Option<usize>) -> Result<Option<Vec<u8>>, String> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err(format!("{url}: the desktop app reads releases over https"));
    }
    let resp = client.get(url).send().await.map_err(|e| format!("could not reach {url}: {e}"))?;
    match resp.status().as_u16() {
        200 => {}
        404 => return Ok(None),
        status => return Err(format!("{url} answered {status}")),
    }
    let bytes = resp.bytes().await.map_err(|e| format!("could not read {url}: {e}"))?;
    if limit.is_some_and(|l| bytes.len() > l) {
        return Err(format!("{url} is too big to be what it says; nothing is installed"));
    }
    Ok(Some(bytes.to_vec()))
}

/// Where the release is, and which version it must be.
#[derive(Debug, PartialEq)]
struct Source {
    base: String,
    /// The version asked for, which the manifest must name.
    asked: Option<String>,
    /// The tag `/releases/latest` redirected to, which the manifest must name too.
    tag: Option<String>,
}

/// The plane's word as the check reads it: from its signed answer, checked against the key
/// the daemon pinned for the plane, where the page passed one; otherwise the page's policy,
/// which can only hold an update back, with releases where they are without a plane.
async fn plane_word(plane: &PlaneWord) -> Result<PlaneWord, String> {
    let Some(signed) = &plane.signed else {
        return Ok(PlaneWord { signed: None, release: None, ..plane.clone() });
    };
    let identity = tauri::async_runtime::spawn_blocking(|| {
        let endpoint = daemon::read_endpoint().ok_or("no daemon is running on this computer to say which key it pinned")?;
        daemon::identity(&endpoint)
    })
    .await
    .map_err(|e| e.to_string())?;
    signed_word(plane, signed, identity, std::time::SystemTime::now())
}

fn signed_word(plane: &PlaneWord, signed: &Signed, identity: Result<serde_json::Value, String>, now: std::time::SystemTime) -> Result<PlaneWord, String> {
    let refused = |why: String| format!("the version policy from {} is not checked ({why}): the update does not follow it; nothing is installed", plane.url.trim_end_matches('/'));
    let identity = identity.map_err(refused)?;
    let pinned = plane_word::pinned_for(&identity, &plane.url)?;
    let word = plane_word::verify(signed, &pinned, &plane.url, now)?;
    Ok(PlaneWord { url: plane.url.clone(), versions: word.versions, signed: Some(signed.clone()), release: word.release_url })
}

/// Where the release is: `TROUPE_RELEASE_URL`, the person's own, first; then where a plane's
/// signed policy says releases are, each under `v<version>/`, which has no "latest", so a
/// version must be named; then GitHub's.
async fn source(version: Option<&str>, plane_release: Option<&str>) -> Result<Source, String> {
    if let Some(url) = env("TROUPE_RELEASE_URL") {
        return Ok(Source { base: url.trim_end_matches('/').to_string(), asked: version.map(Into::into), tag: None });
    }
    if let Some(url) = plane_release {
        let version = version.ok_or_else(|| {
            format!(
                "the plane says releases are at {url} and recommends no version of the desktop app, and a release \
                 there is found by its version: nothing is offered"
            )
        })?;
        return Ok(Source { base: format!("{url}/v{version}"), asked: Some(version.to_string()), tag: None });
    }
    let repo = env("TROUPE_REPO").unwrap_or_else(|| REPO.to_string());
    if let Some(v) = version {
        return Ok(Source {
            base: format!("https://github.com/{repo}/releases/download/v{v}"),
            asked: Some(v.to_string()),
            tag: None,
        });
    }
    let url = format!("https://github.com/{repo}/releases/latest");
    let resp = client(false)?.get(&url).send().await.map_err(|e| format!("could not reach {url}: {e}"))?;
    if !resp.status().is_redirection() {
        return Err(format!("{url} answered {}, not the latest release", resp.status().as_u16()));
    }
    let location = resp.headers().get("location").and_then(|l| l.to_str().ok()).unwrap_or_default();
    let tag = release::latest_tag(location).ok_or_else(|| format!("{url} did not name a release"))?;
    Ok(Source { base: format!("https://github.com/{repo}/releases/download/v{tag}"), asked: None, tag: Some(tag) })
}

/// The release's manifest, once its signature holds and it names the version asked for.
async fn signed_manifest(client: &reqwest::Client, source: &Source, keys: &[TrustedKey]) -> Result<Manifest, String> {
    let base = &source.base;
    let bytes = get(client, &format!("{base}/manifest.json"), Some(release::SMALL)).await?.ok_or_else(|| {
        format!(
            "the release at {base} has no manifest.json: releases from before 0.13 and pre-releases are not signed, \
             and the desktop app installs only a signed release; nothing is installed"
        )
    })?;
    let signature = get(client, &format!("{base}/manifest.json.minisig"), Some(release::SMALL))
        .await?
        .ok_or_else(|| format!("the release at {base} has no manifest.json.minisig; nothing is installed"))?;
    let signature = String::from_utf8(signature).map_err(|_| format!("the manifest of the release at {base} has a signature that is not text; nothing is installed"))?;
    release::verify(&bytes, &signature, keys).map_err(|why| format!("the manifest of the release at {base} {why}; nothing is installed"))?;
    let manifest = release::decode_manifest(&bytes).map_err(|why| format!("the signed manifest at {base} {why}; nothing is installed"))?;
    asked_for(&manifest, source)?;
    Ok(manifest)
}

// An old signed manifest served in place of the one asked for is still signed: what it
// names has to be what was asked for.
fn asked_for(manifest: &Manifest, source: &Source) -> Result<(), String> {
    let version = &manifest.version;
    if let Some(asked) = source.asked.as_deref().filter(|a| *a != version) {
        return Err(format!("the release at {} is {version}, not {asked}; nothing is installed", source.base));
    }
    if let Some(tag) = source.tag.as_deref().filter(|t| *t != version) {
        return Err(format!("the release tagged v{tag} carries the manifest of {version}; nothing is installed"));
    }
    Ok(())
}

/// A plane's word on a version for one component: never a blocked one, never below its
/// minimum (Decision 868).
fn served(plane: &PlaneWord, component: &str, version: &str) -> Result<(), String> {
    let name = match component {
        "desktop" => "the desktop app",
        "tui" => "troupe",
        _ => "troupe-daemon",
    };
    match release::judge(&plane.policy(component), version) {
        Judgement::Blocked => Err(format!("the plane at {} blocks {name} {version}; nothing is installed", plane.url)),
        Judgement::BelowMinimum => Err(format!(
            "the plane at {} needs {name} {} or later, and the release found is {version}; nothing is installed",
            plane.url,
            plane.policy(component).minimum.unwrap_or_default()
        )),
        Judgement::Served => Ok(()),
    }
}

/// The app's update's signature: the `.sig` beside it, held to the signed manifest, and the
/// trusted key that made it, which is the key Tauri's updater is given.
async fn signature_of(
    client: &reqwest::Client,
    base: &str,
    manifest: &Manifest,
    artifact: &Artifact,
    keys: &[TrustedKey],
) -> Result<(String, TrustedKey), String> {
    let name = format!("{}.sig", artifact.file);
    let entry = manifest
        .file(&name)
        .ok_or_else(|| format!("the signed manifest of {} names no {name}; nothing is installed", manifest.version))?;
    let bytes = get(client, &format!("{base}/{name}"), Some(release::SMALL))
        .await?
        .ok_or_else(|| format!("{base}/{name} is not there, though the signed manifest names it; nothing is installed"))?;
    release::check_bytes(entry, &bytes).map_err(|why| format!("{why}; nothing is installed"))?;
    let signature = String::from_utf8(bytes).map_err(|_| format!("{name} is not a signature; nothing is installed"))?.trim().to_string();
    let key = signing_key(&signature, keys).map_err(|why| format!("{name} {why}; nothing is installed"))?;
    Ok((signature, key))
}

/// The trusted key that made an update's signature, which Tauri writes base64-encoded.
fn signing_key(signature: &str, keys: &[TrustedKey]) -> Result<TrustedKey, String> {
    use base64::Engine;
    let text = base64::engine::general_purpose::STANDARD
        .decode(signature.trim())
        .ok()
        .and_then(|b| String::from_utf8(b).ok())
        .ok_or("is not a signature")?;
    let id = release::signer(&text)?;
    keys.iter().find(|k| k.id == id).cloned().ok_or_else(|| {
        format!("is signed by key {}, which this build does not trust", release::key_id_text(&id))
    })
}

/// Tauri's update for this version, with the file and the signature this check found: the
/// updater reads the release's `latest.json` to know there is one, and installs only what
/// the signature's key signed for that version.
async fn tauri_update(app: &AppHandle, base: &str, version: &str, key: &TrustedKey, file: &str, signature: String) -> Result<Update, String> {
    let endpoint = Url::parse(&format!("{base}/latest.json")).map_err(|e| format!("{base}: {e}"))?;
    let wanted = semver::Version::parse(version).map_err(|e| format!("{version} is not a version: {e}"))?;
    let updater = app
        .updater_builder()
        .pubkey(key.tauri_pubkey())
        .endpoints(vec![endpoint])
        .map_err(|e| format!("{base}: {e}; nothing is installed"))?
        .version_comparator(move |_current, remote| remote.version == wanted)
        .build()
        .map_err(|e| format!("the desktop app cannot update itself here: {e}"))?;
    let mut update = updater
        .check()
        .await
        .map_err(|e| format!("the release at {base} has no latest.json for this computer ({e}); nothing is installed"))?
        .ok_or_else(|| format!("the latest.json of the release at {base} is not for {version}; nothing is installed"))?;
    update.download_url = Url::parse(&format!("{base}/{file}")).map_err(|e| format!("{base}/{file}: {e}"))?;
    update.signature = signature;
    Ok(update)
}

// -- the daemon beside the app --------------------------------------------------

/// Where the installers put the daemon's release: `TROUPE_LIB_DIR` moves it, as it moves
/// theirs and `troupe update`'s.
fn lib_dir() -> Option<PathBuf> {
    if let Some(dir) = env("TROUPE_LIB_DIR") {
        return Some(PathBuf::from(dir));
    }
    if cfg!(windows) {
        std::env::var_os("LOCALAPPDATA").map(|l| PathBuf::from(l).join("Programs").join("troupe-daemon"))
    } else {
        daemon::home().map(|h| h.join(".local").join("lib").join("troupe-daemon"))
    }
}

fn daemon_bin(lib: &Path) -> PathBuf {
    lib.join("bin").join(if cfg!(windows) { "troupe-daemon.cmd" } else { "troupe-daemon" })
}

fn sibling(lib: &Path, suffix: &str) -> PathBuf {
    let mut name = lib.as_os_str().to_os_string();
    name.push(suffix);
    PathBuf::from(name)
}

/// The version of the daemon's release in `lib`, as the installers read it, or `None`
/// where none is installed.
fn daemon_version(lib: &Path) -> Option<String> {
    if !daemon_bin(lib).is_file() {
        return None;
    }
    let data = std::fs::read_to_string(lib.join("releases").join("start_erl.data")).unwrap_or_default();
    Some(data.split_whitespace().nth(1).unwrap_or("unknown version").to_string())
}

/// The daemon's part of an update: replaced where the installers put one older than the
/// release, and the plane, if there is one, serves the release's daemon.
fn daemon_step(manifest: &Manifest, platform: &Platform, plane: Option<&PlaneWord>, lib: Option<PathBuf>) -> (Option<DaemonStep>, Option<DaemonOffer>, Option<String>) {
    let Some(lib) = lib else { return (None, None, None) };
    let Some(from) = daemon_version(&lib) else { return (None, None, None) };
    let to = &manifest.version;
    if !release::wanted(&from, to) {
        return (None, None, None);
    }
    if let Some(plane) = plane {
        if let Err(why) = served(plane, "daemon", to) {
            return (None, None, Some(format!("troupe-daemon {from} is left as it is: {}", why.trim_end_matches("; nothing is installed"))));
        }
    }
    let Some(artifact) = manifest.find("daemon", &platform.target()).cloned() else {
        return (None, None, Some(format!("troupe-daemon {from} is left as it is: release {to} has no daemon for this computer")));
    };
    let offer = DaemonOffer { from, to: to.clone(), lib: lib.display().to_string() };
    (Some(DaemonStep { lib, artifact, staged: false }), Some(offer), None)
}

/// The daemon's release downloaded, checked, and unpacked beside the one it replaces, as
/// `<lib>.new`. Nothing in place is touched.
async fn stage_daemon(client: &reqwest::Client, base: &str, step: &DaemonStep) -> Result<(), String> {
    let url = format!("{base}/{}", step.artifact.file);
    let bytes = get(client, &url, None)
        .await?
        .ok_or_else(|| format!("{url} is not there, though the signed manifest names it; nothing is installed"))?;
    release::check_bytes(&step.artifact, &bytes).map_err(|why| format!("{why}; nothing is installed"))?;
    unpack_daemon(&bytes, &step.lib)
}

fn unpack_daemon(archive: &[u8], lib: &Path) -> Result<(), String> {
    let staging = sibling(lib, ".new");
    let _ = std::fs::remove_dir_all(&staging);
    std::fs::create_dir_all(&staging).map_err(|e| format!("{} could not be made: {e}; nothing is installed", staging.display()))?;
    let unpacked = tar::Archive::new(flate2::read::GzDecoder::new(archive)).unpack(&staging);
    let result = match unpacked {
        Err(e) => Err(format!("could not unpack the daemon's release: {e}; nothing is installed")),
        Ok(()) if !daemon_bin(&staging).is_file() => Err(format!(
            "{} holds no {}; nothing is installed",
            staging.display(),
            daemon_bin(Path::new("")).display()
        )),
        Ok(()) => Ok(()),
    };
    if result.is_err() {
        let _ = std::fs::remove_dir_all(&staging);
    }
    result
}

// A program that has just exited can hold its files a moment longer on Windows, and so can
// a virus scanner: a few tries, a second apart.
fn rename(from: &Path, to: &Path, why: &str) -> Result<(), String> {
    let mut tries = if cfg!(windows) { 5 } else { 1 };
    loop {
        match std::fs::rename(from, to) {
            Ok(()) => return Ok(()),
            Err(_) if tries > 1 => {
                tries -= 1;
                std::thread::sleep(Duration::from_secs(1));
            }
            Err(e) => return Err(format!("{why} ({e})")),
        }
    }
}

/// The staged release in, the old one kept as `<lib>.previous`: the installers' names, so
/// `troupe update --rollback` and `install-local.ps1 -Rollback` find it.
fn swap_daemon_in(lib: &Path) -> Result<(), String> {
    let previous = sibling(lib, ".previous");
    if previous.exists() {
        std::fs::remove_dir_all(&previous)
            .map_err(|_| format!("{} could not be removed: something still runs from it; nothing changed", previous.display()))?;
    }
    rename(lib, &previous, &format!("{} could not be moved aside: something still runs from it; nothing changed", lib.display()))?;
    if let Err(why) = rename(&sibling(lib, ".new"), lib, &format!("the new troupe-daemon could not be moved into {}", lib.display())) {
        let _ = std::fs::rename(&previous, lib);
        return Err(format!("{why}; nothing changed"));
    }
    Ok(())
}

/// The swap undone, when the app's own update cannot follow it.
fn undo_daemon(lib: &Path) {
    let _ = std::fs::rename(lib, sibling(lib, ".new"));
    let _ = std::fs::rename(sibling(lib, ".previous"), lib);
}

// -- the terminal client and the VS Code extension -----------------------------------

/// Where the installers put the programs: `TROUPE_BIN_DIR`, else
/// `%LOCALAPPDATA%\Programs\troupe` on Windows and `~/.local/bin` elsewhere.
fn bin_dir() -> Option<PathBuf> {
    if let Some(dir) = env("TROUPE_BIN_DIR") {
        return Some(PathBuf::from(dir));
    }
    if cfg!(windows) {
        std::env::var_os("LOCALAPPDATA").map(|l| PathBuf::from(l).join("Programs").join("troupe"))
    } else {
        daemon::home().map(|h| h.join(".local").join("bin"))
    }
}

fn tui_path() -> Option<PathBuf> {
    bin_dir().map(|b| b.join(if cfg!(windows) { "troupe.exe" } else { "troupe" }))
}

/// A program run to completion with no window, its output and status.
fn run_quiet(program: &Path, args: &[&str]) -> Result<(String, i32), String> {
    let mut command = Command::new(program);
    command.args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    let output = command.output().map_err(|e| format!("{} could not be run: {e}", program.display()))?;
    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    Ok((text, output.status.code().unwrap_or(-1)))
}

/// The version `troupe --version` prints (`troupe 0.29.0-beta`), or "unknown version" for
/// a program that is there and says something else; `None` where none is installed.
fn tui_version(path: &Path) -> Option<String> {
    if !path.is_file() {
        return None;
    }
    Some(match run_quiet(path, &["--version"]) {
        Ok((output, 0)) => tui_version_of(&output),
        _ => "unknown version".to_string(),
    })
}

fn tui_version_of(output: &str) -> String {
    output
        .lines()
        .find_map(|line| line.trim().strip_prefix("troupe ").map(|v| v.trim().to_string()))
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "unknown version".to_string())
}

/// VS Code's command line, as the installers find it: `TROUPE_VSCODE_CLI`, `code` on the
/// PATH, or where the macOS and Windows setups put it.
fn code_cli() -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(given) = env("TROUPE_VSCODE_CLI") {
        candidates.push(PathBuf::from(given));
    }
    let name = if cfg!(windows) { "code.cmd" } else { "code" };
    if let Some(path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path) {
            candidates.push(dir.join(name));
        }
    }
    if cfg!(windows) {
        if let Some(local) = std::env::var_os("LOCALAPPDATA") {
            candidates.push(PathBuf::from(local).join("Programs").join("Microsoft VS Code").join("bin").join("code.cmd"));
        }
        if let Some(programs) = std::env::var_os("ProgramFiles") {
            candidates.push(PathBuf::from(programs).join("Microsoft VS Code").join("bin").join("code.cmd"));
        }
    } else {
        candidates.push(PathBuf::from("/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"));
        if let Some(h) = daemon::home() {
            candidates.push(h.join("Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"));
        }
    }
    candidates.into_iter().find(|c| c.is_file())
}

/// The extension's version as `code --list-extensions --show-versions` lists it, or
/// `None` where it is not installed or `code` does not answer.
fn extension_version(code: &Path) -> Option<String> {
    match run_quiet(code, &["--list-extensions", "--show-versions"]) {
        Ok((output, 0)) => extension_version_of(&output),
        _ => None,
    }
}

fn extension_version_of(output: &str) -> Option<String> {
    output.lines().find_map(|line| {
        let (id, version) = line.trim().split_once('@')?;
        (id.eq_ignore_ascii_case(EXTENSION) && !version.is_empty()).then(|| version.to_string())
    })
}

/// The terminal client's part of an update: replaced where the installers put one older
/// than the release, and the plane, if there is one, serves the release's terminal.
fn tui_step(manifest: &Manifest, platform: &Platform, plane: Option<&PlaneWord>, path: Option<PathBuf>, from: Option<String>) -> (Option<TuiStep>, Option<ComponentOffer>, Option<String>) {
    let (Some(path), Some(from)) = (path, from) else { return (None, None, None) };
    let to = &manifest.version;
    if !release::wanted(&from, to) {
        return (None, None, None);
    }
    if let Some(plane) = plane {
        if let Err(why) = served(plane, "tui", to) {
            return (None, None, Some(format!("troupe {from} is left as it is: {}", why.trim_end_matches("; nothing is installed"))));
        }
    }
    let Some(artifact) = manifest.find("tui", &platform.target()).cloned() else {
        return (None, None, Some(format!("troupe {from} is left as it is: release {to} has no troupe for this computer")));
    };
    let offer = ComponentOffer { from, to: to.clone(), at: path.display().to_string() };
    (Some(TuiStep { path, artifact, staged: false }), Some(offer), None)
}

/// The extension's part: installed again from the release where `code` lists one older.
fn extension_step(manifest: &Manifest, code: Option<PathBuf>, from: Option<String>) -> (Option<ExtensionStep>, Option<ComponentOffer>, Option<String>) {
    let (Some(code), Some(from)) = (code, from) else { return (None, None, None) };
    let to = &manifest.version;
    if !release::wanted(&from, to) {
        return (None, None, None);
    }
    let Some(artifact) = manifest.file("troupe.vsix").cloned() else {
        return (None, None, Some(format!("the VS Code extension {from} is left as it is: release {to} has none")));
    };
    let vsix = std::env::temp_dir().join(format!("troupe-update-{}-{}", std::process::id(), artifact.file));
    let offer = ComponentOffer { from, to: to.clone(), at: code.display().to_string() };
    (Some(ExtensionStep { code, artifact, vsix, staged: false }), Some(offer), None)
}

/// The terminal client downloaded, checked, and put beside the one it replaces as
/// `<path>.new`, made executable. Nothing in place is touched.
async fn stage_tui(client: &reqwest::Client, base: &str, step: &TuiStep) -> Result<(), String> {
    let url = format!("{base}/{}", step.artifact.file);
    let bytes = get(client, &url, None)
        .await?
        .ok_or_else(|| format!("{url} is not there, though the signed manifest names it; nothing is installed"))?;
    release::check_bytes(&step.artifact, &bytes).map_err(|why| format!("{why}; nothing is installed"))?;
    let new = sibling(&step.path, ".new");
    std::fs::write(&new, &bytes).map_err(|e| format!("{} could not be written: {e}; nothing is installed", new.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&new, std::fs::Permissions::from_mode(0o755));
    }
    Ok(())
}

/// The extension's `.vsix` downloaded and checked, kept until `code` installs it.
async fn stage_extension(client: &reqwest::Client, base: &str, step: &ExtensionStep) -> Result<(), String> {
    let url = format!("{base}/{}", step.artifact.file);
    let bytes = get(client, &url, None)
        .await?
        .ok_or_else(|| format!("{url} is not there, though the signed manifest names it; nothing is installed"))?;
    release::check_bytes(&step.artifact, &bytes).map_err(|why| format!("{why}; nothing is installed"))?;
    std::fs::write(&step.vsix, &bytes).map_err(|e| format!("{} could not be written: {e}; nothing is installed", step.vsix.display()))
}

/// The staged terminal client in, the old one kept as `<path>.previous`, as `troupe update`
/// keeps it: on Unix the old file is linked to that name and the new one
/// replaces it in one rename; on Windows a running program cannot be replaced but can be
/// renamed, so it is moved aside first, and one a terminal still runs is set aside under a
/// stamped name for a later update to remove.
fn swap_tui_in(path: &Path) -> Result<(), String> {
    let previous = sibling(path, ".previous");
    let new = sibling(path, ".new");
    clear_set_aside(path);
    if previous.exists() && std::fs::remove_file(&previous).is_err() {
        let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        rename(&previous, &sibling(path, &format!(".in-use-{stamp}")), &format!("{} could not be removed or set aside; nothing changed", previous.display()))?;
    }
    if cfg!(windows) {
        rename(path, &previous, &format!("{} could not be moved aside; nothing changed", path.display()))?;
        if let Err(why) = rename(&new, path, &format!("the new troupe could not be moved into {}", path.display())) {
            let _ = std::fs::rename(&previous, path);
            return Err(format!("{why}; nothing changed"));
        }
    } else {
        if std::fs::hard_link(path, &previous).is_err() {
            std::fs::copy(path, &previous).map_err(|e| format!("{} could not be kept as {}: {e}; nothing changed", path.display(), previous.display()))?;
        }
        rename(&new, path, &format!("the new troupe could not be moved into {}; nothing changed", path.display()))?;
    }
    Ok(())
}

/// The swap undone, when the app's own update cannot follow it.
fn undo_tui(path: &Path) {
    let previous = sibling(path, ".previous");
    if cfg!(windows) {
        let _ = std::fs::rename(path, sibling(path, ".new"));
        let _ = std::fs::rename(&previous, path);
    } else {
        let _ = std::fs::rename(path, sibling(path, ".new"));
        let _ = std::fs::copy(&previous, path);
    }
}

/// Files an earlier update set aside because a terminal still ran them, removed where
/// they are free now.
fn clear_set_aside(path: &Path) {
    let (Some(dir), Some(name)) = (path.parent(), path.file_name().and_then(|n| n.to_str())) else { return };
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let file = entry.file_name();
        let file = file.to_string_lossy();
        if file.starts_with(&format!("{name}.")) && file.contains(".in-use-") {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

/// The extension installed with `code`, which replaces the one listed; the `.vsix` goes
/// either way.
fn install_extension(step: &ExtensionStep) -> Result<(), String> {
    let result = match run_quiet(&step.code, &["--install-extension", &step.vsix.display().to_string(), "--force"]) {
        Ok((_output, 0)) => Ok(()),
        Ok((output, status)) => {
            let said = output.lines().rfind(|l| !l.trim().is_empty()).unwrap_or("").trim().to_string();
            Err(format!("{} --install-extension exited with {status}{}; nothing changed", step.code.display(), if said.is_empty() { String::new() } else { format!(" ({said})") }))
        }
        Err(why) => Err(format!("{why}; nothing changed")),
    };
    let _ = std::fs::remove_file(&step.vsix);
    result
}

/// Wait for a daemon that said it stops to be gone: nothing answering where `daemon.json`
/// says it listens, asked every quarter second for a minute.
fn daemon_gone() -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_secs(60);
    while Instant::now() < deadline {
        match daemon::read_endpoint() {
            Some(endpoint) if daemon::listening(&endpoint) => std::thread::sleep(Duration::from_millis(250)),
            _ => return Ok(()),
        }
    }
    Err("troupe-daemon said it would stop, and still answers a minute later; nothing changed".into())
}

// -- the commands -----------------------------------------------------------------

/// Find the release to move to and say what an update would do. `Current` when this build
/// is that release or newer: the desktop app never moves back on its own.
#[tauri::command]
pub async fn update_check(app: AppHandle, updates: State<'_, Updates>, params: Option<CheckParams>) -> Result<Checked, String> {
    let params = params.unwrap_or_default();
    let keys = release::trusted_keys();
    let current = release::current_version().to_string();
    let platform = Platform::this();
    let client = client(true)?;

    let plane = match &params.plane {
        Some(word) => Some(plane_word(word).await?),
        None => None,
    };
    // A signed policy says which version to ask for; without one, the page's word does.
    let asked = match &plane {
        Some(word) if word.signed.is_some() => word.policy("desktop").recommended,
        _ => params.version.clone(),
    };
    let source = source(asked.as_deref(), plane.as_ref().and_then(|p| p.release.as_deref())).await?;
    let manifest = signed_manifest(&client, &source, &keys).await?;
    let version = manifest.version.clone();
    if let Some(plane) = &plane {
        served(plane, "desktop", &version)?;
    }
    if !release::wanted(&current, &version) {
        // Blocked here, and pointed at something older: said, never done.
        if let Some(plane) = plane.as_ref().filter(|p| p.policy("desktop").blocked.contains(&current)) {
            if release::older(&version, &current) {
                return Err(format!(
                    "the plane at {} blocks the desktop app {current}, and the version it recommends, {version}, is older: \
                     the desktop app does not move back on its own; install {version} from its release page",
                    plane.url
                ));
            }
        }
        *updates.0.lock().unwrap() = None;
        return Ok(Checked::Current { version, current });
    }

    let artifact = manifest.desktop_update(&platform).cloned().ok_or_else(|| {
        format!("release {version} has no desktop app update for this computer ({}); nothing is installed", platform.target())
    })?;
    let (signature, key) = signature_of(&client, &source.base, &manifest, &artifact, &keys).await?;
    let update = tauri_update(&app, &source.base, &version, &key, &artifact.file, signature).await?;
    let (daemon, daemon_offer, daemon_note) = daemon_step(&manifest, &platform, plane.as_ref(), lib_dir());
    // The terminal's and the extension's versions are programs run, off this thread.
    let (tui_at, tui_from, code_at, code_from) = tauri::async_runtime::spawn_blocking(|| {
        let tui_at = tui_path();
        let tui_from = tui_at.as_deref().and_then(tui_version);
        let code_at = code_cli();
        let code_from = code_at.as_deref().and_then(extension_version);
        (tui_at, tui_from, code_at, code_from)
    })
    .await
    .map_err(|e| e.to_string())?;
    let (tui, tui_offer, tui_note) = tui_step(&manifest, &platform, plane.as_ref(), tui_at, tui_from);
    let (extension, extension_offer, extension_note) = extension_step(&manifest, code_at, code_from);

    let offer = Offer {
        version,
        current,
        source: source.base.clone(),
        daemon: daemon_offer,
        daemon_note,
        tui: tui_offer,
        tui_note,
        extension: extension_offer,
        extension_note,
    };
    *updates.0.lock().unwrap() = Some(Pending { base: source.base, update, app: artifact, daemon, tui, extension, bytes: None });
    Ok(Checked::Offer(Box::new(offer)))
}

#[derive(Clone, Serialize)]
struct Progress {
    received: u64,
    total: Option<u64>,
}

/// Download what the last check offered and check it; nothing in place changes.
#[tauri::command]
pub async fn update_download(app: AppHandle, updates: State<'_, Updates>) -> Result<(), String> {
    let (update, artifact, base, daemon, tui, extension) = {
        let pending = updates.0.lock().unwrap();
        let p = pending.as_ref().ok_or("no update was found to download; check for one first")?;
        (p.update.clone(), p.app.clone(), p.base.clone(), p.daemon.clone(), p.tui.clone(), p.extension.clone())
    };

    let mut received: u64 = 0;
    let mut said: u64 = 0;
    let bytes = update
        .download(
            |chunk, total| {
                received += chunk as u64;
                if received - said >= 512 * 1024 || total == Some(received) {
                    said = received;
                    let _ = app.emit(PROGRESS, Progress { received, total });
                }
            },
            || {},
        )
        .await
        .map_err(|e| format!("{} is not what the release key signed for {} ({e}); nothing is installed", artifact.file, update.version))?;
    release::check_bytes(&artifact, &bytes).map_err(|why| format!("{why}; nothing is installed"))?;

    let http = client(true)?;
    let mut staged = false;
    if let Some(step) = &daemon {
        stage_daemon(&http, &base, step).await?;
        staged = true;
    }
    let mut tui_staged = false;
    if let Some(step) = &tui {
        stage_tui(&http, &base, step).await?;
        tui_staged = true;
    }
    let mut extension_staged = false;
    if let Some(step) = &extension {
        stage_extension(&http, &base, step).await?;
        extension_staged = true;
    }

    let mut pending = updates.0.lock().unwrap();
    let p = pending.as_mut().ok_or("the update was put aside while it downloaded; nothing is installed")?;
    if let Some(step) = p.daemon.as_mut() {
        step.staged = staged;
    }
    if let Some(step) = p.tui.as_mut() {
        step.staged = tui_staged;
    }
    if let Some(step) = p.extension.as_mut() {
        step.staged = extension_staged;
    }
    p.bytes = Some(bytes);
    Ok(())
}

/// Install what was downloaded: the extension with `code`, the daemon's release and the
/// terminal client swapped in, then the app's update, which restarts the app.
/// `daemon_stopped` is the page's word that it asked the daemon to stop between turns and
/// it said it would; that daemon is waited for. One a terminal runs inside itself, or
/// none, is not. The extension goes first, since `code` failing changes nothing else; a
/// terminal client that cannot follow the daemon puts the daemon back, and an app update
/// that cannot follow puts both back.
#[tauri::command]
pub async fn update_install(app: AppHandle, updates: State<'_, Updates>, daemon_stopped: bool) -> Result<(), String> {
    let (update, bytes, daemon, tui, extension) = {
        let pending = updates.0.lock().unwrap();
        let p = pending.as_ref().ok_or("no update was downloaded; nothing is installed")?;
        let bytes = p.bytes.clone().ok_or("the update is not downloaded yet; nothing is installed")?;
        (
            p.update.clone(),
            bytes,
            p.daemon.clone().filter(|d| d.staged),
            p.tui.clone().filter(|t| t.staged),
            p.extension.clone().filter(|x| x.staged),
        )
    };

    if let Some(step) = extension {
        tauri::async_runtime::spawn_blocking(move || install_extension(&step)).await.map_err(|e| e.to_string())??;
    }

    if let Some(step) = &daemon {
        if daemon_stopped {
            tauri::async_runtime::spawn_blocking(daemon_gone).await.map_err(|e| e.to_string())??;
        }
        swap_daemon_in(&step.lib)?;
    }

    if let Some(step) = &tui {
        if let Err(why) = swap_tui_in(&step.path) {
            if let Some(step) = &daemon {
                undo_daemon(&step.lib);
            }
            return Err(why);
        }
    }

    // The daemon and the terminal first: when the app cannot follow them, both go back.
    if let Err(e) = update.install(&bytes) {
        if let Some(step) = &tui {
            undo_tui(&step.path);
        }
        if let Some(step) = &daemon {
            undo_daemon(&step.lib);
        }
        return Err(format!("the desktop app's update could not be installed ({e}); nothing changed"));
    }
    // Windows has exited by now, the setup restarting the app; elsewhere the new app is in
    // place and this one makes way for it.
    app.restart();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest(version: &str, artifacts: Vec<Artifact>) -> Manifest {
        Manifest { version: version.into(), artifacts }
    }

    fn artifact(component: &str, target: &str, file: &str, bytes: &[u8]) -> Artifact {
        Artifact {
            component: component.into(),
            target: Some(target.into()),
            file: file.into(),
            size: bytes.len() as u64,
            sha256: release::sha256_of(bytes),
        }
    }

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("troupe-desktop-update-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A daemon release as the installers leave one: its program and its version.
    fn installed(lib: &Path, version: &str) {
        std::fs::create_dir_all(lib.join("bin")).unwrap();
        std::fs::create_dir_all(lib.join("releases")).unwrap();
        std::fs::write(daemon_bin(lib), "the daemon\n").unwrap();
        std::fs::write(lib.join("releases").join("start_erl.data"), format!("28.5 {version}\n")).unwrap();
    }

    /// A daemon release's archive, as the release publishes it.
    fn archive(version: &str) -> Vec<u8> {
        let mut builder = tar::Builder::new(flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast()));
        let program = format!("the daemon {version}\n");
        let start = format!("28.5 {version}\n");
        for (path, body) in [(daemon_bin(Path::new("")), program.as_bytes()), (Path::new("releases").join("start_erl.data"), start.as_bytes())] {
            let mut header = tar::Header::new_gnu();
            header.set_size(body.len() as u64);
            header.set_mode(0o755);
            header.set_cksum();
            builder.append_data(&mut header, path, body).unwrap();
        }
        builder.into_inner().unwrap().finish().unwrap()
    }

    fn plane(daemon: Policy) -> PlaneWord {
        PlaneWord {
            url: "https://plane.example.test".into(),
            versions: HashMap::from([("daemon".to_string(), daemon)]),
            signed: None,
            release: None,
        }
    }

    // -- the terminal client and the extension --------------------------------------

    #[test]
    fn the_terminal_s_version_and_the_extension_s_are_read_as_the_programs_print_them() {
        assert_eq!(tui_version_of("troupe 0.29.0-beta\n"), "0.29.0-beta");
        assert_eq!(tui_version_of("something else\n"), "unknown version");
        assert_eq!(extension_version_of("ms-python.python@2024.1.0\nObjective-MJ.troupe@0.28.0\n"), Some("0.28.0".into()));
        assert_eq!(extension_version_of("ms-python.python@2024.1.0\n"), None);
        assert_eq!(tui_version(Path::new("/nowhere/troupe")), None);
    }

    #[test]
    fn the_terminal_beside_the_app_is_replaced_when_it_is_older_and_left_when_the_plane_blocks_it() {
        let dir = scratch("tui-older");
        let path = dir.join("troupe");
        std::fs::write(&path, "the terminal 0.14.0-beta\n").unwrap();
        let platform = Platform::this();
        let release = manifest("0.15.0-beta", vec![artifact("tui", &platform.target(), "troupe-0.15.0-beta", b"t")]);

        let (step, offer, note) = tui_step(&release, &platform, None, Some(path.clone()), Some("0.14.0-beta".into()));
        assert!(step.is_some());
        assert_eq!(offer, Some(ComponentOffer { from: "0.14.0-beta".into(), to: "0.15.0-beta".into(), at: path.display().to_string() }));
        assert_eq!(note, None);

        let (step, offer, note) = tui_step(&release, &platform, None, Some(path.clone()), Some("0.15.0-beta".into()));
        assert!(step.is_none() && offer.is_none() && note.is_none());

        let blocking = PlaneWord {
            url: "https://plane.example.test".into(),
            versions: HashMap::from([("tui".to_string(), Policy { blocked: vec!["0.15.0-beta".into()], ..Default::default() })]),
            signed: None,
            release: None,
        };
        let (step, offer, note) = tui_step(&release, &platform, Some(&blocking), Some(path.clone()), Some("0.14.0-beta".into()));
        assert!(step.is_none() && offer.is_none());
        assert!(note.unwrap().contains("blocks troupe 0.15.0-beta"));

        let bare = manifest("0.15.0-beta", vec![]);
        let (_step, _offer, note) = tui_step(&bare, &platform, None, Some(path), Some("0.14.0-beta".into()));
        assert!(note.unwrap().contains("has no troupe for this computer"));

        let (step, offer, note) = tui_step(&release, &platform, None, None, None);
        assert!(step.is_none() && offer.is_none() && note.is_none());
    }

    #[test]
    fn the_extension_is_installed_again_where_code_lists_an_older_one() {
        let release = manifest("0.15.0-beta", vec![artifact("vscode", "", "troupe.vsix", b"v")]);
        let code = PathBuf::from("/fake/code");
        let (step, offer, note) = extension_step(&release, Some(code.clone()), Some("0.14.0".into()));
        assert!(step.is_some());
        assert_eq!(offer.map(|o| (o.from, o.to)), Some(("0.14.0".into(), "0.15.0-beta".into())));
        assert_eq!(note, None);

        let (step, _offer, _note) = extension_step(&release, Some(code.clone()), Some("0.15.0-beta".into()));
        assert!(step.is_none());

        let bare = manifest("0.15.0-beta", vec![]);
        let (step, _offer, note) = extension_step(&bare, Some(code), Some("0.14.0".into()));
        assert!(step.is_none());
        assert!(note.unwrap().contains("release 0.15.0-beta has none"));

        let (step, offer, note) = extension_step(&release, None, None);
        assert!(step.is_none() && offer.is_none() && note.is_none());
    }

    #[test]
    fn the_terminal_is_swapped_in_with_the_old_kept_and_put_back_when_the_app_cannot_follow() {
        let dir = scratch("tui-swap");
        let path = dir.join("troupe");
        std::fs::write(&path, "the terminal 0.14.0-beta\n").unwrap();
        std::fs::write(sibling(&path, ".new"), "the terminal 0.15.0-beta\n").unwrap();
        std::fs::write(sibling(&path, ".in-use-1"), "an old one\n").unwrap();

        swap_tui_in(&path).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "the terminal 0.15.0-beta\n");
        assert_eq!(std::fs::read_to_string(sibling(&path, ".previous")).unwrap(), "the terminal 0.14.0-beta\n");
        assert!(!sibling(&path, ".new").exists());
        assert!(!sibling(&path, ".in-use-1").exists());

        undo_tui(&path);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "the terminal 0.14.0-beta\n");
        assert_eq!(std::fs::read_to_string(sibling(&path, ".new")).unwrap(), "the terminal 0.15.0-beta\n");

        // A second update keeps only the one before it.
        swap_tui_in(&path).unwrap();
        assert_eq!(std::fs::read_to_string(sibling(&path, ".previous")).unwrap(), "the terminal 0.14.0-beta\n");
    }

    #[test]
    fn the_daemon_beside_the_app_is_replaced_when_it_is_older() {
        let dir = scratch("older");
        let lib = dir.join("troupe-daemon");
        installed(&lib, "0.14.0-beta");
        let platform = Platform::this();
        let release = manifest("0.15.0-beta", vec![artifact("daemon", &platform.target(), "troupe-daemon.tar.gz", b"x")]);

        let (step, offer, note) = daemon_step(&release, &platform, None, Some(lib.clone()));
        assert!(step.is_some());
        assert_eq!(offer.unwrap().from, "0.14.0-beta");
        assert_eq!(note, None);

        // Current, or none installed: nothing to do, and nothing said.
        installed(&lib, "0.15.0-beta");
        assert!(daemon_step(&release, &platform, None, Some(lib.clone())).0.is_none());
        assert!(daemon_step(&release, &platform, None, Some(dir.join("none"))).0.is_none());
    }

    #[test]
    fn a_plane_that_blocks_the_release_s_daemon_leaves_it_and_says_why() {
        let dir = scratch("blocked");
        let lib = dir.join("troupe-daemon");
        installed(&lib, "0.14.0-beta");
        let platform = Platform::this();
        let release = manifest("0.15.0-beta", vec![artifact("daemon", &platform.target(), "troupe-daemon.tar.gz", b"x")]);
        let word = plane(Policy { blocked: vec!["0.15.0-beta".into()], ..Policy::default() });

        let (step, _offer, note) = daemon_step(&release, &platform, Some(&word), Some(lib));
        assert!(step.is_none());
        assert!(note.unwrap().contains("blocks troupe-daemon 0.15.0-beta"));
    }

    #[test]
    fn the_daemon_is_unpacked_beside_and_swapped_in_with_the_old_kept() {
        let dir = scratch("swap");
        let lib = dir.join("troupe-daemon");
        installed(&lib, "0.14.0-beta");

        unpack_daemon(&archive("0.15.0-beta"), &lib).unwrap();
        // Nothing in place is touched until the swap.
        assert_eq!(daemon_version(&lib).as_deref(), Some("0.14.0-beta"));
        assert_eq!(daemon_version(&sibling(&lib, ".new")).as_deref(), Some("0.15.0-beta"));

        swap_daemon_in(&lib).unwrap();
        assert_eq!(daemon_version(&lib).as_deref(), Some("0.15.0-beta"));
        assert_eq!(daemon_version(&sibling(&lib, ".previous")).as_deref(), Some("0.14.0-beta"));
        assert!(!sibling(&lib, ".new").exists());

        // And back, when the app cannot follow it.
        undo_daemon(&lib);
        assert_eq!(daemon_version(&lib).as_deref(), Some("0.14.0-beta"));
    }

    #[test]
    fn an_archive_that_is_not_a_daemon_s_release_is_refused_and_leaves_nothing() {
        let dir = scratch("not-a-daemon");
        let lib = dir.join("troupe-daemon");
        installed(&lib, "0.14.0-beta");
        let mut builder = tar::Builder::new(flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast()));
        let mut header = tar::Header::new_gnu();
        header.set_size(2);
        header.set_cksum();
        builder.append_data(&mut header, "README", &b"hi"[..]).unwrap();
        let bytes = builder.into_inner().unwrap().finish().unwrap();

        assert!(unpack_daemon(&bytes, &lib).unwrap_err().contains("holds no"));
        assert!(!sibling(&lib, ".new").exists());
        assert!(unpack_daemon(b"not gzip", &lib).unwrap_err().contains("could not unpack"));
        assert_eq!(daemon_version(&lib).as_deref(), Some("0.14.0-beta"));
    }

    #[test]
    fn a_manifest_of_another_version_is_refused() {
        let source = Source { base: "https://example.test/r".into(), asked: Some("0.15.0-beta".into()), tag: None };
        let old = manifest("0.14.0-beta", vec![]);
        assert_eq!(
            asked_for(&old, &source).unwrap_err(),
            "the release at https://example.test/r is 0.14.0-beta, not 0.15.0-beta; nothing is installed"
        );
        let tagged = Source { base: "https://example.test/r".into(), asked: None, tag: Some("0.15.0-beta".into()) };
        assert!(asked_for(&old, &tagged).unwrap_err().contains("tagged v0.15.0-beta"));
        assert!(asked_for(&manifest("0.15.0-beta", vec![]), &source).is_ok());
    }

    #[test]
    fn a_plane_never_has_a_blocked_or_too_old_version_installed() {
        let word = PlaneWord {
            url: "https://plane.example.test".into(),
            versions: HashMap::from([(
                "desktop".to_string(),
                Policy { minimum: Some("0.15.0-beta".into()), blocked: vec!["0.15.1-beta".into()], ..Policy::default() },
            )]),
            signed: None,
            release: None,
        };
        assert!(served(&word, "desktop", "0.15.1-beta").unwrap_err().contains("blocks the desktop app 0.15.1-beta"));
        assert!(served(&word, "desktop", "0.14.0-beta").unwrap_err().contains("needs the desktop app 0.15.0-beta or later"));
        assert!(served(&word, "desktop", "0.15.2-beta").is_ok());
    }

    /// A release's files over HTTP, as a mirror serves them: `GET /<name>`, 404 for the rest.
    fn serve(files: Vec<(&'static str, Vec<u8>)>) -> String {
        use std::io::{BufRead, BufReader, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let files: HashMap<String, Vec<u8>> = files.into_iter().map(|(n, b)| (format!("/{n}"), b)).collect();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                let _ = reader.read_line(&mut line);
                let path = line.split_whitespace().nth(1).unwrap_or("/").to_string();
                // The rest of the request, up to the blank line.
                loop {
                    let mut header = String::new();
                    if reader.read_line(&mut header).unwrap_or(0) <= 2 {
                        break;
                    }
                }
                let mut stream = stream;
                let (status, body) = match files.get(&path) {
                    Some(body) => ("200 OK", body.clone()),
                    None => ("404 Not Found", Vec::new()),
                };
                let _ = write!(stream, "HTTP/1.1 {status}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n", body.len());
                let _ = stream.write_all(&body);
            }
        });
        base
    }

    fn vector(name: &str) -> Vec<u8> {
        std::fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../../../test/fixtures/release").join(name)).unwrap()
    }

    // The release's manifest fetched from where it is published, checked against the keys
    // this build trusts, and held to the version asked for: the shared vectors, served.
    #[test]
    fn a_release_s_manifest_is_fetched_and_checked_before_anything_else() {
        let current = release::parse_public_key(&String::from_utf8(vector("keys/current.pub")).unwrap()).unwrap();
        let other = release::parse_public_key(&String::from_utf8(vector("keys/other.pub")).unwrap()).unwrap();
        let base = serve(vec![
            ("signed/manifest.json", vector("manifest.json")),
            ("signed/manifest.json.minisig", vector("signatures/current.minisig")),
            ("changed/manifest.json", vector("manifest-tampered.json")),
            ("changed/manifest.json.minisig", vector("signatures/current.minisig")),
        ]);
        let http = client(true).unwrap();
        let at = |dir: &str, asked: Option<&str>| Source { base: format!("{base}/{dir}"), asked: asked.map(Into::into), tag: None };
        let check = |source: Source, keys: Vec<TrustedKey>| {
            tauri::async_runtime::block_on(signed_manifest(&http, &source, &keys)).map(|m| m.version)
        };

        assert_eq!(check(at("signed", None), vec![current.clone()]).unwrap(), "9.9.9-test");
        assert_eq!(check(at("signed", Some("9.9.9-test")), vec![current.clone()]).unwrap(), "9.9.9-test");
        assert!(check(at("signed", Some("9.9.10-test")), vec![current.clone()]).unwrap_err().contains("is 9.9.9-test, not 9.9.10-test"));
        assert!(check(at("signed", None), vec![other]).unwrap_err().contains("does not trust"));
        assert!(check(at("changed", None), vec![current.clone()]).unwrap_err().contains("changed after it was signed"));
        assert!(check(at("missing", None), vec![current]).unwrap_err().contains("has no manifest.json"));
    }

    /// A plane's version policy signed by the key from a seed of `seed`s, naming `release`
    /// as where releases are, and the daemon's `identity.get` pinning the key of `pinned`.
    fn signed_policy(seed: u8, pinned: u8, release: &str) -> (Signed, serde_json::Value) {
        use base64::Engine;
        use ring::signature::{Ed25519KeyPair, KeyPair};
        let b64 = base64::engine::general_purpose::STANDARD;
        let pair = |s: u8| Ed25519KeyPair::from_seed_unchecked(&[s; 32]).unwrap();
        let signer = pair(seed);
        let held = pair(pinned);

        let document = format!(
            r#"{{"body":{{"release":{{"url":"{release}"}},"versions":{{"desktop":{{"blocked":[],"minimum":"0.20.0-beta","recommended":"9.9.9-test"}}}}}},"expires_at":"2999-01-01T00:00:00Z","kind":"client_versions","plane":"https://plane.example.test","signed_at":"2026-10-23T12:00:00Z"}}"#
        );
        let signed = Signed {
            algorithm: "ed25519".into(),
            fingerprint: Some(plane_word::fingerprint(signer.public_key().as_ref())),
            document: document.clone(),
            signature: b64.encode(signer.sign(document.as_bytes()).as_ref()),
        };
        let identity = serde_json::json!({ "plane_key": {
            "public_key": b64.encode(held.public_key().as_ref()),
            "fingerprint": plane_word::fingerprint(held.public_key().as_ref()),
            "plane_url": "https://plane.example.test/"
        }});
        (signed, identity)
    }

    fn page(signed: Signed) -> PlaneWord {
        // What the page says beside the signed answer is not read.
        let page_says = Policy { recommended: Some("0.1.0".into()), ..Policy::default() };
        PlaneWord {
            url: "https://plane.example.test".into(),
            versions: HashMap::from([("desktop".to_string(), page_says)]),
            signed: Some(signed),
            release: None,
        }
    }

    // The plane names where releases are in what it signed; the shell reads it there, and
    // the release found is still held to the manifest the release key signed.
    #[test]
    fn a_release_url_is_taken_only_from_a_policy_the_pinned_key_signed() {
        let current = release::parse_public_key(&String::from_utf8(vector("keys/current.pub")).unwrap()).unwrap();
        let base = serve(vec![
            ("downloads/v9.9.9-test/manifest.json", vector("manifest.json")),
            ("downloads/v9.9.9-test/manifest.json.minisig", vector("signatures/current.minisig")),
        ]);
        let now = std::time::SystemTime::now();

        let (signed, identity) = signed_policy(7, 7, &format!("{base}/downloads"));
        let word = signed_word(&page(signed.clone()), &signed, Ok(identity), now).unwrap();
        assert_eq!(word.release.as_deref(), Some(format!("{base}/downloads").as_str()));
        assert_eq!(word.policy("desktop").recommended.as_deref(), Some("9.9.9-test"));
        assert_eq!(word.policy("desktop").minimum.as_deref(), Some("0.20.0-beta"));

        let found = tauri::async_runtime::block_on(source(word.policy("desktop").recommended.as_deref(), word.release.as_deref())).unwrap();
        assert_eq!(found.base, format!("{base}/downloads/v9.9.9-test"));
        let manifest = tauri::async_runtime::block_on(signed_manifest(&client(true).unwrap(), &found, &[current])).unwrap();
        assert_eq!(manifest.version, "9.9.9-test");

        // Signed by another key than the one the daemon pinned: refused, with the sentence,
        // before anything is fetched from the URL it names.
        let (forged, pinned_elsewhere) = signed_policy(9, 7, "https://mirror.example.test");
        let why = signed_word(&page(forged.clone()), &forged, Ok(pinned_elsewhere), now).unwrap_err();
        assert!(why.starts_with("the version policy from https://plane.example.test is signed by the key"), "{why}");
        assert!(why.ends_with("nothing is installed"), "{why}");

        // No daemon to ask, or none that pinned a key for this plane: refused too.
        assert!(signed_word(&page(forged.clone()), &forged, Err("no daemon".into()), now).unwrap_err().contains("is not checked (no daemon)"));
        let why = signed_word(&page(forged.clone()), &forged, Ok(serde_json::json!({ "linked": true })), now).unwrap_err();
        assert!(why.contains("holds no key for that plane"), "{why}");
    }

    #[test]
    fn a_plane_s_release_url_needs_a_version_and_the_person_s_own_url_wins() {
        let found = tauri::async_runtime::block_on(source(Some("0.24.0-beta"), Some("https://plane.example.test/downloads"))).unwrap();
        assert_eq!(found, Source { base: "https://plane.example.test/downloads/v0.24.0-beta".into(), asked: Some("0.24.0-beta".into()), tag: None });

        let why = tauri::async_runtime::block_on(source(None, Some("https://plane.example.test/downloads"))).unwrap_err();
        assert!(why.contains("recommends no version of the desktop app"), "{why}");
    }

    #[test]
    fn an_update_s_signature_names_the_key_the_updater_is_given() {
        use base64::Engine;
        let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../../../test/fixtures/release");
        let read = |f: &str| std::fs::read_to_string(fixtures.join(f)).unwrap();
        let current = release::parse_public_key(&read("keys/current.pub")).unwrap();
        let other = release::parse_public_key(&read("keys/other.pub")).unwrap();
        // Tauri's `.sig`: the minisign signature, base64-encoded.
        let sig = base64::engine::general_purpose::STANDARD.encode(read("signatures/current.minisig"));

        assert_eq!(signing_key(&sig, &[other.clone(), current.clone()]).unwrap().id, current.id);
        assert!(signing_key(&sig, &[other]).unwrap_err().contains("does not trust"));
        assert!(signing_key("not base64!", &[current]).is_err());
    }
}
