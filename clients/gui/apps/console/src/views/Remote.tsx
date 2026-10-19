// Laptop sessions offered to you, steered from the console (troupe #58).
//
// Not an administrative view: these are the sessions a laptop's person offered to the
// plane, your own from your laptops and those somebody shared with you, and you steer them
// as yourself. The rest of the console is metadata and never what a session said; this is
// what you would see at the laptop, because its person said you may.
//
// Opening one attaches as the desktop app attaches to a pod: `remote.open` for an endpoint
// and a token, the same socket and the same commands. You follow the transcript live,
// answer its approvals and questions, send a prompt, stop a turn and switch its agent; the
// laptop's rules hold for each, and a laptop that is away says since when.

import { useEffect, useRef, useState } from "react";
import type { JSX } from "react";
import { emptyTranscript, fold, isBusy, openApprovals, openQuestions, openRemote, remoteWhen, SessionAttachment } from "@troupe/client";
import type { AgentRow, AttachStatus, TranscriptState } from "@troupe/client";
import { describeError, useConsole, useLoad } from "../console";
import { href } from "../route";
import { Empty, Loaded } from "./bits";

interface RemoteRow {
  id: string;
  owner: string;
  owner_name?: string | null;
  workspace?: string | null;
  state: string;
  offline_since?: string | null;
  your_role: string;
}

/** The laptop's presence, as a person reads it. */
function presence(row: RemoteRow): string {
  if (row.state === "online") return "online";
  return row.offline_since ? `offline since ${remoteWhen(row.offline_since)}` : "offline";
}

