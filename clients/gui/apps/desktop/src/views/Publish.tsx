// "Publish…": files from this computer published on the plane as an artifact (troupe #62),
// as the person this computer's daemon is signed in as, through the daemon's sign-in, as
// the terminal client's /publish does. A new artifact, the person's alone until they share a
// link (the default), or for the whole organisation, a team they are in or a profile's
// people; or "Publish a new version of…" one of the person's own, the next version
// at the same address with a note, the earlier ones kept. The daemon sends what is too large
// for one call by an upload handle. The gallery, in the console, is a link away.
//
// The files are read here, in the app, by a file picker; nothing of what they hold is drawn.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { visibilityWords } from "@troupe/client";
import type { Artifact, ArtifactKind, ArtifactList, ArtifactUpload, DaemonClient } from "@troupe/client";
import { shell } from "../shell";

/** The person's real browser where there is a shell; a webview does nothing useful with a new window. */
async function openExternal(url: string): Promise<void> {
  const open = shell()?.openExternal;
  if (open) await open(url);
  else globalThis.open?.(url, "_blank", "noopener,noreferrer");
}

/** A page, a document or a file, by what was picked: what the plane opens it as. */
export function kindOf(paths: string[]): ArtifactKind {
  if (paths.some((p) => /\.html?$/i.test(p))) return "html";
  if (paths.length === 1 && /\.(md|markdown)$/i.test(paths[0]!)) return "markdown";
  return "file";
}

