// Runs and review: every run a trigger started with nobody watching, newest first, across
// the teams this person administers, as `admin.runs.list` answers them. A run is listed by
// its trigger, the repository it worked in and the issue that started it, where GitHub did,
// how it stands, the draft pull request it opened with its CI rounds, and what it spent.
//
// A run's page reads its whole record: when and how it fired, which revision of its trigger
// it ran, and what its session did on GitHub (`sessions.github`), with a link to the
// session. Metadata only: no administrative method returns what a session said. A run a
// person is expected to read is marked read from its page, which is what Review is for: a
// run that ended badly and nobody has read is the state this screen exists to empty.

import { useState } from "react";
import type { JSX } from "react";
import type { SessionGitHub, TriggerRun } from "@troupe/client";
import { show, useConsole, useLoad } from "../console";
import { href } from "../route";
import { AuditNote, Empty, Field, Fields, Loaded, Preview, Region, Status, count, money, useChange, when } from "./bits";
import type { StatusKind } from "./bits";

const STATE: Record<string, { kind: StatusKind; glyph: string; word: string }> = {
  created: { kind: "waiting", glyph: "◌", word: "starting" },
  running: { kind: "running", glyph: "●", word: "running" },
  waiting: { kind: "waiting", glyph: "◐", word: "waiting on a person" },
  done: { kind: "muted", glyph: "✓", word: "done" },
  failed: { kind: "denied", glyph: "✕", word: "failed" },
  skipped: { kind: "muted", glyph: "–", word: "skipped" },
};

/** What the plane answers at most per team. */
const LIMIT = 200;

function RunState({ run }: { run: TriggerRun }): JSX.Element {
  const st = STATE[run.state] ?? { kind: "muted" as const, glyph: "○", word: run.state };
  return (
    <Status kind={st.kind} glyph={st.glyph}>
      {st.word}
    </Status>
  );
}

/** Whether a person still has to read it: it ended and nobody has. */
function unread(run: TriggerRun): boolean {
  return !run.reviewed_at && (run.state === "done" || run.state === "failed" || run.state === "waiting");
}

// -- the list ----------------------------------------------------------------------------

export function Runs(): JSX.Element {
  const { admin, teams, role } = useConsole();
  const [team, setTeam] = useState("");
  const [shown, setShown] = useState("");
  const [query, setQuery] = useState("");
  const [load, reload] = useLoad(() => admin.runs({ limit: LIMIT, ...(team ? { team } : {}) }), [admin, team]);
  const [known] = useLoad(() => admin.teams().catch(() => []), [admin]);
  const choices = known.state === "ready" ? known.data.map((t) => t.name) : role === "platform_admin" ? [] : teams;
  const q = query.trim().toLowerCase();

  return (
    <div className="page">
      <p className="lead">
        Every run a trigger started with nobody watching, newest first: what fired it, the repository and issue it worked on, how it stands, the draft
        pull request it opened and what it spent. A run that ended is read by somebody; the ones nobody has read are marked.
      </p>
      <div className="toolbar">
        <input aria-label="Search runs" placeholder="search a trigger, a repository, an issue…" value={query} onChange={(e) => setQuery(e.target.value)} />
        {choices.length > 1 && (
          <Field label="Team">
            {(p) => (
              <select {...p} value={team} onChange={(e) => setTeam(e.target.value)}>
                <option value="">every team</option>
                {choices.map((t) => (
                  <option key={t} value={t}>
                    {t}
                  </option>
                ))}
              </select>
            )}
          </Field>
        )}
        <Field label="Showing">
          {(p) => (
            <select {...p} value={shown} onChange={(e) => setShown(e.target.value)}>
              <option value="">every run</option>
              <option value="unread">not read yet</option>
              <option value="failed">failed</option>
              <option value="live">running or waiting</option>
              <option value="github">on GitHub</option>
            </select>
          )}
        </Field>
      </div>
      <Loaded load={load} what="the runs" retry={reload}>
        {(runs) => {
          const rows = runs
            .filter((r) => matches(r, shown))
            .filter((r) => !q || [r.trigger, r.team ?? "", r.repository ?? "", r.issue ? `#${r.issue.number} ${r.issue.title ?? ""}` : "", r.session_id ?? ""].some((v) => v.toLowerCase().includes(q)));
          if (runs.length === 0) {
            return <Empty title="No runs yet">A run appears here once a trigger of a team you administer fires: on its schedule, from a webhook or GitHub, or by hand.</Empty>;
          }
          if (rows.length === 0) return <Empty title="No run matches">Widen the filters above.</Empty>;
          return (
            <div className="scroll">
              <table className="runs">
                <thead>
                  <tr>
                    <th>Fired</th>
                    <th>Trigger</th>
                    <th>Repository</th>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Pull request</th>
                    <th className="num">Spent</th>
                    <th>Read</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r) => (
                    <tr key={r.id}>
                      <td>
                        <a href={href({ page: "runs", path: [r.id] })}>{when(r.fired_at)}</a>
                      </td>
                      <td>
                        {r.team ? <a href={href({ page: "triggers", path: [r.team, r.trigger] })}>{r.trigger}</a> : r.trigger}
                        {r.team && <span className="muted"> · {r.team}</span>}
                      </td>
                      <td className="mono">{r.repository ?? <span className="muted">—</span>}</td>
                      <td>
                        <Issue run={r} />
                      </td>
                      <td>
                        <RunState run={r} />
                      </td>
                      <td>
                        <PullRequest github={r.github ?? null} />
                      </td>
                      <td className="num">{money(r.cost_micros)}</td>
                      <td>{r.reviewed_by ? `by ${r.reviewed_by}` : unread(r) ? <strong>not yet</strong> : <span className="muted">—</span>}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          );
        }}
      </Loaded>
    </div>
  );
}

