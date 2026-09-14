// Everything waiting on this person, across every session, answerable without opening
// any of them.
//
// The list costs one `sessions.list`: the platform's index carries how many approvals
// each session has open, so finding out what is waiting never replays a log. Answering
// does need the session itself — an approval is a command on the machine running the
// work, and there is no side door — so a row opens that session while it is on screen
// and lets go again.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { awaitingApproval, emptyTranscript, fold, openApprovals, SessionAttachment } from "@troupe/client";
import type { AuthSession, FleetRow, TranscriptState } from "@troupe/client";
import { ApprovalPanel } from "./Approval";
import { Loading, When, Where } from "./bits";

export function Approvals({
  auth,
  rows,
  onOpen,
  onAnswered,
}: {
  auth: AuthSession;
  rows: FleetRow[];
  onOpen: (id: string) => void;
  onAnswered: () => void;
}): JSX.Element {
  const waiting = awaitingApproval(rows);

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
          <p>When a session needs a decision — running a command, changing a file — it appears here and in the session itself.</p>
        </div>
      ) : (
        <ul className="inbox">
          {waiting.map((row) => (
            <Waiting key={row.id} auth={auth} row={row} onOpen={onOpen} onAnswered={onAnswered} />
          ))}
        </ul>
      )}
    </>
  );
}

function Waiting({
  auth,
  row,
  onOpen,
  onAnswered,
}: {
  auth: AuthSession;
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
      <InlineApprovals auth={auth} row={row} onAnswered={onAnswered} />
    </li>
  );
}

/**
 * One session's open approvals, answerable where they are.
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
  row,
  onAnswered,
}: {
  auth: AuthSession;
  row: FleetRow;
  onAnswered: () => void;
}): JSX.Element {
  const [state, setState] = useState<TranscriptState>(emptyTranscript);
  const [attachment, setAttachment] = useState<SessionAttachment | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    let opened: SessionAttachment | null = null;
    SessionAttachment.open({
      sessionId: row.id,
      mode: "read",
      open: (mode) => auth.rpc("session.open", { session_id: row.id, mode }),
      mint: () => auth.rpc("token.mint", { session_id: row.id }),
      hooks: { onEvent: (e) => live && setState((s) => fold(s, e)) },
    })
      .then((a) => {
        opened = a;
        if (!live) return void a.close();
        setAttachment(a);
      })
      .catch((e: unknown) => live && setError(e instanceof Error ? e.message : String(e)));

    return () => {
      live = false;
      void opened?.close();
    };
  }, [auth, row.id]);

  const open = openApprovals(state);
  const answered = state.entries.find((e) => e.kind === "approval" && e.decision !== undefined);

  return (
    <>
      {error && (
        <div className="banner error">
          <p>{error}</p>
        </div>
      )}
      {!attachment && !error && (
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
            await attachment?.view.respondApproval(entry.callId, d);
            onAnswered();
          }}
        />
      ))}

      {attachment && open.length === 0 && answered && (
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