/** Your laptops' sessions, and those shared with you, for the Sessions page. */
export function RemoteSessions(): JSX.Element | null {
  const { auth } = useConsole();
  const [load, reload] = useLoad(
    () =>
      auth
        .rpc<{ sessions: RemoteRow[] }>("remote.list", {})
        .then((r) => r.sessions)
        .catch((e: unknown) => {
          // A plane from before #58 relays nothing.
          if ((e as { code?: unknown }).code === -32601) return [] as RemoteRow[];
          throw e;
        }),
    [auth],
  );

  if (load.state === "ready" && load.data.length === 0) return null;

  return (
    <section className="remote-sessions" aria-label="Offered to you from laptops">
      <h2>Offered to you from laptops</h2>
      <p className="note">Sessions a laptop's person offered for steering from another device. You steer them as yourself, not as an administrator.</p>
      <Loaded load={load} what="the sessions offered to you" retry={reload}>
        {(rows) => (
          <table className="sessions remote">
            <thead>
              <tr>
                <th>Session</th>
                <th>Laptop</th>
                <th>Workspace</th>
                <th>You may</th>
                <th>Where it is</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.id}>
                  <td className="mono">
                    <a href={href({ page: "sessions", path: ["remote", r.id] })}>{r.id}</a>
                  </td>
                  <td>{r.your_role === "owner" ? "yours" : (r.owner_name ?? r.owner)}</td>
                  <td>{r.workspace ?? "—"}</td>
                  <td>{r.your_role === "observe" ? "follow it" : "steer it"}</td>
                  <td>{presence(r)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Loaded>
    </section>
  );
}

/** One laptop's session, followed and steered. */
export function RemoteSession({ id }: { id: string }): JSX.Element {
  const { auth } = useConsole();
  const [state, setState] = useState<TranscriptState>(emptyTranscript);
  const [status, setStatus] = useState<AttachStatus>("connecting");
  const [error, setError] = useState<string | null>(null);
  const [agents, setAgents] = useState<AgentRow[]>([]);
  const [text, setText] = useState("");
  const [answers, setAnswers] = useState<Record<string, string>>({});
  const [refusal, setRefusal] = useState<string | null>(null);
  const attachment = useRef<SessionAttachment | null>(null);

  useEffect(() => {
    let live = true;
    setState(emptyTranscript);
    setError(null);
    const open = () => openRemote((method, params) => auth.rpc(method, params), auth.planeUrl, id);

    SessionAttachment.open({
      sessionId: id,
      mode: "activate",
      open,
      mint: open,
      clientInfo: { name: "troupe-console", version: __TROUPE_VERSION__ },
      hooks: { onEvent: (e) => live && setState((s) => fold(s, e, { now: Date.now() })) },
      onStatus: (s, detail) => {
        if (!live) return;
        setStatus(s);
        if (s === "failed" && detail) setError(detail);
      },
    })
      .then((a) => {
        if (!live) return void a.close();
        attachment.current = a;
        void a.view.setPresence("viewing").catch(() => undefined);
        a.view
          .agents()
          .then((r) => live && setAgents(r.agents.filter((row) => row.mode !== "subagent")))
          .catch(() => undefined);
      })
      .catch((e: unknown) => live && setError(describeError(e)));

    return () => {
      live = false;
      const a = attachment.current;
      attachment.current = null;
      if (a) void a.close();
    };
  }, [auth, id]);

  const act = async (f: (a: SessionAttachment) => Promise<unknown>): Promise<void> => {
    const a = attachment.current;
    if (!a) return;
    setRefusal(null);
    try {
      await f(a);
    } catch (e) {
      setRefusal(describeError(e));
    }
  };

  const busy = isBusy(state);
  const words = state.entries.filter((e) => e.kind === "user" || e.kind === "assistant");

  return (
    <div className="page remote-session">
      <p className="crumbs">
        <a href={href({ page: "sessions" })}>← Sessions</a> · <span className="mono">{id}</span> · on a laptop, through the plane
      </p>
      {error ? (
        <Empty title="Not reachable now">{error}</Empty>
      ) : (
        <>
          <p className="meta" role="status">
            {status === "live" ? (busy ? "working" : "idle") : status}
            {state.profile ? ` · ${state.profile}` : ""}
          </p>

          <ol className="transcript" aria-label="Transcript">
            {words.map((e) =>
              e.kind === "user" ? (
                <li key={e.seq} className="person">
                  <b>{e.author ?? "somebody"}</b>
                  {e.via === "plane" ? <span className="meta"> from another device</span> : null}: {e.text}
                </li>
              ) : e.kind === "assistant" ? (
                <li key={e.seq} className="agent">
                  {e.text}
                </li>
              ) : null,
            )}
          </ol>

          {openApprovals(state).map((a) => (
            <section key={a.callId} className="approval" aria-label={`Approve ${a.tool}`}>
              <p>
                The agent asks to run <span className="mono">{a.tool}</span>.
              </p>
              <button type="button" onClick={() => void act((x) => x.view.respondApproval(a.callId, "allow"))}>
                Allow once
              </button>
              <button type="button" onClick={() => void act((x) => x.view.respondApproval(a.callId, "deny"))}>
                Deny
              </button>
            </section>
          ))}

          {openQuestions(state).map((q) => (
            <form
              key={q.callId}
              className="question"
              aria-label="The agent asks"
              onSubmit={(e) => {
                e.preventDefault();
                void act((x) => x.view.answerQuestion(q.callId, answers[q.callId] ?? ""));
              }}
            >
              <label>
                {q.question}
                <input value={answers[q.callId] ?? ""} onChange={(e) => setAnswers((m) => ({ ...m, [q.callId]: e.target.value }))} />
              </label>
              <button type="submit">Answer</button>
            </form>
          ))}

          <form
            className="composer"
            onSubmit={(e) => {
              e.preventDefault();
              const prompt = text.trim();
              if (!prompt) return;
              void act((x) => x.view.send(prompt)).then(() => setText(""));
            }}
          >
            <label>
              Prompt
              <textarea value={text} onChange={(e) => setText(e.target.value)} />
            </label>
            <button type="submit" disabled={status !== "live"}>
              Send
            </button>
            <button type="button" disabled={!busy} onClick={() => void act((x) => x.view.cancel())}>
              Stop the turn
            </button>
            {agents.length > 0 && (
              <label>
                Agent
                <select value={state.profile ?? ""} onChange={(e) => void act((x) => x.view.switchProfile(e.target.value))}>
                  {!state.profile && <option value="">—</option>}
                  {agents.map((a) => (
                    <option key={a.name} value={a.name}>
                      {a.name}
                    </option>
                  ))}
                </select>
              </label>
            )}
          </form>
          {refusal && (
            <p className="error" role="alert">
              {refusal}
            </p>
          )}
        </>
      )}
    </div>
  );
}