function matches(run: TriggerRun, shown: string): boolean {
  if (shown === "unread") return unread(run);
  if (shown === "failed") return run.state === "failed";
  if (shown === "live") return run.state === "running" || run.state === "waiting" || run.state === "created";
  if (shown === "github") return Boolean(run.repository);
  return true;
}

function Issue({ run }: { run: TriggerRun }): JSX.Element {
  if (!run.issue) return <span className="muted">—</span>;
  return run.issue.url ? (
    <a href={run.issue.url} target="_blank" rel="noreferrer">
      #{run.issue.number}
    </a>
  ) : (
    <span>#{run.issue.number}</span>
  );
}

/** The draft pull request as a link, with its CI rounds; the branch before there is one. */
function PullRequest({ github }: { github: SessionGitHub | null }): JSX.Element {
  if (!github?.branch) return <span className="muted">—</span>;
  const pr = github.pull_request;
  const rounds = github.rounds ?? [];
  const red = rounds.filter((r) => r.state === "red").length;
  return (
    <span>
      {pr ? (
        <a href={pr.url} target="_blank" rel="noreferrer">
          #{pr.number}
        </a>
      ) : (
        <span className="mono">{github.branch}</span>
      )}
      {rounds.length > 0 && (
        <span className="muted">
          {" "}
          · {count(rounds.length, "CI round")}
          {red > 0 ? `, ${red} red` : ""}
        </span>
      )}
      {github.stopped && <span className="muted"> · stopped</span>}
    </span>
  );
}

// -- a run -------------------------------------------------------------------------------

