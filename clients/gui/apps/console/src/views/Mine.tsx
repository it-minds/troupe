// Mine: what is a person's own on this plane, for everybody who signs in, administrators
// too. The laptops' sessions offered to them, steered from here as themselves; their own
// sessions on the plane; which version of each of their clients the plane last saw, against
// its policy; the memory their organisation gives their machines, to read; and their own
// memory (#55's user level), which every session of theirs reads on every machine, to
// change, with the preview the administrators' pages have.
//
// Nothing here is an administrative call for a member. Each is what any client of the
// person's asks the plane as that person (`sessions.list`, `remote.*`, `me.clients`,
// `me.memory`, `me.memory.preview`, `me.memory.put`), so the plane answers it as it answers
// the desktop app, and a member is shown nothing of anybody else's. An administrator's role
// also asks `admin.sessions.list`, only to know which of their own sessions Sessions shows
// them, so a row links there where it can.

import { useState } from "react";
import type { JSX } from "react";
import { appLink } from "@troupe/client";
import type { OwnClient, OwnMemory, OwnMemoryPreview, PlaneDocument } from "@troupe/client";
import { OpenInApp } from "./AppBanner";
import { describeError, show, useConsole, useLoad } from "../console";
import { href } from "../route";
import { Empty, Field, Loaded, Preview, Region, SessionState, Status, TextDiff, count, when } from "./bits";
import type { StatusKind } from "./bits";
import { InvitedToYou } from "./Invited";
import { RemoteSessions, useOffered } from "./Remote";

const COMPONENT: Record<string, string> = { tui: "terminal", daemon: "daemon", desktop: "desktop app" };

const STANDING: Record<string, { kind: StatusKind; glyph: string; word: string; why: (c: OwnClient) => string | null }> = {
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

/**
 * The person's sessions on the plane, each saying where it opens: a session is read and
 * steered in the desktop app or the terminal, and one this person's role may see on
 * Sessions links there too. Which those are is what `admin.sessions.list` answers them; a
 * member is asked nothing administrative, and sees the sentence alone.
 */
function YourSessions(): JSX.Element {
  const { auth, admin, me, role, plane } = useConsole();
  const [load, reload] = useLoad(async () => {
    const mine = await auth.withToken((plane, token) => plane.listSessions(token)).then((r) => r.sessions.filter((s) => s.owner === me.subject));
    const seen = role === "member" || mine.length === 0 ? [] : await admin.sessions().catch(() => []);
    return { rows: mine, onSessions: new Set(seen.map((s) => s.id)) };
  }, [auth, admin, me.subject, role]);
  return (
    <section aria-label="Your sessions">
      <Region>Your sessions</Region>
      <Loaded load={load} what="your sessions" retry={reload}>
        {({ rows, onSessions }) =>
          rows.length === 0 ? (
            <Empty title="No session of yours on the plane">One you start on the platform, from the desktop app or the terminal, is listed here.</Empty>
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
                    <th>Where it opens</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((s) => (
                    <tr key={s.id}>
                      <td className="mono">{onSessions.has(s.id) ? <a href={href({ page: "sessions", path: [s.id] })}>{s.id}</a> : s.id}</td>
                      <td>{s.title ?? "—"}</td>
                      <td>{s.profile ?? "—"}</td>
                      <td>
                        <SessionState state={s.state} />
                        {s.state === "active" && s.status && s.status !== "idle" && ` · ${s.status.replace(/_/g, " ")}`}
                      </td>
                      <td>{when(s.last_active_at ?? null)}</td>
                      <td>
                        <OpenInApp link={appLink({ kind: "session", id: s.id, plane: plane.url })} />, or in the terminal.
                        {onSessions.has(s.id) && (
                          <>
                            {" "}
                            What the plane keeps of it is on <a href={href({ page: "sessions", path: [s.id] })}>Sessions</a>.
                          </>
                        )}
                      </td>
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
        .withToken((plane, token) => plane.clientsSeen(token))
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
        .withToken((plane, token) => plane.ownMemory(token))
        .then((r) => ({ documents: (r.documents ?? []).filter((d) => d.scope !== "user"), own: r.user ?? null }))
        .catch((e: unknown) => {
          if ((e as { code?: unknown }).code === -32601) return { documents: [] as PlaneDocument[], own: null };
          throw e;
        }),
    [auth],
  );
  return (
    <section aria-label="Your memory">
      <Region>Your memory</Region>
      <p className="note">What every session on your machines starts from: instructions from your organisation, then your own.</p>
      <Loaded load={load} what="your memory" retry={reload}>
        {({ documents, own }) => (
          <>
            {documents.length === 0 ? (
              <Empty title="Your organisation keeps no memory for you" />
            ) : (
              <p className="note">Your organisation's and your teams' are read-only here: an administrator of each keeps it.</p>
            )}
            {documents.map((d) => (
                <article key={`${d.scope}/${d.name ?? ""}`} className="memory-read" aria-label={d.scope === "team" ? `The ${d.name} team's memory` : "The organisation's memory"}>
                  <h3>
                    {d.scope === "team" ? `The ${d.name} team's` : "The organisation's"} <span className="meta">version {show(d.version)}{d.updated_at ? ` · ${when(d.updated_at)}` : ""}</span>
                  </h3>
                  <pre className="memory-text">{d.text}</pre>
                </article>
              ))}
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
        Yours to change. Every session you run reads it, on every machine, after your organisation's memory and before the repository's files. An agent of yours only adds an entry when
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
            auth.withToken((plane, token) => plane.previewOwnMemory(token, draft)).then(setPreview, setError);
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
            const saved = await auth.withToken((plane, token) => plane.putOwnMemory(token, draft, own.version));
            notify(saved.changed ? `Your memory is saved as version ${saved.user.version}; your sessions read it from their next turn.` : "Your memory is as it was.");
            setPreview(null);
            setDraft(null);
            onSaved();
          }}
          onCancel={() => setPreview(null)}
          cancel="Back to editing"
        />
      )}
    </article>
  );
}
