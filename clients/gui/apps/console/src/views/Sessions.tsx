// Sessions, as metadata: who owns each, where it runs, what state it is in, what it holds,
// whether somebody pinned it, the branch and draft pull request it left on GitHub, and
// whether a running one's last turn read an older version of its memory than the one in force.
// Never what it said: no administrative method returns
// that, so there is nothing here that could show it. Every session for a platform admin,
// their teams' for a team admin, as `admin.sessions.list` answers each.
//
// Filtered by state and profile at the plane, searched here over what came back, and paged.
// A session is erased behind `admin.session.erase.preview`: what goes, that its key goes
// with it, and the forks that survive because each has its own; then typed by its id.
//
// Beside every session, Mine: the signed-in person's own and the laptops' sessions offered
// to them, which is the whole of a member's Sessions.

import { useState } from "react";
import type { JSX } from "react";
import { bytes, lifespanMark, lifespanOf, nameOrSubject, repositoriesOf, repositoryName, sensitiveMark, sensitiveOf } from "@troupe/client";
import type { AdminSessionRow, SessionErasePreview, SessionErased, SessionGitHub, SessionRepository } from "@troupe/client";
import { recorded, useConsole, useLoad } from "../console";
import { href } from "../route";
import { AuditNote, Empty, Field, Loaded, Preview, Status, count, sessionState, when } from "./bits";
import { MySessions } from "./Yours";

const PAGE = 25;

/**
 * An administrator's two tabs: every session their role may see, and Mine, their own and
 * those offered to them. A member's Sessions is Mine alone, so it has none.
 */
function SessionTabs({ mine }: { mine: boolean }): JSX.Element | null {
  const { role } = useConsole();
  if (role === "member") return null;
  return (
    <nav className="tabs" aria-label="Whose sessions">
      <a href={href({ page: "sessions" })} aria-current={mine ? undefined : "page"}>
        Every session
      </a>
      <a href={href({ page: "sessions", path: ["mine"] })} aria-current={mine ? "page" : undefined}>
        Mine
      </a>
    </nav>
  );
}

/** Sessions' Mine: what is the signed-in person's own, steered from here as themselves. */
export function SessionsMine(): JSX.Element {
  const { me, plane } = useConsole();
  return (
    <div className="page">
      <SessionTabs mine />
      <p className="lead">
        Yours on {plane.name}, {me.display_name ?? me.subject}: the sessions offered to you from laptops and those you were invited into, to follow and steer from here, and your
        sessions on the plane.
      </p>
      <MySessions />
    </div>
  );
}

/** What the plane answers at most, newest activity first, when asked for no fewer. */
const PLANE_LIMIT = 200;