export function RunPage({ id }: { id: string }): JSX.Element {
  const { admin } = useConsole();
  const [load, reload] = useLoad(() => admin.runs({ limit: LIMIT }), [admin]);
  const [marking, setMarking] = useState(false);
  const { done, apply } = useChange(reload);

  return (
    <div className="page">
      <p className="team-meta">
        <a href={href({ page: "runs" })}>Runs and review</a>
      </p>
      <Loaded load={load} what={`run ${id}`} retry={reload}>
        {(runs) => {
          const r = runs.find((x) => x.id === id);
          if (!r) {
            return (
              <Empty title="No such run">
                Or not one of a team you administer. <a href={href({ page: "runs" })}>Runs and review</a>
              </Empty>
            );
          }
          const gh = r.github ?? null;
          return (
            <>
              {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
              <Fields
                rows={[
                  ["State", <RunState run={r} />],
                  ["Trigger", r.team ? <a href={href({ page: "triggers", path: [r.team, r.trigger] })}>{`${r.team}/${r.trigger}`}</a> : r.trigger],
                  ["Fired", `${when(r.fired_at)}${r.source ? `, by ${r.source}` : ""}${r.fired_by ? ` (${r.fired_by})` : ""}`],
                  ["Revision", r.revision ? `${r.revision}${r.revision_hash ? ` · ${r.revision_hash}` : ""}` : "—"],
                  ["Why it ended", show(r.failed_reason ?? r.done_reason)],
                  ["Waiting on", r.pending_approvals || r.pending_questions ? `${count(r.pending_approvals ?? 0, "approval")}, ${count(r.pending_questions ?? 0, "question")}` : "nothing"],
                  ["Repository", <span className="mono">{show(r.repository)}</span>],
                  ["Issue", r.issue ? <span><Issue run={r} /> {r.issue.title ?? ""}</span> : "—"],
                  ["Session", r.session_id ? <a href={href({ page: "sessions", path: [r.session_id] })}>{r.session_id}</a> : "none: it did not start one"],
                  ["Spent", money(r.cost_micros)],
                  ["Read", r.reviewed_by ? `by ${r.reviewed_by}, ${when(r.reviewed_at)}` : unread(r) ? "not yet" : "—"],
                ]}
              />

              {r.session_id && !r.reviewed_at && !marking && (
                <div className="actions">
                  <button type="button" onClick={() => setMarking(true)}>
                    Mark it read
                  </button>
                </div>
              )}
              {marking && r.session_id && (
                <Preview
                  title={`run/${r.trigger}/${r.id}`}
                  lines={[{ field: "reviewed_by", from: null, to: "you" }]}
                  effects={["The run stops counting as unread, on this screen and on Overview, for everybody who administers its team."]}
                  verb="Mark it read"
                  onCancel={() => setMarking(false)}
                  onConfirm={async () => {
                    await apply("run.review", r.session_id!, () => admin.reviewRun(r.session_id!), "The run is marked read.");
                    setMarking(false);
                  }}
                />
              )}

              <Region>On GitHub</Region>
              {gh?.branch ? <Record github={gh} /> : <p className="note">Its session has done nothing on GitHub{r.repository ? " yet" : ": the run names no repository"}.</p>}
            </>
          );
        }}
      </Loaded>
    </div>
  );
}

/** What the session did on GitHub, as its pod reported it and the plane keeps it. */
function Record({ github }: { github: SessionGitHub }): JSX.Element {
  const rounds = github.rounds ?? [];
  return (
    <>
      <Fields
        rows={[
          [
            "Pull request",
            github.pull_request ? (
              <a href={github.pull_request.url} target="_blank" rel="noreferrer">
                #{github.pull_request.number}
              </a>
            ) : (
              "not opened yet"
            ),
          ],
          ["Branch", <span className="mono">{show(github.branch)}</span>],
          ["Last commit", <span className="mono">{show(github.commit)}</span>],
          ["Started from", <span className="mono">{show(github.base)}</span>],
          ["Pushes", show(github.pushes ?? 0)],
          ["Last pushed", when(github.pushed_at)],
          ["Stopped", github.stopped ? `${when(github.stopped.at)}: ${github.stopped.reason}; the draft is left for a person` : "no"],
        ]}
      />
      {rounds.length === 0 ? (
        <p className="note">No CI round has finished on its pull request.</p>
      ) : (
        <div className="scroll">
          <table className="rounds">
            <thead>
              <tr>
                <th>Round</th>
                <th>Commit</th>
                <th>CI</th>
                <th>Failing</th>
                <th>When</th>
              </tr>
            </thead>
            <tbody>
              {rounds.map((round, i) => (
                <tr key={round.commit}>
                  <td className="num">{i + 1}</td>
                  <td className="mono">{round.commit.slice(0, 12)}</td>
                  <td>
                    {round.state === "green" ? (
                      <Status kind="running" glyph="●">
                        green
                      </Status>
                    ) : (
                      <Status kind="denied" glyph="✕">
                        red
                      </Status>
                    )}
                  </td>
                  <td>{round.failing.length ? round.failing.join(", ") : <span className="muted">—</span>}</td>
                  <td>{when(round.at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
