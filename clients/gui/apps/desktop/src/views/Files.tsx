// The session's files, read-only. `fs.list` and `fs.read` go through the session's
// mount table, so this is confined to exactly what the agent can see — there is no
// separate file API and no way to climb out of a mount.
//
// The listing refreshes on `fs_changed`, which is the same feed the transcript folds.

import { useCallback, useEffect, useState } from "react";
import type { JSX } from "react";
import type { FsEntry, SessionAttachment } from "@troupe/client";
import { Loading } from "./bits";

export function Files({ attachment }: { attachment: SessionAttachment | null }): JSX.Element {
  const [path, setPath] = useState(".");
  const [entries, setEntries] = useState<FsEntry[]>([]);
  const [open, setOpen] = useState<{ path: string; content: string; hash: string } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const list = useCallback(
    async (at: string) => {
      if (!attachment) return;
      setLoading(true);
      setError(null);
      try {
        const r = await attachment.view.fsList(at);
        setPath(r.path);
        setEntries([...r.entries].sort(byKindThenName));
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
      } finally {
        setLoading(false);
      }
    },
    [attachment],
  );

  useEffect(() => {
    void list(".");
  }, [list]);

  // A file the agent wrote should not need a manual refresh to appear.
  useEffect(() => {
    if (!attachment) return;
    return attachment.view.listen((e) => {
      if (e.type === "fs_changed") void list(path);
    });
  }, [attachment, list, path]);

  const read = async (entry: FsEntry): Promise<void> => {
    if (!attachment) return;
    setError(null);
    try {
      const file = await attachment.view.fsRead(entry.path);
      setOpen({ path: file.path, content: file.content, hash: file.hash });
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  const up = path === "." || path === "" ? null : path.split("/").slice(0, -1).join("/") || ".";

  return (
    <div className="files">
      <div className="tree">
        <header className="crumbs">
          <code>{path === "." ? "/" : path}</code>
          {up !== null && (
            <button className="link" onClick={() => void list(up)}>
              up
            </button>
          )}
          <button className="link" onClick={() => void list(path)}>
            refresh
          </button>
        </header>
        {loading && <Loading what="Reading the files…" />}
        {error && <p className="note error">{error}</p>}
        <ul>
          {entries.map((e) => (
            <li key={e.path}>
              <button
                className={`entry ${e.kind}`}
                onClick={() => (e.kind === "directory" ? void list(e.path) : void read(e))}
              >
                <span className="name">{e.name}</span>
                {e.kind === "file" && <span className="when">{e.size}</span>}
              </button>
            </li>
          ))}
        </ul>
        {!loading && entries.length === 0 && <p className="note">Nothing here.</p>}
      </div>

      <div className="viewer">
        {open ? (
          <>
            <header>
              <code>{open.path}</code>
              <span className="when" title={open.hash}>
                {open.hash.slice(7, 19)}
              </span>
              <button className="link" onClick={() => setOpen(null)}>
                close
              </button>
            </header>
            <pre>{open.content}</pre>
          </>
        ) : (
          <p className="note">Choose a file to read it. Files cannot be edited here.</p>
        )}
      </div>
    </div>
  );
}

function byKindThenName(a: FsEntry, b: FsEntry): number {
  if (a.kind !== b.kind) return a.kind === "directory" ? -1 : 1;
  return a.name.localeCompare(b.name);
}
