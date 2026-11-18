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
//
// What the session's own `initialize` says of your scopes decides what is drawn: somebody
// offered it to follow is shown no prompt box, no agent and no answers, and a sentence
// says so, rather than a control that is refused once pressed. A refusal of anything sent
// says why in words and keeps what was typed. An approval shows what the desktop app's
// shows, the command, its folder, the file or the diff and what allowing it does, in the
// client's words for both apps, and once answered it stays as a line saying who answered.
// Its answers are the desktop app's for the same session: allowed once, for the rest of
// the session or denied, and always only where the session's server names it, which a pod
// does not and a laptop's never does from here. A laptop whose daemon is from before it
// took an answer for the session from another device (troupe #932) is answered once, and
// a line says so.
//
// While the laptop is away the plane says so on the session's stream, and the status line
// reads it: asleep or offline, or Troupe stopped there, and then that it is back. The
// attachment's own words stay for this page's own connection.

import { useEffect, useRef, useState } from "react";
import type { JSX } from "react";
import {
  ALLOW_ALWAYS,
  ONCE_ONLY_SENTENCE,
  RELAYED_ALLOW_SESSION,
  callConsequence,
  callEvidence,
  callHeadline,
  callScopedLabel,
  decisionWords,
  emptyTranscript,
  fold,
  invitationsFrom,
  isBusy,
  needsYou,
  openApprovals,
  openQuestions,
  personName,
  planeOpener,
  remoteRefusal,
  remoteWhen,
  roleWords,
  ruleScope,
  SessionAttachment,
  sessionStateWords,
  toolGlyph,
  toolOutcome,
  toolTarget,
  TroupeRpcError,
  watchRemote,
} from "@troupe/client";
import type { AgentRow, AttachStatus, Entry, Invitation, Invitee, TranscriptState } from "@troupe/client";
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
  /** Why the laptop is away, while it is: `stopped` (Troupe stopped there) or `offline` (troupe #932). */
  paused?: string | null;
  your_role: string;
  /** A private session, offered with its owner's yes to its passing through the plane unsealed. */
  private?: boolean;
}

