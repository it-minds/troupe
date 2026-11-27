// What is a person's own on this plane, for everybody who signs in, administrators too, on
// the page where everybody's of that kind is: on Sessions, the laptops' sessions offered to
// them and those they were invited into, steered from here as themselves, and their own
// sessions on the plane; on Client versions, which version of each of their clients the
// plane last saw, against its policy; on Memory, the memory their organisation gives their
// machines, to read, and their own memory (#55's user level), which every session of theirs
// reads on every machine, to change, with the preview the administrators' pages have.
//
// Nothing here is an administrative call for a member. Each is what any client of the
// person's asks the plane as that person (`sessions.list`, `remote.*`, `me.clients`,
// `me.memory`, `me.memory.preview`, `me.memory.put`), so the plane answers it as it answers
// the desktop app, and a member is shown nothing of anybody else's. An administrator's role
// also asks `admin.sessions.list`, only to know which of their own sessions the list of
// every session shows them, so a row links there where it can.

import { Fragment, useState } from "react";
import type { JSX } from "react";
import {
  LIFESPAN_CHOICES,
  lifespanChoice,
  lifespanItem,
  lifespanMark,
  lifespanOf,
  lifespanRefusal,
  planeKnowsLifespans,
  TAKE_BACK_LINE,
  appLink,
  behind,
  configurationLine,
  giveLine,
  owedLine,
  raiseKept,
  raiseRefusal,
  sessionWhose,
  teamWords,
  updateLine,
  versionOf,
  visibilityRefusal,
} from "@troupe/client";
import type { Lifespan, OwnClient, OwnMemory, OwnMemoryPreview, PlaneDocument, SessionRow } from "@troupe/client";
import { OpenInApp } from "./OpenInApp";
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

/** Sessions' Mine: the sessions offered to the person and those they were invited into, then their own on the plane. */
export function MySessions(): JSX.Element {
  const [offered, reload, invites] = useOffered();
  return (
    <>
      <RemoteSessions load={offered} reload={reload} />
      <InvitedToYou load={invites} reload={reload} />
      <YourSessions />
    </>
  );
}

/**
 * Whose one of the person's own sessions on the plane is, and the one control that changes
 * it (troupe #1169): a pod session given to its team, or taken back. A private session is
 * sealed on its owner's machine and is never a team's, so it says so and offers nothing.
 */
function Whose({ session, onChanged }: { session: SessionRow; onChanged: () => void }): JSX.Element {
  const { auth, notify } = useConsole();
  const [busy, setBusy] = useState(false);
  const [refused, setRefused] = useState<string | null>(null);
  if (session.kind === "private") return <span className="muted">only you, sealed on your computer</span>;
  const team = session.visibility === "team";
  const change = async (): Promise<void> => {
    setBusy(true);
    setRefused(null);
    try {
      await auth.withToken((plane, token) => plane.setSessionVisibility(token, session.id, team ? "private" : "team"));
      notify(team ? `${session.title ?? session.id} is yours again.` : `${session.title ?? session.id} is given to ${teamWords(session.team)}.`);
      onChanged();
    } catch (e) {
      setRefused(visibilityRefusal(e, !team));
    } finally {
      setBusy(false);
    }
  };
  return (
    <>
      <span title={team ? giveLine(session.team) : TAKE_BACK_LINE}>{sessionWhose(session.visibility, true)}</span>{" "}
      <button type="button" className="link" disabled={busy} title={team ? TAKE_BACK_LINE : giveLine(session.team)} onClick={() => void change()}>
        {team ? "Only me again" : `Give it to ${teamWords(session.team)}`}
      </button>
      {refused && (
        <span className="hint" role="alert">
          {" "}
          {refused}
        </span>
      )}
    </>
  );
}

/**
 * How long one of the person's own sessions lasts (troupe #1209), and the change to either
 * of the other two, where the plane knows lifespans: a throwaway one says when it goes.
 */
