// Sessions, as metadata: who owns each, where it runs, what state it is in, what it holds
// and whether somebody pinned it. Never what it said: no administrative method returns
// that, so there is nothing here that could show it. Every session for a platform admin,
// their teams' for a team admin, as `admin.sessions.list` answers each.
//
// Filtered by state and profile at the plane, searched here over what came back, and paged.
// A session is erased behind `admin.session.erase.preview`: what goes, that its key goes
// with it, and the forks that survive because each has its own; then typed by its id.

import { useState } from "react";
import type { JSX } from "react";
import type { AdminSessionRow, SessionErasePreview, SessionErased } from "@troupe/client";
import { recorded, useConsole, useLoad } from "../console";
import { AuditNote, Empty, Field, Loaded, Preview, Status, bytes, count, when } from "./bits";
import type { StatusKind } from "./bits";

const PAGE = 25;

/** What the plane answers at most, newest activity first, when asked for no fewer. */
const PLANE_LIMIT = 200;

const STATE: Record<string, { kind: StatusKind; glyph: string; word: string }> = {
  active: { kind: "running", glyph: "●", word: "active" },
  dormant: { kind: "dormant", glyph: "◑", word: "dormant" },
  read_only: { kind: "muted", glyph: "◇", word: "read-only" },
  erasure_pending: { kind: "denied", glyph: "✕", word: "erasure pending" },
};

export function Sessions(): JSX.Element {
  const { admin, me, notify } = useConsole();
  const [state, setState] = useState("");
  const [profile, setProfile] = useState("");
  const [query, setQuery] = useState("");
  const [page, setPage] = useState(0);
  const [erasing, setErasing] = useState<AdminSessionRow | null>(null);
  const [done, setDone] = useState<{ id: string; answer: SessionErased; detail: Record<string, unknown> | null } | null>(null);
  const [load, reload] = useLoad(() => admin.sessions({ ...(state ? { state } : {}), ...(profile ? { profile } : {}) }), [admin, state, profile]);
  const [profiles] = useLoad(() => admin.profiles().catch(() => []), [admin]);

  const q = query.trim().toLowerCase();
  const narrow = (f: () => void) => {
    f();
    setPage(0);
  };

  return (
    <div className="page">
      <p className="lead">
        Who owns each session, where it runs, what state it is in and what it holds. Metadata only: no administrative role can read what a session
        said.
      </p>
      {done && (
        <>
          <AuditNote action="session.erase" subject={done.id} detail={done.detail} />
          {done.answer.state === "erasure_pending" && (
            <p className="note">Its key was not destroyed, so the erasure is pending: erase it again to try again.</p>
          )}
        </>
      )}
      <div className="toolbar">
        <input aria-label="Search sessions" placeholder="search an id, an owner, a profile…" value={query} onChange={(e) => narrow(() => setQuery(e.target.value))} />
        <Field label="State">
          {(p) => (
            <select {...p} value={state} onChange={(e) => narrow(() => setState(e.target.value))}>
              <option value="">any</option>
              <option value="active">active</option>
              <option value="dormant">dormant</option>
              <option value="read_only">read-only</option>
            </select>
          )}
        </Field>
        <Field label="Profile">
          {(p) => (
            <select {...p} value={profile} onChange={(e) => narrow(() => setProfile(e.target.value))}>
              <option value="">any</option>
              {(profiles.state === "ready" ? profiles.data : []).map((o) => (
                <option key={o.name} value={o.name}>
                  {o.name}
                </option>
              ))}
              {profile && profiles.state === "ready" && !profiles.data.some((o) => o.name === profile) && <option value={profile}>{profile}</option>}
            </select>
          )}
        </Field>
      </div>
      {erasing !== null && (
        <Erase
          session={erasing}
          onCancel={() => setErasing(null)}
          onConfirm={async () => {
            const id = erasing.id;
            const answer = await admin.eraseSession(id);
            setDone({ id, answer, detail: await recorded(admin, me.subject, "session.erase", id) });
            notify(answer.state === "erasure_pending" ? `The erasure of ${id} is pending.` : `${id} is erased.`);
            setErasing(null);
            reload();
          }}
        />
      )}
      <Loaded load={load} what="the sessions" retry={reload}>
        {(sessions) => {
          const shown = sessions.filter((s) => !q || [s.id, s.owner, s.profile ?? ""].some((v) => v.toLowerCase().includes(q)));
          if (sessions.length === 0) {
            return (
              <Empty title={state || profile ? "No session in this state or on this profile" : "No sessions yet"}>
                {state || profile ? "Widen the filters above." : "A session appears here once somebody in a team you administer starts one."}
              </Empty>
            );
          }
          if (shown.length === 0) return <Empty title={`No session matches "${query.trim()}"`}>Search by a session's id, its owner or its profile.</Empty>;
          const pages = Math.ceil(shown.length / PAGE);
          const at = Math.min(page, pages - 1);
          const rows = shown.slice(at * PAGE, at * PAGE + PAGE);
          return (
            <>
              <div className="scroll">
                <table className="sessions">
                  <thead>
                    <tr>
                      <th>Session</th>
                      <th>Owner</th>
                      <th>Profile</th>
                      <th>State</th>
                      <th className="num">Objects</th>
                      <th className="num">Workspace</th>
                      <th>Pinned</th>
                      <th>Last active</th>
                      <th aria-label="Actions" />
                    </tr>
                  </thead>
                  <tbody>
                    {rows.map((s) => (
                      <SessionRow key={s.id} session={s} busy={erasing !== null} onErase={() => setErasing(s)} />
                    ))}
                  </tbody>
                </table>
              </div>
              <div className="pager">
                <span className="meta">
                  {at * PAGE + 1}–{at * PAGE + rows.length} of {shown.length}
                </span>
                {pages > 1 && (
                  <>
                    <button type="button" disabled={at === 0} onClick={() => setPage(at - 1)}>
                      Previous
                    </button>
                    <button type="button" disabled={at >= pages - 1} onClick={() => setPage(at + 1)}>
                      Next
                    </button>
                  </>
                )}
              </div>
              {sessions.length >= PLANE_LIMIT && (
                <p className="note">The plane answers the {PLANE_LIMIT} most recently active; narrow by state or profile to reach older ones.</p>
              )}
            </>
          );
        }}
      </Loaded>
    </div>
  );
}

