// Inviting a person into a session by name (troupe #765).
//
// In a session's head, who it is shared with, at what, named for everybody in it; and for
// its owner the invitation itself: a picker of the people the plane knows whom the
// session's profile covers, observe or control, and each invitation taken back. A pod
// session is invited at the plane, where the invitation is the session's grant made
// visible. A private session is invited through this computer's daemon, which puts the
// session's key in the invitee's own slot at the key manager, since only this computer
// holds it, and seals what follows under a new key when an invitation is taken back.
//
// And somebody else's private session they invited this person into: read here from the
// plane's sealed copy, with this person's own keys, through the daemon, since nothing the
// plane serves can open it.

import { useCallback, useEffect, useRef, useState } from "react";
import type { JSX } from "react";
import { emptyTranscript, fold, invitationWords, inviteRefusal, personName, removedSentence, roleWords } from "@troupe/client";
import type { AuthSession, DaemonClient, FleetRow, Invitee, InviteRole, Person, TranscriptState, TroupeEvent } from "@troupe/client";

/** How the head reaches a session's invitations: the plane for a pod session, the daemon for a private one. */
interface Inviting {
  list(): Promise<Invitee[]>;
  invite(person: string, role: InviteRole): Promise<unknown>;
  uninvite(person: string): Promise<unknown>;
}

function inviting(row: FleetRow, auth: AuthSession | null, daemon: DaemonClient | null): Inviting | null {
  if (row.kind === "private" && daemon) {
    return {
      list: () => daemon.sessionInvites(row.id).then((r) => r.invites),
      invite: (person, role) => daemon.inviteSession(row.id, person, role),
      uninvite: (person) => daemon.uninviteSession(row.id, person),
    };
  }
  if (row.kind === "team" && auth) {
    return {
      list: () => auth.rpc<{ invites: Invitee[] }>("session.invites", { session_id: row.id }).then((r) => r.invites),
      invite: (subject, role) => auth.rpc("session.invite", { session_id: row.id, subject, role }),
      uninvite: (subject) => auth.rpc("session.uninvite", { session_id: row.id, subject }),
    };
  }
  return null;
}

/** Who it is shared with, in a line: "Shared with Bea (follows), Cy (steers)". */
export function sharedWords(invites: Invitee[]): string | null {
  if (invites.length === 0) return null;
  return `Shared with ${invites.map((i) => `${personName(i)} (${roleWords(i.role)})`).join(", ")}`;
}

/**
 * A session's invitations, in its head. Everybody in it sees whom it is shared with; its
 * owner, or a team's admin on a pod session, invites and takes back.
 */
export function InviteControl({
  auth,
  daemon,
  row,
}: {
  auth: AuthSession | null;
  daemon: DaemonClient | null;
  row: FleetRow;
}): JSX.Element | null {
  const reach = inviting(row, auth, daemon);
  // A private session listed by this computer's daemon is this person's own; a pod
  // session's owner is who the plane says.
  const owner = row.kind === "private" || row.yourRole === "owner";
  const [invites, setInvites] = useState<Invitee[]>([]);
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [found, setFound] = useState<Person[]>([]);
  const [chosen, setChosen] = useState<string>("");
  const [role, setRole] = useState<InviteRole>("observe");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(() => {
    if (!reach) return;
    reach
      .list()
      .then(setInvites)
      // A plane from before #765 lists nobody, which is nobody shown rather than a fault.
      .catch(() => setInvites([]));
  }, [row.id, row.kind, Boolean(auth), Boolean(daemon)]);

  useEffect(load, [load]);

  // The picker: people whose name starts with what is typed, among those the plane says
  // this session may be shared with.
  useEffect(() => {
    const q = query.trim();
    if (!open || !auth || q === "") return setFound([]);
    let live = true;
    const t = setTimeout(() => {
      auth
        .rpc<{ people: Person[] }>("people.search", row.kind === "team" ? { query: q, session_id: row.id } : { query: q })
        .then((r) => live && setFound(r.people.filter((p) => !invites.some((i) => i.subject === p.subject))))
        .catch(() => live && setFound([]));
    }, 150);
    return () => {
      live = false;
      clearTimeout(t);
    };
  }, [auth, open, query, row.id, row.kind, invites]);

  if (!reach) return null;
  const words = sharedWords(invites);
  if (!owner && !words) return null;

  const act = async (f: () => Promise<unknown>): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      await f();
      setOpen(false);
      setQuery("");
      setChosen("");
      load();
    } catch (e) {
      setError(inviteRefusal(e));
    } finally {
      setBusy(false);
    }
  };

  const person = chosen || query.trim();

  return (
    <div className="invites" role="group" aria-label="Shared with">
      {words && <span className="shared">{words}</span>}
      {owner && (
        <button className="tab" onClick={() => setOpen((o) => !o)} aria-expanded={open} disabled={busy}>
          Invite
        </button>
      )}
      {owner &&
        invites.map((i) => (
          <button key={i.subject} className="tab" onClick={() => void act(() => reach.uninvite(i.subject))} disabled={busy} aria-label={`Remove ${personName(i)}`}>
            Remove {personName(i)}
          </button>
        ))}

      {open && (
        <form
          className="invite-form"
          onSubmit={(e) => {
            e.preventDefault();
            if (person) void act(() => reach.invite(person, role));
          }}
        >
          <p>
            {row.kind === "private"
              ? "Invite somebody by name to read this private session. Its key goes from this computer into their own slot at the key manager; the plane cannot read it. Taking it back seals what follows under a new key they never get, and what they read before stays read."
              : "Invite somebody by name. They act under this profile's rules, and see it in their list."}
          </p>
          <label>
            Person
            <input
              value={query}
              onChange={(e) => {
                setQuery(e.target.value);
                setChosen("");
              }}
              placeholder="A name or an email"
            />
          </label>
          {found.length > 0 && (
            <ul className="people" aria-label="People">
              {found.map((p) => (
                <li key={p.subject}>
                  <button
                    type="button"
                    className={chosen === p.subject ? "tab on" : "tab"}
                    onClick={() => {
                      setChosen(p.subject);
                      setQuery(personName(p));
                    }}
                  >
                    {personName(p)}
                    {p.email && p.email !== personName(p) ? ` · ${p.email}` : ""}
                  </button>
                </li>
              ))}
            </ul>
          )}
          <label>
            They may
            <select value={role} onChange={(e) => setRole(e.target.value as InviteRole)}>
              <option value="observe">Follow it</option>
              <option value="control">Steer it</option>
            </select>
          </label>
          <button type="submit" disabled={busy || !person}>
            Invite
          </button>
        </form>
      )}

      {error && (
        <p className="error" role="alert">
          {error}
        </p>
      )}
    </div>
  );
}