/** `query` is what the search starts with: a run's page links to its session by id. */
export function Sessions({ query: initial = "" }: { query?: string } = {}): JSX.Element {
  const { admin, me, notify } = useConsole();
  const [state, setState] = useState("");
  const [profile, setProfile] = useState("");
  const [query, setQuery] = useState(initial);
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
      <SessionTabs mine={false} />
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
              <option value="dormant">asleep</option>
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
          const shown = sessions.filter((s) => !q || [s.id, s.owner, s.owner_name ?? "", s.profile ?? ""].some((v) => v.toLowerCase().includes(q)));
          if (sessions.length === 0) {
            return (
              <Empty title={state || profile ? "No session in this state or on this profile" : "No sessions yet"}>
                {state || profile ? "Widen the filters above." : "A session appears here once somebody in a team you administer starts one."}
              </Empty>
            );
          }
          if (shown.length === 0) return <Empty title={<>No session matches <code>"{query.trim()}"</code></>}>Search by a session's id, its owner or its profile.</Empty>;
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
                      <th>Lasts</th>
                      <th>Sensitive</th>
                      <th>On GitHub</th>
                      <th>Last active</th>
                      <th className="row-actions" aria-label="Actions" />
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
  const st = sessionState(s.state);
  return (
    <tr>
      <td className="mono">{s.id}</td>
      <td title={s.owner} className={s.owner_name ? undefined : "mono"}>{nameOrSubject(s.owner, s.owner_name)}</td>
      <td>{s.profile ?? "—"}</td>
      <td>
        <Status kind={st.kind} glyph={st.glyph}>
          {st.word}
        </Status>
        {s.memory === "behind" && (
          <span className="memory-mark" title="Its last turn read an older version of its memory than the one in force; it reads the new one at its next turn.">
            {" "}
            · memory: behind
          </span>
        )}
      </td>
      <td className="num">{bytes(s.object_bytes)}</td>
      <td className="num">{bytes(s.workspace_bytes)}</td>
      <td>{s.pinned ? (s.pinned_by ? `pinned by ${s.pinned_by}` : "pinned") : <span className="muted">no</span>}</td>
      <td>{lifespanMark({ lifespan: lifespanOf(s.lifespan), erasesAt: s.erases_at ?? null }) ?? <span className="muted">normal</span>}</td>
      <td>
        <SensitiveCell row={s} />
      </td>
      <td>
        <OnGitHub repositories={repositoriesOf(s)} />
      </td>
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
// What the session did on GitHub, per repository it holds (troupe #1207): the first, and
// every other one under "+N more", opened in place.
/** Whether a session is sensitive (troupe #1239), its title since when and by what; a dash from a plane that does not say. */
function SensitiveCell({ row }: { row: AdminSessionRow }): JSX.Element {
  if (row.sensitive === undefined) return <span className="muted">—</span>;
  const mark = sensitiveMark({ sensitive: sensitiveOf(row.sensitive) }, { nameOf: (s) => (s === row.owner ? row.owner_name : null) });
  return mark ? <span title={mark.title}>{mark.word}</span> : <span className="muted">no</span>;
}

function OnGitHub({ repositories }: { repositories: SessionRepository[] }): JSX.Element {
  const [first, ...rest] = repositories;
  if (!first) return <span className="muted">—</span>;
  const one = (r: SessionRepository): JSX.Element => (
    <span>
      <span className="mono">{repositoryName(r)}</span> <OnRepository github={(r.github ?? null) as SessionGitHub | null} />
    </span>
  );
  if (rest.length === 0) return one(first);
  return (
    <details>
      <summary>
        {one(first)} <span className="muted">+{rest.length} more</span>
      </summary>
      {rest.map((r) => (
        <div key={repositoryName(r)}>{one(r)}</div>
      ))}
    </details>
  );
}

// What the session did on one repository, as its pod reported it: its draft pull request as
// a link, or its branch and last commit before it has opened one, and that it stopped after
// its red CI rounds and left the draft for a person.
function OnRepository({ github }: { github: SessionGitHub | null }): JSX.Element {
  if (!github?.branch) return <span className="muted">nothing pushed</span>;
  const pr = github.pull_request;
  return (
    <span>
      {pr ? (
        <a href={pr.url} target="_blank" rel="noreferrer">
          #{pr.number}
        </a>
      ) : (
        <span className="mono">{(github.commit ?? "").slice(0, 7)}</span>
      )}{" "}
      <span className="mono muted">{github.branch}</span>
      {github.stopped && <span className="muted"> · stopped after its red CI rounds</span>}
    </span>
  );
}

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
          effects={eraseWords(effect, nameOrSubject(effect.owner, effect.owner_name ?? session.owner_name))}
          verb={`Erase ${id}`}
          typeToConfirm={effect.confirm || id}
          onCancel={onCancel}
          onConfirm={onConfirm}
        />
      )}
    </Loaded>
  );
}

function eraseWords(e: SessionErasePreview, owner: string): string[] {
  return [
    `Its key is destroyed, every version of it: no backup of object storage, the database or a volume can recover what ${owner}'s session said.`,
    `Every object version under it goes: ${bytes(e.object_bytes)} of objects and ${bytes(e.workspace_bytes)} of workspace.`,
    e.survivor_count === 0
      ? "No fork of it survives, because it has none."
      : `${count(e.survivor_count, "fork survives", "forks survive")}: ${e.survivors.join(", ")}. A fork has its own key; erase each one on its own if that is what you meant.`,
    "Its owner is not told; what it spent stays in the month's total; the audit keeps the erasure, with your name on it.",
  ];
}
