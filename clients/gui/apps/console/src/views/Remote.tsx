// Laptop sessions offered to you, steered from the console (troupe #58).
//
// Not an administrative view: these are the sessions a laptop's person offered to the
// plane, your own from your laptops and those somebody shared with you, and you steer them
// as yourself, whether you administer anything or not; they are on Mine. The administrative
// areas are metadata and never what a session said; this is what you would see at the
// laptop, because its person said you may.
//
// The list is the plane's word as it changes: a person's watch (`/v1/relay/watch`) tells it
// of an offer made or withdrawn and of a laptop come or gone, so nothing here asks again on
// a timer. While the watch is down it is asked once at each try to reach it again.
//
// Opening one attaches as the desktop app attaches to a pod: `remote.open` for an endpoint
// and a token, the same socket and the same commands. You follow the transcript live,
// answer its approvals and questions, send a prompt, stop a turn and switch its agent; the
// laptop's rules hold for each, and a laptop that is away says since when.

import { useEffect, useRef, useState } from "react";
import type { JSX } from "react";
import { emptyTranscript, fold, isBusy, openApprovals, openQuestions, openRemote, remoteWhen, SessionAttachment, watchRemote } from "@troupe/client";
import type { AgentRow, AttachStatus, TranscriptState } from "@troupe/client";
import { describeError, useConsole } from "../console";
import type { Load } from "../console";
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

/**
 * The laptop sessions offered to this person, as the plane says them now: the watch's list,
 * and `remote.list` asked while the watch is down.
 */
export function useOffered(): [Load<RemoteRow[]>, () => void] {
  const { auth } = useConsole();
  const [load, setLoad] = useState<Load<RemoteRow[]>>({ state: "loading" });
  const [tick, setTick] = useState(0);

  useEffect(() => {
    let live = true;
    const ask = (): void =>
      void auth
        .rpc<{ sessions: RemoteRow[] }>("remote.list", {})
        .then((r) => live && setLoad({ state: "ready", data: r.sessions }))
        .catch((e: unknown) => {
          if (!live) return;
          // A plane from before #58 relays nothing.
          if ((e as { code?: unknown }).code === -32601) setLoad({ state: "ready", data: [] });
          else setLoad((now) => (now.state === "ready" ? now : { state: "error", error: e }));
        });
    const watch = watchRemote({
      planeUrl: auth.planeUrl,
      token: () => auth.token(),
      clientInfo: { name: "troupe-console", version: __TROUPE_VERSION__ },
      onSessions: (rows) => live && setLoad({ state: "ready", data: rows as unknown as RemoteRow[] }),
      onLive: (up) => {
        if (!up && live) ask();
      },
    });
    return () => {
      live = false;
      watch.close();
    };
  }, [auth, tick]);

  return [load, () => setTick((t) => t + 1)];
}

/** Your laptops' sessions, and those shared with you, on Mine. */
export function RemoteSessions(): JSX.Element {
  const [load, reload] = useOffered();

  return (
    <section className="remote-sessions" aria-label="Offered to you from laptops">
      <h2>Offered to you from laptops</h2>
      <p className="note">Sessions a laptop's person offered for steering from another device. You steer them as yourself, not as an administrator.</p>
      <Loaded load={load} what="the sessions offered to you" retry={reload}>
        {(rows) =>
          rows.length === 0 ? (
            <Empty title="Nothing offered to you">
              A session appears here, as it is offered, once you offer one from a laptop with <span className="mono">/steer on</span> or Steer from elsewhere, or somebody
              shares one with you.
            </Empty>
          ) : (
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
                    <a href={href({ page: "mine", path: ["remote", r.id] })}>{r.id}</a>
                  </td>
                  <td>{r.your_role === "owner" ? "yours" : (r.owner_name ?? r.owner)}</td>
                  <td>{r.workspace ?? "—"}</td>
                  <td>{r.your_role === "observe" ? "follow it" : "steer it"}</td>
                  <td>{presence(r)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          )
        }
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
        <a href={href({ page: "mine" })}>← Mine</a> · <span className="mono">{id}</span> · on a laptop, through the plane
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
