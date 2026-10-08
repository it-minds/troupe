// What a window finds as it opens: the folders' Troupe terminals from before a reload, and
// whether Troupe opens as the window opens a folder (`troupe.openOnFolderOpen`, Decision
// 816).
//
// VS Code keeps a terminal, and the TUI in it, across a window reload, but gives it back
// with its process and nothing else: not the name Troupe gave it, nor its icon. So the
// extension keeps the process id of each folder's terminal in the workspace's storage, and
// a terminal whose process is the one kept is that folder's. One still named for a folder
// is too.
//
// Opening with the folder is off until the person turns it on. Then Troupe opens as
// Troupe: Open opens it, except:
// - in a workspace that is not trusted: a program started because a folder was opened is
//   what VS Code's Restricted Mode holds back (it runs no task on a folder's opening
//   either), and Troupe: Open is still there to press. Trusting the workspace opens it then.
// - when a folder's Troupe terminal is there from before a reload: a second Troupe would be
//   a second session.

import { terminalName } from "./folder.js";

/** The folders' terminals from before, by the folder's key: its process kept, or its name. */
export function fromBefore<T>(
  folders: readonly { key: string; name: string }[],
  kept: Readonly<Record<string, number>>,
  terminals: readonly { terminal: T; name: string; pid: number | undefined }[],
): Map<string, T> {
  const found = new Map<string, T>();

  for (const folder of folders) {
    const pid = kept[folder.key];
    const terminal =
      terminals.find((t) => pid !== undefined && t.pid === pid) ?? terminals.find((t) => t.name === terminalName(folder.name));
    if (terminal !== undefined) found.set(folder.key, terminal.terminal);
  }

  return found;
}

export type AtStart = { open: true } | { not: "off" | "no folder" | "untrusted" | "open already" };

export function atStart(window: { enabled: boolean; trusted: boolean; folders: number; open: boolean }): AtStart {
  if (!window.enabled) return { not: "off" };
  if (window.folders === 0) return { not: "no folder" };
  if (!window.trusted) return { not: "untrusted" };
  return window.open ? { not: "open already" } : { open: true };
}
