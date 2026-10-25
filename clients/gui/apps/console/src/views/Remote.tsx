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
import {
  emptyTranscript,
  fold,
  invitationsFrom,
  isBusy,
  openApprovals,
  openQuestions,
  openRemote,
  personName,
  remoteWhen,
  roleWords,
  SessionAttachment,
  watchRemote,
} from "@troupe/client";
import type { AgentRow, Attachment, AttachStatus, Invitation, Invitee, TranscriptState } from "@troupe/client";
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
  /** A private session, offered with its owner's yes to its passing through the plane unsealed. */
  private?: boolean;
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
export function useOffered(): [Load<RemoteRow[]>, () => void, Load<Invitation[]>] {
  const { auth } = useConsole();
  const [load, setLoad] = useState<Load<RemoteRow[]>>({ state: "loading" });
  // The invitations to the person ride the same watch (troupe #765).
  const [invites, setInvites] = useState<Load<Invitation[]>>({ state: "loading" });
  const [tick, setTick] = useState(0);

  useEffect(() => {
    let live = true;
    const ask = (): void => {
      void auth
        .rpc<{ sessions: RemoteRow[] }>("remote.list", {})
        .then((r) => live && setLoad({ state: "ready", data: r.sessions }))
        .catch((e: unknown) => {
          if (!live) return;
          // A plane from before #58 relays nothing.
          if ((e as { code?: unknown }).code === -32601) setLoad({ state: "ready", data: [] });
          else setLoad((now) => (now.state === "ready" ? now : { state: "error", error: e }));
        });
      void auth
        .rpc<{ invites: unknown }>("invites.list", {})
        .then((r) => live && setInvites({ state: "ready", data: invitationsFrom(r.invites) }))
        .catch((e: unknown) => {
          if (!live) return;
          // Nor does a plane from before #765 invite anybody.
          if ((e as { code?: unknown }).code === -32601) setInvites({ state: "ready", data: [] });
          else setInvites((now) => (now.state === "ready" ? now : { state: "error", error: e }));
        });
    };
    const watch = watchRemote({
      planeUrl: auth.planeUrl,
      token: () => auth.token(),
      clientInfo: { name: "troupe-console", version: __TROUPE_VERSION__ },
      onSessions: (rows) => live && setLoad({ state: "ready", data: rows as unknown as RemoteRow[] }),
      onInvites: (rows) => live && setInvites({ state: "ready", data: rows }),
      onLive: (up) => {
        if (!up && live) ask();
      },
    });
    return () => {
      live = false;
      watch.close();
    };
  }, [auth, tick]);

  return [load, () => setTick((t) => t + 1), invites];
}

/** Your laptops' sessions, and those shared with you, on Mine. */
export function RemoteSessions({ load, reload }: { load: Load<RemoteRow[]>; reload: () => void }): JSX.Element {

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
                  <td>
                    {r.workspace ?? "—"}
                    {r.private ? " · private, unsealed while offered" : ""}
                  </td>
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

/**
 * One laptop's session, followed and steered; or, with `pod`, a pod session somebody
 * invited this person into (troupe #765), attached as the desktop app attaches to one: an
 * endpoint and a token from `session.open`, read to follow it and activated to steer it.
 */
export function RemoteSession({ id, pod }: { id: string; pod?: { mode: "read" | "activate"; whose: string } }): JSX.Element {
  const { auth } = useConsole();
  const [state, setState] = useState<TranscriptState>(emptyTranscript);
  const [status, setStatus] = useState<AttachStatus>("connecting");
  const [error, setError] = useState<string | null>(null);
  const [agents, setAgents] = useState<AgentRow[]>([]);
  const [text, setText] = useState("");
  const [answers, setAnswers] = useState<Record<string, string>>({});
  const [refusal, setRefusal] = useState<string | null>(null);
  // Whom a pod session is shared with by name, named to everybody in it (troupe #765).
  const [shared, setShared] = useState<Invitee[]>([]);
  const attachment = useRef<SessionAttachment | null>(null);

  useEffect(() => {
    if (!pod) return;
    let live = true;
    auth
      .rpc<{ invites: Invitee[] }>("session.invites", { session_id: id })
      .then((r) => live && setShared(r.invites))
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [auth, id, Boolean(pod)]);

  useEffect(() => {
    let live = true;
    setState(emptyTranscript);
    setError(null);
    const open = pod
      ? () => auth.rpc<Attachment>("session.open", { session_id: id, mode: pod.mode })
      : () => openRemote((method, params) => auth.rpc(method, params), auth.planeUrl, id);
    const mint = pod ? () => auth.rpc<Attachment>("token.mint", { session_id: id }) : open;

    SessionAttachment.open({
      sessionId: id,
      mode: pod?.mode ?? "activate",
      open,
      mint,
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
  }, [auth, id, pod?.mode]);

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
        <a href={href({ page: "mine" })}>← Mine</a> · <span className="mono">{id}</span> ·{" "}
        {pod ? `on the platform, shared with you by ${pod.whose}` : "on a laptop, through the plane"}
      </p>
      {shared.length > 0 && (
        <p className="meta shared">Shared with {shared.map((i) => `${personName(i)} (${roleWords(i.role)})`).join(", ")}</p>
      )}
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