function SessionRow({ session: s, busy, onErase }: { session: AdminSessionRow; busy: boolean; onErase: () => void }): JSX.Element {
  const st = STATE[s.state] ?? { kind: "muted" as const, glyph: "○", word: s.state };
  return (
    <tr>
      <td className="mono">{s.id}</td>
      <td className="mono">{s.owner}</td>
      <td>{s.profile ?? "—"}</td>
      <td>
        <Status kind={st.kind} glyph={st.glyph}>
          {st.word}
        </Status>
      </td>
      <td className="num">{bytes(s.object_bytes)}</td>
      <td className="num">{bytes(s.workspace_bytes)}</td>
      <td>{s.pinned ? (s.pinned_by ? `pinned by ${s.pinned_by}` : "pinned") : <span className="muted">no</span>}</td>
      <td>{when(s.last_active_at)}</td>
      <td className="row-actions">
        {!busy && (
          <button type="button" onClick={onErase}>
            Erase
          </button>
        )}
      </td>
    </tr>
  );
}

/** What erasing one session takes, read from the plane first, then typed by its id. */
function Erase({ session, onCancel, onConfirm }: { session: AdminSessionRow; onCancel: () => void; onConfirm: () => Promise<void> }): JSX.Element {
  const { admin } = useConsole();
  const id = session.id;
  const [load, reload] = useLoad(() => admin.eraseSessionPreview(id), [admin, id]);
  return (
    <Loaded load={load} what={`what erasing ${id} would take`} retry={reload}>
      {(effect) => (
        <Preview
          title={`session/${id}`}
          lines={[{ field: "state", from: session.state, to: "erased" }]}
          effects={eraseWords(effect)}
          verb={`Erase ${id}`}
          typeToConfirm={effect.confirm || id}
          onCancel={onCancel}
          onConfirm={onConfirm}
        />
      )}
    </Loaded>
  );
}

function eraseWords(e: SessionErasePreview): string[] {
  return [
    `Its key is destroyed, every version of it: no backup of object storage, the database or a volume can recover what ${e.owner}'s session said.`,
    `Every object version under it goes: ${bytes(e.object_bytes)} of objects and ${bytes(e.workspace_bytes)} of workspace.`,
    e.survivor_count === 0
      ? "No fork of it survives, because it has none."
      : `${count(e.survivor_count, "fork survives", "forks survive")}: ${e.survivors.join(", ")}. A fork has its own key; erase each one on its own if that is what you meant.`,
    "Its owner is not told; what it spent stays in the month's total; the audit keeps the erasure, with your name on it.",
  ];
}
