// Mine: what is a person's own on this plane, for everybody who signs in, administrators
// too. The laptops' sessions offered to them, steered from here as themselves; their own
// sessions on the plane; which version of each of their clients the plane last saw, against
// its policy; the memory their organisation gives their machines, to read; and their own
// memory (#55's user level), which every session of theirs reads on every machine, to
// change, with the preview the administrators' pages have.
//
// Nothing here is an administrative call. Each is what any client of the person's asks the
// plane as that person (`sessions.list`, `remote.*`, `me.clients`, `me.memory`,
// `me.memory.preview`, `me.memory.put`), so the plane answers it as it answers the desktop
// app, and a member is shown nothing of anybody else's.

import { useState } from "react";
import type { JSX } from "react";
import type { OwnMemory, OwnMemoryPreview, OwnMemorySaved, SessionRow } from "@troupe/client";
import { describeError, show, useConsole, useLoad } from "../console";
import { Empty, Field, Loaded, Preview, Region, Status, TextDiff, count, when } from "./bits";
import type { StatusKind } from "./bits";
import { InvitedToYou } from "./Invited";
import { RemoteSessions, useOffered } from "./Remote";

/** One of the person's clients, as the plane last saw it. */
interface ClientSeen {
  component: string;
  version: string;
  platform?: string | null;
  seen_at?: string | null;
  standing: string;
  recommended?: string | null;
}

/** A memory document a person's machine reads, as `me.memory` answers it. */
interface MemoryDocument {
  scope: string;
  name?: string | null;
  version: number;
  updated_at?: string | null;
  text: string;
}

const COMPONENT: Record<string, string> = { tui: "terminal", daemon: "daemon", desktop: "desktop app" };

const STANDING: Record<string, { kind: StatusKind; glyph: string; word: string; why: (c: ClientSeen) => string | null }> = {
  current: { kind: "running", glyph: "●", word: "current", why: () => null },
  behind: { kind: "waiting", glyph: "◐", word: "behind", why: (c) => (c.recommended ? `the plane recommends ${c.recommended}` : "the plane recommends a newer one") },
  refused: { kind: "denied", glyph: "✕", word: "refused", why: () => "at its next start: update it" },
};

export function Mine(): JSX.Element {
  const { me, plane } = useConsole();
  const [offered, reload, invites] = useOffered();
  return (
    <div className="page mine">
      <p className="lead">
        What is yours on {plane.name}, {me.display_name ?? me.subject}: the sessions offered to you from laptops and those you were invited into, to follow and steer from here, your sessions, your clients'
        versions, and the memory your machines read.
      </p>
      <RemoteSessions load={offered} reload={reload} />
      <InvitedToYou load={invites} reload={reload} />
      <YourSessions />
      <YourClients />
      <YourMemory />
    </div>
  );
}