function Lasts({ session, knows, onChanged }: { session: SessionRow; knows: boolean; onChanged: () => void }): JSX.Element {
  const { auth, notify } = useConsole();
  const [busy, setBusy] = useState(false);
  const [refused, setRefused] = useState<string | null>(null);
  const now = lifespanOf(session.lifespan);
  const change = async (to: Lifespan): Promise<void> => {
    setBusy(true);
    setRefused(null);
    try {
      await auth.withToken((plane, token) => plane.setSessionLifespan(token, session.id, to));
      notify(`${session.title ?? session.id} is ${to} now.`);
      onChanged();
    } catch (e) {
      setRefused(lifespanRefusal(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <>
      <span title={lifespanChoice(now).sentence}>{lifespanMark({ lifespan: now, erasesAt: session.erases_at ?? null }) ?? "normal"}</span>
      {knows &&
        LIFESPAN_CHOICES.filter((c) => c.value !== now).map((c) => (
          <Fragment key={c.value}>
            {" · "}
            <button type="button" className="link" disabled={busy} title={c.sentence} onClick={() => void change(c.value)}>
              {lifespanItem(c.value)}
            </button>
          </Fragment>
        ))}
      {refused && (
        <span className="hint" role="alert">
          {" "}
          {refused}
        </span>
      )}
    </>
  );
}

/**
 * Which configuration one of the person's own pod sessions runs on, and Update where its
 * channel has published a newer version (troupe #1177): at once when its agent is at rest,
 * else when the agent is done, which it then says. A session on a computer has no bundle.
 */
function Configuration({ session, onChanged }: { session: SessionRow; onChanged: () => void }): JSX.Element {
  const { auth, notify } = useConsole();
  const [busy, setBusy] = useState(false);
  const [refused, setRefused] = useState<string | null>(null);
  const version = versionOf(session.bundle_version);
  const current = versionOf(session.bundle_current);
  const owed = versionOf(session.bundle_raise_to);
  if (session.kind === "private" || version === null) return <span className="muted">—</span>;
  const update = async (): Promise<void> => {
    setBusy(true);
    setRefused(null);
    try {
      await auth.withToken((plane, token) => plane.raiseSessionBundle(token, session.id));
      notify(`${session.title ?? session.id} runs on v${current} now.`);
    } catch (e) {
      const kept = raiseKept(e);
      if (kept !== null) notify(`${session.title ?? session.id}: ${owedLine(kept).toLowerCase()}.`);
      else setRefused(raiseRefusal(e));
    } finally {
      setBusy(false);
      onChanged();
    }
  };
  return (
    <>
      {configurationLine(version, current)}
      {owed !== null && owed > version ? (
        <span className="muted"> · {owedLine(owed)}</span>
      ) : current !== null && behind(version, current) ? (
        <>
          {" "}
          <button type="button" className="link" disabled={busy} title={updateLine(current, session.status === "thinking" || session.status === "acting")} onClick={() => void update()}>
            Update
          </button>
        </>
      ) : null}
      {refused && (
        <span className="hint" role="alert">
          {" "}
          {refused}
        </span>
      )}
    </>
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
    return { rows: mine, onSessions: new Set(seen.map((s) => s.id)), knows: await planeKnowsLifespans(auth) };
  }, [auth, admin, me.subject, role]);
  return (
    <section aria-label="Your sessions">
      <Region>Your sessions</Region>
      <Loaded load={load} what="your sessions" retry={reload}>
        {({ rows, onSessions, knows }) =>
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
                    <th>Who opens it</th>
                    <th>How long it lasts</th>
                    <th>Configuration</th>
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
                        <Whose session={s} onChanged={reload} />
                      </td>
                      <td>
                        <Lasts session={s} knows={knows} onChanged={reload} />
                      </td>
                      <td>
                        <Configuration session={s} onChanged={reload} />
                      </td>
                      <td>
                        <OpenInApp link={appLink({ kind: "session", id: s.id, plane: plane.url })} />, or in the terminal.
                        {onSessions.has(s.id) && (
                          <>
                            {" "}
                            What the plane keeps of it is under <a href={href({ page: "sessions", path: [s.id] })}>Every session</a>.
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

/** Client versions' first section: which version of each of the person's clients the plane last saw, against its policy. */
export function YourClients(): JSX.Element {
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

/**
 * Memory's section of the person's own: what their machines read from the organisation, and
 * their own to change. `ownOnly` where the page above shows the organisation's levels
 * already, as an administrator's does.
 */
export function YourMemory({ ownOnly = false }: { ownOnly?: boolean }): JSX.Element {
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
      {!ownOnly && <p className="note">What every session on your machines starts from: instructions from your organisation, then your own.</p>}
      <Loaded load={load} what="your memory" retry={reload}>
        {({ documents, own }) => (
          <>
            {ownOnly ? null : documents.length === 0 ? (
              <Empty title="Your organisation keeps no memory for you" />
            ) : (
              <p className="note">Your organisation's and your teams' are read-only here: an administrator of each keeps it.</p>
            )}
            {!ownOnly && documents.map((d) => (
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
        you ask it to remember something. The plane's platform administrators may read it, and each time one does, the audit records who.
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