function base64Of(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

/** The picked files as a publish carries them: each its name, its bytes in base64 and its type. */
async function uploads(files: File[]): Promise<ArtifactUpload[]> {
  return Promise.all(files.map(async (f) => ({ path: f.name, bytes: base64Of(await f.arrayBuffer()), ...(f.type ? { content_type: f.type } : {}) })));
}

function sentence(e: unknown): string {
  const data = (e as { data?: { reason?: unknown } } | null)?.data;
  if (data && typeof data.reason === "string") return data.reason;
  return e instanceof Error ? e.message : String(e);
}

/**
 * Who may open an artifact, as a person chooses it here and in the gallery: only them, the
 * organisation, each of their teams and each profile the plane names for them.
 */
export function VisibilityOptions({ teams, profiles }: { teams?: string[] | undefined; profiles?: string[] | undefined }): JSX.Element {
  return (
    <>
      <option value="private">Only you, until you share a link</option>
      <option value="organisation">The whole organisation</option>
      {(teams ?? []).map((t) => (
        <option key={`team:${t}`} value={`team:${t}`}>
          The {t} team
        </option>
      ))}
      {(profiles ?? []).map((p) => (
        <option key={p} value={`profile:${p}`}>
          The {p} profile's people
        </option>
      ))}
    </>
  );
}

export function Publish({
  daemon,
  sessionId,
  target: chosenTarget,
  onClose,
}: {
  daemon: DaemonClient;
  sessionId?: string | undefined;
  /** One of the person's own, chosen already: the gallery's "Publish a new version". */
  target?: string | undefined;
  onClose: () => void;
}): JSX.Element {
  const [list, setList] = useState<ArtifactList & { plane_url?: string } | null>(null);
  const [listError, setListError] = useState<string | null>(null);
  const [mode, setMode] = useState<"new" | "version">(chosenTarget ? "version" : "new");
  const [target, setTarget] = useState<string>(chosenTarget ?? "");
  const [files, setFiles] = useState<File[]>([]);
  const [title, setTitle] = useState("");
  const [visibility, setVisibility] = useState("private");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<Artifact | null>(null);

  useEffect(() => {
    let live = true;
    daemon.artifacts({ mine: true }).then(
      (l) => live && setList(l),
      (e: unknown) => live && setListError(sentence(e)),
    );
    return () => {
      live = false;
    };
  }, [daemon]);

  const mine = list?.artifacts.filter((a) => a.mine) ?? [];
  const chosen = mine.find((a) => a.id === target) ?? null;
  const paths = files.map((f) => f.name);
  const kind = chosen ? chosen.kind : kindOf(paths);
  const ready = files.length > 0 && (mode === "version" ? chosen !== null : title.trim() !== "");

  const publish = async (): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      const sent = await uploads(files);
      const published = await daemon.publishArtifact({
        title: chosen ? chosen.title : title.trim(),
        kind,
        visibility: chosen ? chosen.visibility : visibility,
        files: sent,
        ...(chosen ? { id: chosen.id } : {}),
        ...(chosen && note.trim() ? { note: note.trim() } : {}),
        ...(sessionId ? { session_id: sessionId } : {}),
      });
      setDone(published);
    } catch (e) {
      setError(sentence(e));
    } finally {
      setBusy(false);
    }
  };

  const gallery = list?.gallery_url ?? null;

  return (
    <div className="scrim" onClick={onClose}>
      <div className="dialog publish" role="dialog" aria-modal="true" aria-label="Publish" onClick={(e) => e.stopPropagation()}>
        <h1>Publish</h1>
        {done ? (
          <>
            <p className="copy">
              {done.title} is published as {done.id}, version {done.version}, for {visibilityWords(done.visibility)}.
            </p>
            <div className="actions">
              {gallery && (
                <button type="button" onClick={() => void openExternal(`${gallery}/${done.id}`)}>
                  Open it in the gallery
                </button>
              )}
              <button type="button" className="primary" onClick={onClose}>
                Done
              </button>
            </div>
          </>
        ) : (
          <>
            <p className="copy">Files from this computer, published on your Troupe plane as you, served from a host of their own that can reach nothing of yours.</p>
            {listError && <p className="banner error">{listError}</p>}
            <fieldset>
              <legend>What to publish</legend>
              <label className="inline">
                <input type="radio" name="publish-mode" checked={mode === "new"} onChange={() => setMode("new")} /> A new artifact
              </label>
              <label className="inline">
                <input type="radio" name="publish-mode" checked={mode === "version"} disabled={mine.length === 0} onChange={() => setMode("version")} /> Publish a new version of…
              </label>
            </fieldset>
            {mode === "version" && (
              <label>
                Which of yours
                <select value={target} onChange={(e) => setTarget(e.target.value)}>
                  <option value="">Choose one</option>
                  {mine.map((a) => (
                    <option key={a.id} value={a.id}>
                      {a.title} (version {a.version})
                    </option>
                  ))}
                </select>
              </label>
            )}
            <label>
              Files
              <input type="file" multiple onChange={(e) => setFiles([...(e.target.files ?? [])])} />
            </label>
            {files.length > 0 && <p className="hint">{kind === "html" ? "A page" : kind === "markdown" ? "A Markdown document" : "A file"}: {paths.join(", ")}</p>}
            {mode === "new" && (
              <>
                <label>
                  Title
                  <input value={title} onChange={(e) => setTitle(e.target.value)} maxLength={200} />
                </label>
                <label>
                  Who may open it
                  <select value={visibility} onChange={(e) => setVisibility(e.target.value)}>
                    <VisibilityOptions teams={list?.teams} profiles={list?.profiles} />
                  </select>
                </label>
              </>
            )}
            {mode === "version" && (
              <label>
                What changed
                <input value={note} onChange={(e) => setNote(e.target.value)} maxLength={500} />
              </label>
            )}
            {error && <p className="banner error">{error}</p>}
            <div className="actions">
              {gallery && (
                <button type="button" onClick={() => void openExternal(gallery)}>
                  The gallery
                </button>
              )}
              <button type="button" onClick={onClose}>
                Cancel
              </button>
              <button type="button" className="primary" disabled={!ready || busy} onClick={() => void publish()}>
                {busy ? "Publishing…" : mode === "version" ? "Publish the new version" : "Publish"}
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