/** How often an open shared session is read again from its sealed copy. */
export const sealedTiming = { everyMs: 15_000 };

/**
 * Somebody else's private session, shared with this person: read from the plane's sealed
 * copy through this computer's daemon, with the keys in this person's own slot, and read
 * again while it is open. Following only; steering one goes through its owner's offer.
 */
export function InvitedSession({ daemon, row, onBack }: { daemon: DaemonClient | null; row: FleetRow; onBack: () => void }): JSX.Element {
  const [state, setState] = useState<TranscriptState>(emptyTranscript);
  const [error, setError] = useState<string | null>(null);
  const [reading, setReading] = useState(true);
  const seen = useRef(0);
  const invitation = row.invitation;

  useEffect(() => {
    if (!daemon) return;
    let live = true;
    seen.current = 0;
    setState(emptyTranscript);
    const read = (): void => {
      daemon
        .readSealed(row.id, seen.current)
        .then((r) => {
          if (!live) return;
          setError(null);
          const events = r.events as unknown as TroupeEvent[];
          for (const e of events) if (typeof e.seq === "number") seen.current = Math.max(seen.current, e.seq);
          if (events.length > 0) setState((s) => events.reduce((acc, e) => fold(acc, e, { now: Date.now() }), s));
        })
        .catch((e: unknown) => live && setError(e instanceof Error ? e.message : String(e)))
        .finally(() => live && setReading(false));
    };
    read();
    const t = setInterval(read, sealedTiming.everyMs);
    return () => {
      live = false;
      clearInterval(t);
    };
  }, [daemon, row.id]);

  const words = state.entries.filter((e) => e.kind === "user" || e.kind === "assistant");

  return (
    <section className="session invited">
      <header className="session-head">
        <button className="tab" onClick={onBack}>
          ← Sessions
        </button>
        <h2>{row.title ?? row.id}</h2>
        {invitation && <span className="shared">{invitationWords(invitation)}</span>}
      </header>
      <p className="note">
        {invitation?.owner_name ?? row.owner ?? "Its owner"}'s private session, read on this computer from the plane's sealed copy with your own key. What
        it says is sealed as its owner's machine seals it, so the newest turn arrives once that machine has sealed it.
      </p>
      {!daemon ? (
        <p className="error" role="alert">
          Reading a shared private session needs this computer's daemon: only your own machine can open it.
        </p>
      ) : error ? (
        <p className="error" role="alert">
          {error}
        </p>
      ) : reading ? (
        <p role="status">Reading its sealed copy…</p>
      ) : null}
      <ol className="transcript" aria-label="Transcript">
        {words.map((e) => (
          <li key={e.seq} className={e.kind === "user" ? "person" : "agent"}>
            {e.kind === "user" ? <b>{e.author ?? "somebody"}: </b> : null}
            {e.text}
          </li>
        ))}
      </ol>
    </section>
  );
}

/**
 * An open session as its invitation stands: somebody else's private session is read from
 * its sealed copy, and one opened under an invitation that is then taken back closes with
 * a sentence, as soon as the plane says so over the person's watch.
 */
export function Opened({
  row,
  sessionId,
  daemon,
  onBack,
  children,
}: {
  row: FleetRow | undefined;
  sessionId: string;
  daemon: DaemonClient | null;
  onBack: () => void;
  children: JSX.Element;
}): JSX.Element {
  const invited = useRef<{ id: string; row: FleetRow } | null>(null);
  if (row?.invitation) invited.current = { id: sessionId, row };
  const was = invited.current?.id === sessionId ? invited.current.row : undefined;
  if (was && !row?.invitation) return <Uninvited row={was} onBack={onBack} />;
  if (row?.kind === "invited") return <InvitedSession daemon={daemon} row={row} onBack={onBack} />;
  return children;
}

/** What an open session says once the invitation it was opened under is taken back. */
export function Uninvited({ row, onBack }: { row: FleetRow | undefined; onBack: () => void }): JSX.Element {
  return (
    <section className="session uninvited">
      <p role="alert">{removedSentence(row?.invitation?.owner_name ?? row?.owner ?? null)}</p>
      <button className="tab" onClick={onBack}>
        ← Sessions
      </button>
    </section>
  );
}
