// Everything waiting on this person, across every session, answerable without opening
// any of them.
//
// The list costs one `sessions.list`: the platform's index carries how many approvals
// and questions each session has open, so finding out what is waiting never replays a
// log. Answering does need the session itself — an approval or an answer is a command on
// the machine running the work, and there is no side door — so a row opens that session
// while it is on screen and lets go again.

import type { JSX } from "react";
import { awaitingYou, openApprovals, openQuestions } from "@troupe/client";
import type { AuthSession, DaemonClient, FleetRow } from "@troupe/client";
import { useSessionView } from "../hooks";
import { ApprovalPanel } from "./Approval";
import { QuestionPanel } from "./Question";
import { Loading, When, Where } from "./bits";

export function Approvals({
  auth,
  daemon,
  rows,
  onOpen,
  onAnswered,
}: {
  /** Null in local mode, where everything waiting is on this computer. */
  auth: AuthSession | null;
  daemon: DaemonClient | null;
  rows: FleetRow[];
  onOpen: (id: string) => void;
  onAnswered: () => void;
}): JSX.Element {
  const waiting = awaitingYou(rows);

  return (
    <>
      <header className="toolbar">
        <h2>Waiting for you</h2>
        <span className="spacer" />
        <span className="count">{waiting.length === 0 ? "nothing waiting" : `${waiting.length}`}</span>
      </header>

      {waiting.length === 0 ? (
        <div className="empty">
          <h2>Nothing is waiting for you</h2>
          <p>When a session needs a decision — running a command, changing a file, answering its question — it appears here and in the session itself.</p>
        </div>
      ) : (
        <ul className="inbox">
          {waiting.map((row) => (
            <Waiting key={row.id} auth={auth} daemon={daemon} row={row} onOpen={onOpen} onAnswered={onAnswered} />
          ))}
        </ul>
      )}
    </>
  );
}

function Waiting({
  auth,
  daemon,
  row,
  onOpen,
  onAnswered,
}: {
  auth: AuthSession | null;
  daemon: DaemonClient | null;
  row: FleetRow;
  onOpen: (id: string) => void;
  onAnswered: () => void;
}): JSX.Element {
  return (
    <li>
      <header>
        <button className="link subject" onClick={() => onOpen(row.id)}>
          {row.title ?? row.id}
        </button>
        <Where kind={row.kind} />
        <span className="when">{row.profile}</span>
        <span className="spacer" />
        <When iso={row.lastActiveAt} />
      </header>
      <InlineApprovals auth={auth} daemon={daemon} row={row} onAnswered={onAnswered} />
    </li>
  );
}

/**
 * One session's open approvals and questions, answerable where they are.
 *
 * Opened in `read` mode: looking at what is waiting must not be what wakes a sleeping
 * session — answering is, and that is the person's choice. The attachment lasts as long
 * as the panel is on screen and is closed when it leaves, so an inbox of thirty is not
 * thirty sockets for longer than it is thirty rows.
 *
 * Shared by the inbox and by Review, because "answer it without opening it" is the same
 * promise in both and a second copy is how two screens start disagreeing about it.
 */
export function InlineApprovals({
  auth,
  daemon,
  row,
  onAnswered,
}: {
  auth: AuthSession | null;
  daemon: DaemonClient | null;
  row: FleetRow;
  onAnswered: () => void;
}): JSX.Element {
  // `read` never wakes a sleeping session: looking at what is waiting must not be what
  // starts it. Answering is, and that is the person's choice. Where the session runs
  // decides which socket carries the answer and nothing else.
  const { view, state, error } = useSessionView(auth, row.id, { daemon, kind: row.kind, mode: "read" });

  const open = openApprovals(state);
  const questions = openQuestions(state);
  const answered = state.entries.find((e) => e.kind === "approval" && e.decision !== undefined);

  return (
    <>
      {error && (
        <div className="banner error">
          <p>{error}</p>
        </div>
      )}
      {!view && !error && (
        <div style={{ padding: "var(--space-4)" }}>
          <Loading what="Reading what it is waiting for…" />
        </div>
      )}

      {open.map((entry) => (
        <ApprovalPanel
          key={entry.callId}
          entry={entry}
          canAnswer={row.yourRole !== "viewer"}
          others={[]}
          onAnswer={async (d) => {
            await view?.respondApproval(entry.callId, d);
            onAnswered();
          }}
        />
      ))}

      {/* The agent's questions and the harness's, as the session itself shows them. */}
      {questions.map((entry) => (
        <QuestionPanel
          key={entry.callId}
          entry={entry}
          canAnswer={row.yourRole !== "viewer"}
          onAnswer={async (text) => {
            await view?.answerQuestion(entry.callId, text);
            onAnswered();
          }}
        />
      ))}

      {view && open.length === 0 && questions.length === 0 && answered && (
        <div style={{ padding: "var(--space-4)" }}>
          <p className="note">
            Answered by {(answered as Extract<typeof answered, { kind: "approval" }>).resolvedBy ?? "somebody else"} already. Nothing is
            waiting for you here.
          </p>
        </div>
      )}
    </>
  );
}