/** The laptop's presence, as a person reads it. */
function presence(row: RemoteRow): string {
  if (row.state === "online") return "online";
  const away = row.paused === "stopped" ? "Troupe stopped there" : "offline";
  return row.offline_since ? `${away} since ${remoteWhen(row.offline_since)}` : away;
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
        .withToken((plane, token) => plane.remoteSessions(token))
        .then((r) => live && setLoad({ state: "ready", data: r.sessions as unknown as RemoteRow[] }))
        .catch((e: unknown) => {
          if (!live) return;
          // A plane from before #58 relays nothing.
          if ((e as { code?: unknown }).code === -32601) setLoad({ state: "ready", data: [] });
          else setLoad((now) => (now.state === "ready" ? now : { state: "error", error: e }));
        });
      void auth
        .withToken((plane, token) => plane.listInvites(token))
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
          <div className="scroll">
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
          </div>
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
/**
 * Whom a publication may be for, from this person's own `me`: only them, the organisation,
 * each team (the team's own, or theirs alone) and each profile; the agent's proposal first,
 * and offered even where the plane has not named it for them.
 */
function audienceOptions(me: { teams: Array<{ name: string }>; profiles: string[] }, proposed: { visibility: string | null; owner: "me" | "team" | null; id: string | null }): Array<{ key: string; label: string }> {
  // A new version keeps whose the artifact is, so only whom it is for is offered.
  const own = proposed.id === null ? "|me" : "";
  const options = [
    { key: `private${own}`, label: "Only you" },
    { key: `organisation${own}`, label: "The whole organisation" },
    ...me.teams.flatMap((t) =>
      proposed.id === null
        ? [
            { key: `team:${t.name}|team`, label: `Team ${t.name}, owned by the team` },
            { key: `team:${t.name}|me`, label: `Team ${t.name}, owned by you` },
          ]
        : [{ key: `team:${t.name}`, label: `Team ${t.name}` }],
    ),
    ...me.profiles.map((p) => ({ key: `profile:${p}${own}`, label: `The ${p} profile's people` })),
  ];
  const key = proposedKey(proposed);
  if (key && !options.some((o) => o.key === key)) options.push({ key, label: proposed.id === null ? `${proposed.visibility}, ${key.endsWith("|team") ? "owned by the team" : "owned by you"}` : String(proposed.visibility) });
  return options;
}

/** The proposal's key: its visibility, and for a new artifact whose it is (`visibility|owner`). */
function proposedKey(proposed: { visibility: string | null; owner: "me" | "team" | null; id: string | null }): string | null {
  if (proposed.visibility === null) return null;
  if (proposed.id !== null) return proposed.visibility;
  return `${proposed.visibility}|${proposed.owner ?? (proposed.visibility.startsWith("team:") ? "team" : "me")}`;
}

/** Where the session is, for the line under the page's head. */
function whereWords(pod: { whose: string } | undefined, row: RemoteRow | null): string {
  if (pod) return `on the platform, shared with you by ${pod.whose}`;
  if (!row) return "on a laptop, through the plane";
  return row.your_role === "owner" ? "on your laptop, through the plane" : `on ${row.owner_name ?? row.owner}'s laptop, through the plane`;
}

/**
 * The session's state in words, for its status line: connecting, live and what the agent
 * is doing, waiting on a person while an approval or a question is open, or the laptop
 * (a pod, for a session on the platform) lost, with the reason the connection gave. A
 * laptop the plane says is away is waited for, in the plane's words, and said to be back.
 */
export function statusWords(status: AttachStatus, detail: string | null, state: TranscriptState, opts: { steer: boolean; laptop: boolean }): string {
  const lost = opts.laptop ? "Lost the laptop" : "Lost the connection";
  const away = opts.laptop ? state.laptop : undefined;
  if (away?.state === "away" && status === "live") {
    return away.reason === "stopped" ? "Troupe stopped on the laptop; waiting for it to start again" : "The laptop is asleep or offline; waiting for it";
  }
  if (away?.state === "back" && (status === "reconnecting" || status === "connecting")) return "The laptop is back";
  if (away?.state === "back" && status === "live") {
    const { laptop: _back, ...rest } = state;
    return `The laptop is back · ${statusWords(status, detail, rest, opts)}`;
  }
  switch (status) {
    case "connecting":
      return "Connecting";
    case "reconnecting":
      return `${lost}${detail ? `: ${detail}` : ""}. Trying again`;
    case "failed":
      return `${lost}${detail ? `: ${detail}` : ""}`;
    case "closed":
      return "Closed";
    default:
      if (needsYou(state)) return opts.steer ? sessionStateWords("waiting") : "Waiting for an answer";
      return sessionStateWords(isBusy(state) ? "working" : "idle");
  }
}

/** A method, its error's name and its code, which is what a refusal's message says when it says nothing else. */
const RAW_REFUSAL = /^[\w.]+: [\w_]+ \(-?\d+\)$/;

/**
 * Why the session refused what was sent from here, in the reader's words: never the
 * method and its code. A follower who tries to steer is told who can let them.
 */
export function refusalWords(e: unknown): string {
  if (e instanceof TroupeRpcError) {
    const data = (e.data ?? {}) as Record<string, unknown>;
    if (data["required_scope"] === "control") return "You follow this session and cannot steer it: its owner can let you.";
    if (typeof data["reason"] === "string" && data["reason"] !== "") return String(data["reason"]);
    if (e.code === -32010 || e.code === -32005) return remoteRefusal(e);
    if (e.code === -32004) return "The session refused that.";
  }
  const said = describeError(e);
  return RAW_REFUSAL.test(said) ? "The session refused that, and said no more." : said;
}

type ApprovalEntry = Extract<Entry, { kind: "approval" }>;
type QuestionEntry = Extract<Entry, { kind: "question" }>;

/** An answered approval as its line in the transcript: who answered it, and what it was. */
function decisionLine(a: ApprovalEntry, nameOf: (subject: string | undefined) => string): string {
  const verb = decisionWords(a.decision);
  const what = callHeadline(a.tool).replace(/\?$/, "").toLowerCase();
  const target = toolTarget(a.tool, a.args);
  return `${verb} by ${nameOf(a.resolvedBy ?? a.decidedBy)}: ${what}${target ? ` · ${target}` : ""}${a.decision === "deny" ? ". Nothing was changed." : ""}`;
}

/** What a call's arguments show before it is answered: the command and its folder, the file, a diff. */
function Evidence({ entry, folder }: { entry: ApprovalEntry; folder: string | null }): JSX.Element {
  const { command, cwd, path, diff } = callEvidence(entry.args);
  const where = cwd ?? entry.cwd ?? folder;
  return (
    <div className="evidence">
      {command ? <pre className="command">{command}</pre> : path ? <pre className="command">{path}</pre> : null}
      {diff && <pre className="diff">{diff}</pre>}
      {!command && !path && !diff && <pre>{JSON.stringify(entry.args ?? {}, null, 2)}</pre>}
      {where && <p className="also">In {where}.</p>}
    </div>
  );
}

/**
 * A question for a person, as the desktop app draws it: the agent's options to pick from
 * (one answers it, or several ticked and sent together), then words of one's own.
 */
function QuestionForm({ entry, steer, onAnswer }: { entry: QuestionEntry; steer: boolean; onAnswer: (text: string) => Promise<boolean> }): JSX.Element {
  const [text, setText] = useState("");
  const [ticked, setTicked] = useState<string[]>([]);
  const tick = (label: string): void => setTicked((t) => (t.includes(label) ? t.filter((x) => x !== label) : [...t, label]));
  return (
    <section className="approval question" aria-label="The agent asks">
      <h3>{entry.asked === "budget" ? "A limit is reached. How much more, and for how long?" : "The session has a question"}</h3>
      <p className="consequence">{entry.question}</p>
      {entry.preview !== undefined && <pre className="evidence">{entry.preview}</pre>}
      {!steer ? (
        <p className="also">You follow this session: somebody who steers it answers this.</p>
      ) : (
        <>
          {entry.options.length > 0 && (
            <div className="answers">
              {entry.options.map((o) =>
                entry.multiple ? (
                  <button key={o.label} type="button" aria-pressed={ticked.includes(o.label)} onClick={() => tick(o.label)} title={o.description ?? undefined}>
                    {o.label}
                  </button>
                ) : (
                  <button key={o.label} type="button" onClick={() => void onAnswer(o.label)} title={o.description ?? undefined}>
                    {o.label}
                  </button>
                ),
              )}
              {entry.multiple && ticked.length > 0 && (
                <button type="button" className="primary" onClick={() => void onAnswer(ticked.join(", "))}>
                  Answer with {ticked.length} chosen
                </button>
              )}
            </div>
          )}
          <form
            className="answers"
            onSubmit={(e) => {
              e.preventDefault();
              if (text.trim()) void onAnswer(text.trim());
            }}
          >
            <input value={text} onChange={(e) => setText(e.target.value)} placeholder={entry.options.length > 0 ? "Or answer in your own words" : "Your answer"} aria-label="Your answer" />
            <button type="submit" disabled={!text.trim()}>
              Answer
            </button>
          </form>
        </>
      )}
    </section>
  );
}

export function RemoteSession({ id, pod }: { id: string; pod?: { mode: "read" | "activate"; whose: string } }): JSX.Element {
  const { auth, me } = useConsole();
  const [state, setState] = useState<TranscriptState>(emptyTranscript);
  const [status, setStatus] = useState<AttachStatus>("connecting");
  const [detail, setDetail] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [agents, setAgents] = useState<AgentRow[]>([]);
  // Whether this person may steer, as the session's own `initialize` said their scopes:
  // unknown until it is attached, and then a follower is shown nothing that steers.
  const [steer, setSteer] = useState<boolean | null>(null);
  // The laptop's offer as the plane lists it: whose laptop and which folder.
  const [row, setRow] = useState<RemoteRow | null>(null);
  const [text, setText] = useState("");
  // Whom each publication is for, as chosen here, by its call id (`visibility|owner`).
  const [audiences, setAudiences] = useState<Record<string, string>>({});
  const [refusal, setRefusal] = useState<string | null>(null);
  // Whom a pod session is shared with by name, named to everybody in it (troupe #765).
  const [shared, setShared] = useState<Invitee[]>([]);
  // Whether the laptop takes an answer for the rest of the session from here, as its
  // daemon said at `initialize`; one from before answers a call once.
  const [sessionWide, setSessionWide] = useState(false);
  // Whether the session's server takes a lasting rule from an approval, as it said at
  // `initialize`: a pod names none, its rules being its worker profile's.
  const [alwaysAllow, setAlwaysAllow] = useState(false);
  const attachment = useRef<SessionAttachment | null>(null);

  useEffect(() => {
    if (!pod) return;
    let live = true;
    auth
      .withToken((plane, token) => plane.sessionInvites(token, id))
      .then((r) => live && setShared(r.invites))
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [auth, id, Boolean(pod)]);

  useEffect(() => {
    if (pod) return;
    let live = true;
    auth
      .withToken((plane, token) => plane.remoteSessions(token))
      .then((r) => live && setRow((r.sessions as unknown as RemoteRow[]).find((s) => s.id === id) ?? null))
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [auth, id, Boolean(pod)]);

  useEffect(() => {
    let live = true;
    setState(emptyTranscript);
    setError(null);
    setSteer(null);
    SessionAttachment.open({
      sessionId: id,
      mode: pod?.mode ?? "activate",
      ...planeOpener(auth, id, !pod),
      clientInfo: { name: "troupe-console", version: __TROUPE_VERSION__ },
      hooks: { onEvent: (e) => live && setState((s) => fold(s, e, { now: Date.now() })) },
      onStatus: (s, said) => {
        if (!live) return;
        setStatus(s);
        setDetail(said ?? null);
        if (s === "failed" && said) setError(said);
      },
    })
      .then((a) => {
        if (!live) return void a.close();
        attachment.current = a;
        // A follow-only grant holds `observe` alone; a pod session opened to read is followed too.
        setSteer(pod?.mode !== "read" && (a.conn?.scopes.has("control") ?? false));
        setSessionWide(!pod && a.view.capabilities[RELAYED_ALLOW_SESSION] === true);
        setAlwaysAllow(Boolean(pod) && Boolean(a.view.capabilities[ALLOW_ALWAYS]));
        void a.view.followPresence().catch(() => undefined);
        void a.view.setPresence("viewing").catch(() => undefined);
        a.view
          .agents()
          .then((r) => live && setAgents(r.agents.filter((agent) => agent.mode !== "subagent")))
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

  /** Send something to the session: true once it took it, and on a refusal the reason said and nothing cleared. */
  const act = async (f: (a: SessionAttachment) => Promise<unknown>): Promise<boolean> => {
    const a = attachment.current;
    if (!a) return false;
    setRefusal(null);
    try {
      await f(a);
      return true;
    } catch (e) {
      setRefusal(refusalWords(e));
      return false;
    }
  };

  // People by name where anything here knows one: the person signed in, the laptop's
  // person as the plane lists the offer, whoever the session's presence names, and each
  // event's actor, which carries the name where the connection knew it (troupe #931).
  const names = new Map<string, string>();
  for (const p of state.presence) if (p.subject && p.display_name) names.set(p.subject, p.display_name);
  if (row?.owner_name) names.set(row.owner, row.owner_name);
  for (const e of state.entries) {
    if (e.kind === "user" && e.author && e.authorName) names.set(e.author, e.authorName);
    if (e.kind === "approval" && e.decidedBy && e.decidedByName) names.set(e.decidedBy, e.decidedByName);
  }
  const nameOf = (subject: string | undefined): string => (subject === undefined || subject === me.subject ? "you" : (names.get(subject) ?? subject));

  const busy = isBusy(state);
  const laptop = !pod;
  const following = steer === false;
  const shown = state.entries.filter(
    (e) => e.kind === "user" || e.kind === "assistant" || e.kind === "tool" || (e.kind === "approval" && e.decision !== undefined) || (e.kind === "question" && e.answer !== undefined),
  );
  const folder = row?.workspace ?? null;

  return (
    <div className="page remote-session">
      <p className="meta where">
        <span className="mono">{id}</span> · {whereWords(pod, row)}
      </p>
      {shared.length > 0 && (
        <p className="meta shared">Shared with {shared.map((i) => `${personName(i)} (${roleWords(i.role)})`).join(", ")}</p>
      )}
      {error ? (
        <Empty title="Not reachable now">{error}</Empty>
      ) : (
        <>
          <p className={`meta status-line${needsYou(state) && status === "live" ? " waiting" : ""}`} role="status">
            {statusWords(status, detail, state, { steer: steer === true, laptop })}
            {state.profile ? ` · ${state.profile}` : ""}
          </p>
          {following && <p className="note follow">You follow this session; its owner can let you steer it.</p>}

          {status === "live" && shown.length === 0 && state.streaming === "" ? (
            <p className="note empty">Nothing yet: the session has not said anything.</p>
          ) : (
            <ol className="transcript" aria-label="Transcript">
              {shown.map((e) =>
                e.kind === "user" ? (
                  <li key={e.seq} className="person">
                    <b>{nameOf(e.author).replace(/^you$/, "You")}</b>
                    {e.via === "plane" && e.author !== me.subject ? <span className="meta"> from another device</span> : null}: {e.text}
                  </li>
                ) : e.kind === "assistant" ? (
                  <li key={e.seq} className="agent">
                    {e.text}
                  </li>
                ) : e.kind === "tool" ? (
                  <li key={e.seq} className={`tool ${e.ok === undefined ? "running" : e.ok ? "ok" : "failed"}`}>
                    <span aria-hidden="true">{toolGlyph(e.ok)}</span> <span className="mono">{e.name}</span>
                    {toolTarget(e.name, e.args) ? <span className="mono"> {toolTarget(e.name, e.args)}</span> : null}
                    {toolOutcome(e) ? <span className="outcome"> · {toolOutcome(e)}</span> : null}
                  </li>
                ) : e.kind === "approval" ? (
                  <li key={e.seq} className={`decision ${e.decision === "deny" ? "denied" : "allowed"}`}>
                    {decisionLine(e, nameOf)}
                  </li>
                ) : e.kind === "question" ? (
                  <li key={e.seq} className="decision answered">
                    Asked: {e.question} · answered: {e.answer}
                  </li>
                ) : null,
              )}
              {state.streaming !== "" && <li className="agent streaming">{state.streaming}</li>}
            </ol>
          )}

          {openApprovals(state).map((a) => {
            const pub = a.publication;
            return pub ? (
              // An agent's publication: whom it is for is the person's to say, the proposal chosen already.
              <section key={a.callId} className="approval" aria-label={`Publish ${pub.title}`}>
                <h3>{callHeadline(a.tool)}</h3>
                <p>
                  The agent asks to publish <b>{pub.title}</b> ({pub.kind}, {pub.files === 1 ? "1 file" : `${pub.files} files`}).
                  {pub.visibility === null ? " It did not say whom it is for." : ""}
                </p>
                {steer ? (
                  <>
                    <label>
                      Who may open it
                      <select value={audiences[a.callId] ?? proposedKey(pub) ?? ""} onChange={(e) => setAudiences((m) => ({ ...m, [a.callId]: e.target.value }))}>
                        {pub.visibility === null && <option value="">Choose whom it is for</option>}
                        {audienceOptions(me, pub).map((o) => (
                          <option key={o.key} value={o.key}>
                            {o.label}
                          </option>
                        ))}
                      </select>
                    </label>
                    <div className="answers">
                      <button
                        type="button"
                        className="primary"
                        disabled={(audiences[a.callId] ?? proposedKey(pub) ?? "") === ""}
                        onClick={() => {
                          const [visibility, owner] = (audiences[a.callId] ?? proposedKey(pub) ?? "").split("|");
                          void act((x) => x.view.respondApproval(a.callId, "allow", { visibility: visibility ?? "private", ...(owner === undefined ? {} : { owner: owner === "team" ? "team" : "me" }) }));
                        }}
                      >
                        Allow once
                      </button>
                      <button type="button" onClick={() => void act((x) => x.view.respondApproval(a.callId, "deny"))}>
                        Deny
                      </button>
                      {(!laptop || sessionWide) && pub.visibility !== null && (
                        <button
                          type="button"
                          disabled={(audiences[a.callId] ?? proposedKey(pub) ?? "") === ""}
                          onClick={() => {
                            const [visibility, owner] = (audiences[a.callId] ?? proposedKey(pub) ?? "").split("|");
                            void act((x) => x.view.respondApproval(a.callId, "allow_session", { visibility: visibility ?? "private", ...(owner === undefined ? {} : { owner: owner === "team" ? "team" : "me" }) }));
                          }}
                        >
                          Allow, and let it publish unasked for this session
                        </button>
                      )}
                    </div>
                    {laptop && !sessionWide && <p className="also">{ONCE_ONLY_SENTENCE}</p>}
                  </>
                ) : (
                  <p className="also">You follow this session: somebody who steers it answers this.</p>
                )}
              </section>
            ) : (
              <section key={a.callId} className="approval" aria-label={`Approve ${a.tool}`}>
                <h3>{callHeadline(a.tool)}</h3>
                <p className="consequence">{callConsequence(a.tool, laptop ? "laptop" : "platform")}</p>
                {a.rule && (
                  <p className="also">
                    Asked by the rule <code>ask {a.rule.rule}</code>, from {ruleScope(a.rule)}
                    {a.rule.source ? ` (${a.rule.source})` : ""}.
                  </p>
                )}
                <Evidence entry={a} folder={folder} />
                {steer ? (
                  <>
                    <div className="answers">
                      <button type="button" className="primary" onClick={() => void act((x) => x.view.respondApproval(a.callId, "allow"))}>
                        Allow once
                      </button>
                      {/* A pod session is the person's to steer, so it is answered as the
                          desktop answers one; a laptop that takes it, as at the laptop. */}
                      {(!laptop || sessionWide) && (
                        <button type="button" onClick={() => void act((x) => x.view.respondApproval(a.callId, "allow_session"))}>
                          {callScopedLabel(a.tool)}
                        </button>
                      )}
                      {!laptop && alwaysAllow && (
                        <button type="button" title="A rule of yours: every call like this runs unasked from now on" onClick={() => void act((x) => x.view.respondApproval(a.callId, "allow_always"))}>
                          Always allow {a.tool}
                        </button>
                      )}
                      <button type="button" onClick={() => void act((x) => x.view.respondApproval(a.callId, "deny"))}>
                        Deny
                      </button>
                    </div>
                    {laptop && !sessionWide && <p className="also">{ONCE_ONLY_SENTENCE}</p>}
                  </>
                ) : (
                  <p className="also">You follow this session: somebody who steers it answers this.</p>
                )}
              </section>
            );
          })}

          {openQuestions(state).map((q) => (
            <QuestionForm key={q.callId} entry={q} steer={steer === true} onAnswer={(answer) => act((x) => x.view.answerQuestion(q.callId, answer))} />
          ))}

          {steer && (
            <form
              className="composer"
              onSubmit={(e) => {
                e.preventDefault();
                const prompt = text.trim();
                if (!prompt) return;
                // The text stays in the box until the session has taken it.
                void act((x) => x.view.send(prompt)).then((sent) => sent && setText(""));
              }}
            >
              <label>
                Prompt
                <textarea value={text} onChange={(e) => setText(e.target.value)} />
              </label>
              <button type="submit" disabled={status !== "live"}>
                Send
              </button>
              {busy && (
                <button type="button" onClick={() => void act((x) => x.view.cancel())}>
                  Stop the turn
                </button>
              )}
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
          )}
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