function YourSessions(): JSX.Element {
  const { auth, me } = useConsole();
  const [load, reload] = useLoad(() => auth.rpc<{ sessions: SessionRow[] }>("sessions.list", {}).then((r) => r.sessions.filter((s) => s.owner === me.subject)), [auth, me.subject]);
  return (
    <section aria-label="Your sessions">
      <Region>Your sessions</Region>
      <Loaded load={load} what="your sessions" retry={reload}>
        {(rows) =>
          rows.length === 0 ? (
            <Empty title="No session of yours on the plane">One you start on a worker, from the desktop app or the terminal, is listed here.</Empty>
          ) : (
            <div className="scroll">
              <table className="sessions">
                <thead>
                  <tr>
                    <th>Session</th>
                    <th>Title</th>
                    <th>Profile</th>
                    <th>State</th>
                    <th>Last active</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((s) => (
                    <tr key={s.id}>
                      <td className="mono">{s.id}</td>
                      <td>{s.title ?? "—"}</td>
                      <td>{s.profile ?? "—"}</td>
                      <td>{s.status ? `${s.state} · ${s.status}` : s.state}</td>
                      <td>{when(s.last_active_at ?? null)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )
        }
      </Loaded>
    </section>
  );
}

function YourClients(): JSX.Element {
  const { auth } = useConsole();
  const [load, reload] = useLoad(
    () =>
      auth
        .rpc<{ clients: ClientSeen[] }>("me.clients", {})
        .then((r) => r.clients)
        .catch((e: unknown) => {
          // A plane from before it says nothing of a person's clients.
          if ((e as { code?: unknown }).code === -32601) return null;
          throw e;
        }),
    [auth],
  );
  return (
    <section aria-label="Your clients">
      <Region>Your clients</Region>
      <Loaded load={load} what="your clients' versions" retry={reload}>
        {(clients) =>
          clients === null ? (
            <Empty title="This plane does not say which versions your clients run" />
          ) : clients.length === 0 ? (
            <Empty title="No client of yours has signed in to this plane yet" />
          ) : (
            <ul className="clients-seen">
              {clients.map((c) => {
                const st = STANDING[c.standing] ?? { kind: "muted" as const, glyph: "○", word: c.standing, why: () => null };
                const why = st.why(c);
                return (
                  <li key={c.component}>
                    <b>{COMPONENT[c.component] ?? c.component}</b> <span className="mono">{c.version}</span>
                    {c.platform ? <span className="muted"> on {c.platform}</span> : null}{" "}
                    <Status kind={st.kind} glyph={st.glyph}>
                      {st.word}
                    </Status>
                    {why ? <span className="muted"> · {why}</span> : null}
                    {c.seen_at ? <span className="muted"> · last seen {when(c.seen_at)}</span> : null}
                  </li>
                );
              })}
            </ul>
          )
        }
      </Loaded>
    </section>
  );
}

function YourMemory(): JSX.Element {
  const { auth } = useConsole();
  const [load, reload] = useLoad(
    () =>
      auth
        .rpc<{ documents: MemoryDocument[]; user?: OwnMemory }>("me.memory", {})
        .then((r) => ({ documents: (r.documents ?? []).filter((d) => d.scope !== "user"), own: r.user ?? null }))
        .catch((e: unknown) => {
          if ((e as { code?: unknown }).code === -32601) return { documents: [] as MemoryDocument[], own: null };
          throw e;
        }),
    [auth],
  );
  return (
    <section aria-label="Your memory">
      <Region>Your memory</Region>
      <p className="note">What every session on your machines starts from, as instructions from your organisation, before your own. Read-only here: an administrator of its scope keeps it.</p>
      <Loaded load={load} what="your memory" retry={reload}>
        {({ documents, own }) => (
          <>
            {documents.length === 0 ? (
              <Empty title="Your organisation keeps no memory for you" />
            ) : (
              documents.map((d) => (
                <article key={`${d.scope}/${d.name ?? ""}`} className="memory-read" aria-label={d.scope === "team" ? `The ${d.name} team's memory` : "The organisation's memory"}>
                  <h3>
                    {d.scope === "team" ? `The ${d.name} team's` : "The organisation's"} <span className="meta">version {show(d.version)}{d.updated_at ? ` · ${when(d.updated_at)}` : ""}</span>
                  </h3>
                  <pre className="memory-text">{d.text}</pre>
                </article>
              ))
            )}
            {own && <YourOwn key={own.version} own={own} onSaved={reload} />}
          </>
        )}
      </Loaded>
    </section>
  );
}

/**
 * The person's own memory: theirs alone to change, read by every session they run after the
 * organisation's, and added to by an agent of theirs one entry at a time. A change is
 * previewed line by line before it is saved, over the version it was edited from, as an
 * administrator's change of the organisation's is.
 */
function YourOwn({ own, onSaved }: { own: OwnMemory; onSaved: () => void }): JSX.Element {
  const { auth, notify } = useConsole();
  const [draft, setDraft] = useState<string | null>(null);
  const [preview, setPreview] = useState<OwnMemoryPreview | null>(null);
  const [error, setError] = useState<unknown>(null);
  const size = draft === null ? 0 : new TextEncoder().encode(draft).length;

  return (
    <article className="memory-own" aria-label="Your own memory">
      <h3>
        Your own <span className="meta">{own.version > 0 ? `version ${own.version}${own.changed_at ? ` · ${when(own.changed_at)}` : ""} · ${count(own.bytes, "byte")}` : "nothing written yet"}</span>
      </h3>
      <p className="note">
        Every session you run reads it, on every machine, after your organisation's memory and before the repository's files. Only you change it; an agent of yours only adds an entry when
        you ask it to remember something. Nobody else reads it.
      </p>
      {draft === null && own.text !== "" && <pre className="memory-text">{own.text}</pre>}
      {draft === null && (
        <div className="actions">
          <button type="button" onClick={() => setDraft(own.text)}>
            Change your memory
          </button>
        </div>
      )}

      {draft !== null && preview === null && (
        <form
          className="edit wide"
          onSubmit={(e) => {
            e.preventDefault();
            setError(null);
            auth.rpc<OwnMemoryPreview>("me.memory.preview", { text: draft }).then(setPreview, setError);
          }}
        >
          <Field label="Your own memory" hint={`${size} of ${own.limit} bytes`} error={size > own.limit ? `At most ${own.limit} bytes.` : null}>
            {(p) => <textarea {...p} className="mono source" value={draft} onChange={(e) => setDraft(e.target.value)} rows={12} spellCheck={false} />}
          </Field>
          {error !== null && (
            <p className="field-error" role="alert">
              {describeError(error)}
            </p>
          )}
          <div className="actions">
            <button type="submit" className="primary" disabled={size > own.limit}>
              Preview
            </button>
            <button type="button" onClick={() => setDraft(null)}>
              Cancel
            </button>
          </div>
        </form>
      )}

      {draft !== null && preview !== null && (
        <Preview
          title="Your own memory"
          lines={preview.unchanged ? [] : [{ field: "text", from: own.version, to: own.version + 1 }]}
          body={<TextDiff title={`your memory v${own.version} → v${own.version + 1}`} lines={preview.unchanged ? [] : preview.diff} />}
          effects={[preview.effect, `${preview.bytes} of ${preview.limit} bytes.`]}
          verb="Save"
          onConfirm={async () => {
            const saved = await auth.rpc<OwnMemorySaved>("me.memory.put", { text: draft, version: own.version });
            notify(saved.changed ? `Your memory is saved as version ${saved.user.version}; your sessions read it from their next turn.` : "Your memory is as it was.");
            setPreview(null);
            setDraft(null);
            onSaved();
          }}
          onCancel={() => setPreview(null)}
        />
      )}
    </article>
  );
}
