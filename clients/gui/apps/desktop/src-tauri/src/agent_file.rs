// An agent's file in the person's own editor (troupe #594): the agent picker's Edit, for
// a person's agents and a repository's. A page cannot start a program, and the opener's
// own `open_path` would let it open any path at all, so this is a command of ours that
// opens one kind of file and nothing else: a `.md` in an `agents` directory whose parent is
// a repository's `.troupe` or Troupe's own config directory (`troupe`, under `%APPDATA%` or
// `~/.config`). It is judged where the file really is, links followed, so a link dressed as
// an agent's file is judged by what it points at. The file opens in whatever the system
// opens Markdown with, which is the person's editor; the daemon checks what they save the
// next time it reads the agents, as it checks any edit made by hand.

use std::path::{Path, PathBuf};
use tauri::AppHandle;
use tauri_plugin_opener::OpenerExt;

/// The file to open, where it really is, or why it is not an agent's file.
pub(crate) fn agent_file(path: &str) -> Result<PathBuf, String> {
    let given = Path::new(path);
    if !given.is_absolute() {
        return Err(format!("{path} is not an agent's file here: its path is not a whole one"));
    }
    let real = std::fs::canonicalize(given).map_err(|e| format!("{path} cannot be opened: {e}"))?;
    let named = |p: Option<&Path>, names: &[&str]| {
        p.and_then(Path::file_name)
            .and_then(|n| n.to_str())
            .is_some_and(|n| names.iter().any(|want| n.eq_ignore_ascii_case(want)))
    };
    let markdown = real.extension().and_then(|e| e.to_str()).is_some_and(|e| e.eq_ignore_ascii_case("md"));
    let dir = real.parent();
    if real.is_file() && markdown && named(dir, &["agents"]) && named(dir.and_then(Path::parent), &[".troupe", "troupe"]) {
        Ok(real)
    } else {
        Err(format!(
            "{path} is not an agent's file: only a .md in a repository's .troupe/agents or in your own Troupe agents opens from here"
        ))
    }
}

/// The path as the system's opener takes it: on Windows without the `\\?\` a real path has.
fn shown(file: &Path) -> String {
    let text = file.to_string_lossy();
    text.strip_prefix(r"\\?\").unwrap_or(&text).to_string()
}

#[tauri::command]
pub fn agent_file_open(app: AppHandle, path: String) -> Result<(), String> {
    let file = agent_file(&path)?;
    app.opener()
        .open_path(shown(&file), None::<&str>)
        .map_err(|e| format!("nothing on this computer opened {path}: {e}"))
}

#[cfg(test)]
mod tests {
    use super::agent_file;
    use std::fs;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("troupe-agent-file-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_repository_s_and_a_person_s_agent_file_open() {
        let base = scratch("ok");
        for home in [".troupe", "troupe"] {
            let dir = base.join(home).join("agents");
            fs::create_dir_all(&dir).unwrap();
            let file = dir.join("careful.md");
            fs::write(&file, "---\nmode: primary\n---\nYou read.\n").unwrap();
            assert!(agent_file(file.to_str().unwrap()).is_ok(), "{home}");
        }
        let _ = fs::remove_dir_all(&base);
    }

    #[test]
    fn anything_else_is_refused_and_says_so() {
        let base = scratch("no");
        let agents = base.join(".troupe").join("agents");
        fs::create_dir_all(&agents).unwrap();
        let script = agents.join("run.cmd");
        fs::write(&script, "echo hi").unwrap();
        let elsewhere = base.join("notes").join("agents");
        fs::create_dir_all(&elsewhere).unwrap();
        let loose = elsewhere.join("careful.md");
        fs::write(&loose, "x").unwrap();

        for refused in [script.to_str().unwrap(), loose.to_str().unwrap(), agents.to_str().unwrap(), "careful.md"] {
            let why = agent_file(refused).unwrap_err();
            assert!(why.contains("not an agent's file") || why.contains("cannot be opened"), "{refused}: {why}");
        }
        assert!(agent_file(agents.join("missing.md").to_str().unwrap()).unwrap_err().contains("cannot be opened"));
        let _ = fs::remove_dir_all(&base);
    }
}
