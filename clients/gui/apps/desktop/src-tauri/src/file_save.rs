// A file the agent made for the person, saved where they choose (troupe #765): the Save…
// on a transcript's "file ready" line. A page has no filesystem here, and the dialog
// plugin's save verb only answers a path, so this is a command of ours that asks the
// system's save dialog and writes the one path the person chose, and nothing else. The page
// gives the bytes (read with `fs.read` from wherever the session runs) and a name for the
// dialog to start with, which is only ever a file's name, never a directory.

use tauri::AppHandle;
use tauri_plugin_dialog::DialogExt;

/// The name the dialog starts with: the last part of what the page gave, never a path.
pub(crate) fn suggested(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or("").trim();
    if base.is_empty() || base == "." || base == ".." {
        "file".to_string()
    } else {
        base.to_string()
    }
}

/// Where the person saved it, or `None` when they cancelled the dialog.
#[tauri::command]
pub async fn file_save(app: AppHandle, name: String, content: String) -> Result<Option<String>, String> {
    let Some(chosen) = app.dialog().file().set_file_name(suggested(&name)).blocking_save_file() else {
        return Ok(None);
    };
    let path = chosen.into_path().map_err(|e| format!("{name} was not saved: {e}"))?;
    std::fs::write(&path, content.as_bytes()).map_err(|e| format!("{} could not be written: {e}", path.display()))?;
    Ok(Some(path.to_string_lossy().into_owned()))
}

#[cfg(test)]
mod tests {
    use super::suggested;

    #[test]
    fn the_dialog_starts_from_the_file_s_own_name_and_never_a_path() {
        assert_eq!(suggested("report.md"), "report.md");
        assert_eq!(suggested("out/q3/report.xlsx"), "report.xlsx");
        assert_eq!(suggested(r"..\..\Windows\win.ini"), "win.ini");
        assert_eq!(suggested("../"), "file");
        assert_eq!(suggested(".."), "file");
        assert_eq!(suggested(""), "file");
    }
}
