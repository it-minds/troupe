// "Publish…": files from this computer published on the plane as an artifact (troupe #62),
// as the person this computer's daemon is signed in as, through the daemon's sign-in, as
// the terminal client's /publish does. A new artifact, read by the person alone until they
// share it (the default), or by the teams of theirs they tick and the whole organisation;
// the person's own unless they make it the one team's they ticked, every member its owner.
// Or "Publish a new version of…" one of the person's own, the next version at the same
// address with a note, the earlier ones kept, read by whoever reads it now. The daemon sends what is too large
// for one call by an upload handle. The gallery, in the console, is a link away.
//
// The files are read here, in the app, by a file picker; nothing of what they hold is drawn.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { artifactAccessWords, blockedKindWords, blockedWords, errorText } from "@troupe/client";
import type { Artifact, ArtifactBlocked, ArtifactKind, ArtifactList, ArtifactThumbnail, ArtifactUpload, DaemonClient } from "@troupe/client";
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

/** A reply's title: its first line, its Markdown marks left off, at most 80 characters. */
export function replyTitle(text: string): string {
  const first = text.split("\n").find((l) => l.trim() !== "") ?? "";
  const plain = first.replace(/^#+\s*/, "").replace(/[*_`]/g, "").trim();
  return plain.length > 80 ? `${plain.slice(0, 79)}…` : plain;
}

export function Publish({
  daemon,
  sessionId,
  target: chosenTarget,
  reply,
  onClose,
}: {
  daemon: DaemonClient;
  sessionId?: string | undefined;
  /** One of the person's own, chosen already: the gallery's "Publish a new version". */
  target?: string | undefined;
  /** A reply's Markdown, from its Publish: the one file, a document titled by its first line. */
  reply?: string | undefined;
  onClose: () => void;
}): JSX.Element {
  const [list, setList] = useState<ArtifactList & { plane_url?: string } | null>(null);
  const [listError, setListError] = useState<string | null>(null);
  const [mode, setMode] = useState<"new" | "version">(chosenTarget ? "version" : "new");
  const [target, setTarget] = useState<string>(chosenTarget ?? "");
  const [files, setFiles] = useState<File[]>(() => (reply ? [new File([reply], "reply.md", { type: "text/markdown" })] : []));
  const [title, setTitle] = useState(() => (reply ? replyTitle(reply) : ""));
  // Who reads a new one: the teams of theirs ticked, and the organisation switch.
  const [teams, setTeams] = useState<string[]>([]);
  const [organisation, setOrganisation] = useState(false);
  // Whether it is the one team's ticked rather than the person's: off unless they say so.
  const [teamOwned, setTeamOwned] = useState(false);
  const [note, setNote] = useState("");
  // A picture of it for its gallery card, which the plane keeps with this version alone.
  const [picture, setPicture] = useState<File | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<(Artifact & { blocked?: ArtifactBlocked[] }) | null>(null);

  useEffect(() => {
    let live = true;
    daemon.artifacts({ mine: true }).then(
      (l) => live && setList(l),
      (e: unknown) => live && setListError(errorText(e)),
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
  const forTeam = !chosen && teams.length === 1;

  const publish = async (): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      const sent = await uploads(files);
      const published = await daemon.publishArtifact({
        title: chosen ? chosen.title : title.trim(),
        kind,
        // A new version keeps who reads it: neither the switch nor the teams go with one.
        ...(chosen ? {} : { visibility: organisation ? "organisation" : "private", teams }),
        files: sent,
        ...(forTeam && teamOwned ? { owner: "team" } : {}),
        ...(chosen ? { id: chosen.id } : {}),
        ...(chosen && note.trim() ? { note: note.trim() } : {}),
        ...(sessionId ? { session_id: sessionId } : {}),
        ...(picture ? { thumbnail: { content_type: picture.type as ArtifactThumbnail["content_type"], bytes: base64Of(await picture.arrayBuffer()) } } : {}),
      });
      setDone(published);
    } catch (e) {
      setError(errorText(e));
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
              {done.title} is published as {done.id}, version {done.version}, {artifactAccessWords({ teams: done.teams ?? [], organisation: done.visibility === "organisation" })}
              {done.owner_team ? `, owned by the ${done.owner_team} team` : ""}.
            </p>
            {/* What the artifacts host will block in it, as the plane read the files. */}
            {done.blocked && done.blocked.length > 0 && (
              <div className="note blocked" role="note">
                <p>{blockedWords(done.blocked.length)}</p>
                <ul>
                  {done.blocked.map((b, i) => (
                    <li key={i}>
                      <code>{b.file}</code> {b.reference} ({blockedKindWords(b.kind)})
                    </li>
                  ))}
                </ul>
              </div>
            )}
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
            <p className="hint">An artifact may load only its own files: no stylesheet, script, font or image from another site, and no inline script.</p>
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
            <label>
              A picture of it for its card, if you have one (PNG, JPEG or WebP, at most 256 KiB)
              <input type="file" accept="image/png,image/jpeg,image/webp" onChange={(e) => setPicture(e.target.files?.[0] ?? null)} />
            </label>
            {mode === "new" && (
              <>
                <label>
                  Title
                  <input value={title} onChange={(e) => setTitle(e.target.value)} maxLength={200} />
                </label>
                <fieldset className="readers">
                  <legend>Who reads it</legend>
                  {(list?.teams ?? []).map((t) => (
                    <label key={t} className="inline">
                      <input type="checkbox" checked={teams.includes(t)} onChange={(e) => setTeams((now) => (e.target.checked ? [...now, t] : now.filter((x) => x !== t)))} /> The {t} team
                    </label>
                  ))}
                  {(list?.publish_organisation !== "platform_admins" || organisation) && (
                    <label className="inline">
                      <input type="checkbox" checked={organisation} onChange={(e) => setOrganisation(e.target.checked)} /> The whole organisation
                    </label>
                  )}
                  <p className="muted">{teams.length === 0 && !organisation ? "Only you, until you share it from its Access tab." : `It will be ${artifactAccessWords({ teams, organisation })}.`}</p>
                </fieldset>
                {forTeam && (
                  <label className="inline">
                    <input type="checkbox" checked={teamOwned} onChange={(e) => setTeamOwned(e.target.checked)} /> Owned by the {teams[0]} team: anyone on it can change or delete it
                  </label>
                )}
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
