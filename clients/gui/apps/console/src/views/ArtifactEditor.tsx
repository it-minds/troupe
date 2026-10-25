// Editing an artifact in the console: one text file of a page or a document, changed by
// hand and saved as the next version, by its owner or somebody holding an edit link.
//
// The editor reads the file's text (`artifact.read`) and nothing of the artifact is ever
// drawn here. Its preview is an address on the artifacts host (`artifact.preview`), the
// edited file over the version it was made on, which this page frames in a sandboxed
// iframe: a Markdown document rendered as the host renders it, a page run as the host runs
// it, under the host's own policy, in an origin that can touch nothing of this console's.
// Saving is a put on the version it was made on (`base`), so one somebody published since
// is not lost under it: the plane refuses it and says which version to open instead.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { textBytes } from "@troupe/client";
import type { ArtifactApi, ArtifactDetail, ArtifactFile } from "@troupe/client";
import { describeError, useConsole } from "../console";
import { Field, Region } from "./bits";

/** The files a person edits as text here: the page's or document's own, its styles and scripts. */
const TEXT = /\.(html?|md|markdown|css|js|mjs|json|txt|svg|csv)$/i;

export function editableFiles(files: ArtifactFile[]): ArtifactFile[] {
  return files.filter((f) => TEXT.test(f.path) && f.bytes <= 1024 * 1024);
}

/** The file a version opens on: the page's or the document's entry, else its first text file. */
function entryOf(kind: string, files: ArtifactFile[]): string | null {
  const paths = files.map((f) => f.path);
  const named = kind === "markdown" ? ["index.md", "README.md"] : ["index.html"];
  return named.find((n) => paths.includes(n)) ?? paths[0] ?? null;
}

export function ArtifactEditor({ artifact: a, api, onSaved, onClose }: { artifact: ArtifactDetail; api: ArtifactApi; onSaved: (saved: ArtifactDetail) => void; onClose: () => void }): JSX.Element {
  const { notify } = useConsole();
  const newest = [...a.versions].sort((x, y) => y.n - x.n)[0]!;
  const files = editableFiles(newest.files);
  const [path, setPath] = useState<string | null>(entryOf(a.kind, files));
  const [text, setText] = useState<string | null>(null);
  const [original, setOriginal] = useState<string | null>(null);
  const [note, setNote] = useState("");
  const [preview, setPreview] = useState<string | null>(null);
  const [busy, setBusy] = useState<"reading" | "previewing" | "saving" | null>(null);
  const [error, setError] = useState<unknown>(null);

  useEffect(() => {
    if (!path) return;
    let live = true;
    setBusy("reading");
    setError(null);
    setPreview(null);
    api.read(a.id, path, newest.n).then(
      (read) => {
        if (!live) return;
        setText(read.text);
        setOriginal(read.text);
        setBusy(null);
      },
      (e: unknown) => {
        if (!live) return;
        setError(e);
        setBusy(null);
      },
    );
    return () => {
      live = false;
    };
  }, [api, a.id, path, newest.n]);

  const file = files.find((f) => f.path === path) ?? null;
  const changed = text !== null && text !== original;

  const showPreview = (): void => {
    if (!path || text === null) return;
    setBusy("previewing");
    setError(null);
    api.preview(a.id, newest.n, path, text).then(
      (p) => {
        setPreview(p.url);
        setBusy(null);
      },
      (e: unknown) => {
        setError(e);
        setBusy(null);
      },
    );
  };

  const save = (): void => {
    if (!path || text === null || !file) return;
    setBusy("saving");
    setError(null);
    api.put(a.id, { base: newest.n, files: [{ path, bytes: textBytes(text), content_type: file.content_type }], ...(note.trim() ? { note: note.trim() } : {}) }).then(
      (saved) => {
        setBusy(null);
        notify(`${a.title} is saved as version ${saved.version}.`);
        onSaved(saved);
      },
      (e: unknown) => {
        setError(e);
        setBusy(null);
      },
    );
  };

  if (files.length === 0) {
    return (
      <section aria-label="Edit">
        <Region>Edit</Region>
        <p className="note">Version {newest.n} has no file to edit as text here. Publish a new version of it from where it was made.</p>
        <div className="actions">
          <button type="button" onClick={onClose}>
            Close
          </button>
        </div>
      </section>
    );
  }

  return (
    <section aria-label="Edit" className="artifact-editor">
      <Region>Edit version {newest.n}</Region>
      <p className="lead">Your change is saved as version {newest.n + 1} at the same address, and version {newest.n} is kept. The preview is drawn by the artifacts host, as people will see it.</p>
      <form
        className="edit wide"
        onSubmit={(e) => {
          e.preventDefault();
          save();
        }}
      >
        <Field label="File">
          {(p) => (
            <select {...p} value={path ?? ""} onChange={(e) => setPath(e.target.value)} disabled={busy !== null}>
              {files.map((f) => (
                <option key={f.path} value={f.path}>
                  {f.path}
                </option>
              ))}
            </select>
          )}
        </Field>
        {text !== null && (
          <div className="artifact-edit-panes">
            <Field label={`Text of ${path}`}>{(p) => <textarea {...p} className="mono source" value={text} onChange={(e) => setText(e.target.value)} rows={18} spellCheck={false} />}</Field>
            {preview !== null && (
              <div className="artifact-preview">
                {/* The host's own page, framed: its policy runs it sandboxed, and so does this frame. */}
                <iframe title={`Preview of ${path}`} src={preview} sandbox="allow-scripts" referrerPolicy="no-referrer" />
              </div>
            )}
          </div>
        )}
        <Field label="What changed" hint="A line for the version list, optional.">
          {(p) => <input {...p} value={note} maxLength={500} onChange={(e) => setNote(e.target.value)} />}
        </Field>
        {error !== null && (
          <p className="field-error" role="alert">
            {describeError(error)}
          </p>
        )}
        <div className="actions">
          <button type="button" disabled={text === null || busy !== null} onClick={showPreview}>
            {busy === "previewing" ? "Previewing…" : preview ? "Preview again" : "Preview"}
          </button>
          <button type="submit" className="primary" disabled={!changed || busy !== null}>
            {busy === "saving" ? "Saving…" : `Save as version ${newest.n + 1}`}
          </button>
          <button type="button" onClick={onClose} disabled={busy === "saving"}>
            Cancel
          </button>
        </div>
      </form>
    </section>
  );
}
