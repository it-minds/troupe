// One session: conversation, approval, composer — and the backstage beside them.
//
// The three primary things are the only ones guaranteed on screen at 380px, because
// they are the only three a person ever *has* to do: read what happened, decide, and
// reply. Tasks, files and who is working live in the backstage track, which stacks
// below the conversation on a narrow screen.
//
// Nothing here is held that a reconnect could not rebuild. A message the person sends
// renders as Queued until the server echoes it back — not inserted optimistically into
// the stream, because the stream's order is the server's and a reconnect must not
// reshuffle what somebody has already read.

import { useEffect, useRef, useState } from "react";
import type { JSX } from "react";
import { isBlobRef, isBusy, openApprovals, rootState } from "@troupe/client";
import type {
  AttachStatus,
  AuthSession,
  BlobRef,
  DaemonClient,
  Entry,
  FleetRow,
  ProfileOffering,
  TranscriptState,
} from "@troupe/client";
import { useProfiles, useSessionView } from "../hooks";
import type { SessionHandle } from "../hooks";
import { ApprovalPanel, DecisionRecord } from "./Approval";
import { Files } from "./Files";
import { LocalControls } from "./LocalControls";
import { Cost, initials, Loading, personColour, Pill, When, Where } from "./bits";

export function Session({
  auth,
  daemon,
  row,
  sessionId,
  onBack,
}: {
  auth: AuthSession;
  daemon: DaemonClient | null;
  row: FleetRow | undefined;
  sessionId: string;
  onBack: () => void;
}): JSX.Element {
  // Where it runs decides which socket it is reached over and nothing else about this
  // screen: the transcript, the approvals and the composer are the same protocol either
  // way, which is the whole point of the client library.
  const view = useSessionView(auth, sessionId, { daemon, kind: row?.kind ?? "team" });
  const { profiles } = useProfiles(auth);
  const [backstage, setBackstage] = useState(true);
  const self = auth.me?.subject;

  const readOnly = row?.state === "read_only" || row?.yourRole === "viewer";
  const dormant = row?.state === "dormant";
  const open = openApprovals(view.state);

  return (
    <section className="session">
      <Header
        row={row}
        sessionId={sessionId}
        state={view.state}
        profiles={profiles}
        self={self}
        backstage={backstage}
        onBack={onBack}
        onToggleBackstage={() => setBackstage((b) => !b)}
        onSwitch={(p) => void view.switchProfile(p)}
      />

      <Banners status={view.status} detail={view.detail} dormant={dormant} readOnly={readOnly} error={view.error} />

      <div className="stagearea">
        <div className="conversation">
          <Stream state={view.state} self={self} readBlob={view.readBlob} />

          {/* Sticky, so scrolling up to read the context never loses the decision. */}
          {open.map((entry) => (
            <ApprovalPanel
              key={entry.callId}
              entry={entry}
              canAnswer={!readOnly}
              others={view.state.presence.filter((p) => p.subject && p.subject !== self).map((p) => p.display_name ?? p.subject)}
              onAnswer={(d) => view.respond(entry.callId, d)}
            />
          ))}

          {readOnly ? (
            <ReadOnly />
          ) : (
            <Composer view={view} dormant={dormant} busy={isBusy(view.state)} live={view.status === "live"} />
          )}
        </div>

        {backstage && <Backstage view={view} daemon={daemon} row={row} self={self} />}
      </div>
    </section>
  );
}

function Header({
  row,
  sessionId,
  state,
  profiles,
  self,
  backstage,
  onBack,
  onToggleBackstage,
  onSwitch,
}: {
  row: FleetRow | undefined;
  sessionId: string;
  state: TranscriptState;
  profiles: ProfileOffering[];
  self: string | undefined;
  backstage: boolean;
  onBack: () => void;
  onToggleBackstage: () => void;
  onSwitch: (p: string) => void;
}): JSX.Element {
  const working = rootState(state);
  const here = state.presence.filter((p) => p.subject);
  const role = row?.yourRole;

  return (
    <header className="session-head">
      <button onClick={onBack} aria-label="Back to all sessions">
        ←
      </button>

      <div className="subject">
        <strong>{row?.title ?? sessionId}</strong>
        <span className="sub">
          {row && <Where kind={row.kind} />}
          <span>{state.profile ?? row?.profile ?? "—"}</span>
          {role && <span>you are {role === "owner" ? "the owner" : role === "collaborator" ? "a collaborator" : "a reader"}</span>}
          {here.length > 0 && <Here members={here} self={self} />}
        </span>
      </div>

      {state.doneReason ? (
        <Pill status={state.doneReason === "budget_exhausted" ? "error" : "allowed"}>Finished</Pill>
      ) : isBusy(state) ? (
        <Pill status="running">{working === "compacting" ? "Tidying up" : "Working"}</Pill>
      ) : (
        <Pill status="queued">Idle</Pill>
      )}

      <select value={state.profile ?? ""} onChange={(e) => onSwitch(e.target.value)} aria-label="Profile" title="Applied at the next turn">
        {profiles.map((p) => (
          <option key={p.name} value={p.name}>
            {p.name}
          </option>
        ))}
      </select>

      <button onClick={onToggleBackstage} aria-pressed={backstage}>
        {backstage ? "Hide backstage" : "Show backstage"}
      </button>
    </header>
  );
}

/** Up to three rings, then a plain sentence. Your own ring is the neutral one. */
function Here({ members, self }: { members: TranscriptState["presence"]; self: string | undefined }): JSX.Element {
  const names = members.map((m) => (m.subject === self ? "you" : (m.display_name ?? m.subject)));
  const sentence = names.length === 1 ? `${names[0]} is here` : `${names.slice(0, -1).join(", ")} and ${names.at(-1)} are here`;
  return <span title={sentence}>{sentence}</span>;
}

function Banners({
  status,
  detail,
  dormant,
  readOnly,
  error,
}: {
  status: AttachStatus;
  detail: string | null;
  dormant: boolean;
  readOnly: boolean;
  error: string | null;
}): JSX.Element | null {
  return (
    <>
      {dormant && (
        <div className="banner dormant">
          <p>This session is asleep. Reading it does not wake it, and sleeping costs nothing.</p>
        </div>
      )}
      {readOnly && (
        <div className="banner readonly">
          <p>You can read this session but not add to it.</p>
        </div>
      )}
      {(status === "reconnecting" || status === "refreshing") && (
        <div className="banner offline">
          <p>
            Connection lost. Trying again. The work carries on, nothing you have sent is lost, and anything you type now is sent when it
            comes back.
          </p>
          {detail && <span className="micro">{detail}</span>}
        </div>
      )}
      {status === "failed" && (
        <div className="banner error">
          <p>Could not reach this session. {detail ?? ""}</p>
        </div>
      )}
      {error && (
        <div className="banner error">
          <p>{error}</p>
        </div>
      )}
    </>
  );
}

function Stream({
  state,
  self,
  readBlob,
}: {
  state: TranscriptState;
  self: string | undefined;
  readBlob: (blob: string) => Promise<string>;
}): JSX.Element {
  const bottom = useRef<HTMLDivElement>(null);
  useEffect(() => {
    // Scrolling is not focus: an arriving event must never move the caret.
    bottom.current?.scrollIntoView({ block: "end" });
  }, [state.entries.length, state.streaming, state.pending.length]);

  return (
    <div className="stream" aria-live="polite">
      {state.entries.length === 0 && <Loading what="Reading the session. The newest part arrives first." />}

      {state.entries.map((e) => (
        <StreamEntry key={`${e.kind}-${e.seq}`} entry={e} self={self} readBlob={readBlob} />
      ))}

      {state.thinking && (
        <details className="thinking">
          <summary>Thinking</summary>
          <pre>{state.thinking}</pre>
        </details>
      )}

      {state.streaming && (
        <article className="turn agent">
          <div className="byline">
            <span className="name">Troupe</span>
            <Pill status="running">Writing now</Pill>
          </div>
          <div className="body caret">{state.streaming}</div>
        </article>
      )}

      {/* Queued, not optimistic: it is not in the stream until the server says it is. */}
      {state.pending.map((p) => (
        <article key={p.commandId} className="turn queued">
          <div className="byline">
            <span className="name">You</span>
            <Pill status="queued">{p.queued ? "Queued" : "Sending"}</Pill>
          </div>
          <div className="body">{p.text}</div>
        </article>
      ))}

      <div ref={bottom} />
    </div>
  );
}

function StreamEntry({
  entry,
  self,
  readBlob,
}: {
  entry: Entry;
  self: string | undefined;
  readBlob: (blob: string) => Promise<string>;
}): JSX.Element | null {
  switch (entry.kind) {
    case "user": {
      const mine = entry.author === self || entry.author === undefined;
      const name = mine ? "You" : (entry.author ?? entry.source);
      return (
        <article className={`turn person ${mine ? "self" : ""}`} style={{ ["--author" as string]: personColour(entry.author, self) }}>
          <div className="byline">
            <span className="mono micro">{initials(name)}</span>
            <span className="name">{name}</span>
            {entry.source !== "user" && <span className="micro muted">via {entry.source}</span>}
          </div>
          <div className="body">{entry.text}</div>
        </article>
      );
    }

    case "assistant":
      return (
        <article className="turn agent">
          <div className="byline">
            <span className="name">Troupe</span>
            {entry.agent.length > 1 && <span className="micro muted">{entry.agent.slice(1).join(" › ")}</span>}
          </div>
          <Markdown text={entry.text} />
        </article>
      );

    case "tool":
      return <ToolActivity entry={entry} readBlob={readBlob} />;

    case "delegation":
      return (
        <p className="note">
          Handed to {entry.child}: {entry.task}
        </p>
      );

    // The task list lives in the backstage; each update in the stream would be noise.
    case "todo":
      return null;

    case "approval":
      return entry.decision ? <DecisionRecord entry={entry} self={self} /> : null;

    case "system":
      return <p className={`note ${entry.type === "llm_error" || entry.type === "budget_exhausted" ? "error" : ""}`}>{entry.text}</p>;
  }
}

/**
 * Tool activity: one mono line — verb, target, duration — collapsed by default,
 * because a session produces hundreds and none of them is the point.
 */
function ToolActivity({ entry, readBlob }: { entry: Extract<Entry, { kind: "tool" }>; readBlob: (b: string) => Promise<string> }): JSX.Element {
  const args = (entry.args ?? {}) as Record<string, unknown>;
  const target = ["path", "file", "command", "query", "url"].map((k) => args[k]).find((v) => typeof v === "string") as string | undefined;
  const running = entry.ok === undefined;

  return (
    <details className={`tool ${running ? "running" : entry.ok ? "ok" : "failed"}`}>
      <summary>
        <span className="verb">{entry.name}</span>
        <span className="target">{target ?? ""}</span>
        <span className="muted">{running ? "running" : entry.ok ? "done" : "failed"}</span>
      </summary>
      <pre className="payload">{JSON.stringify(entry.args, null, 2)}</pre>
      {entry.content !== undefined &&
        (isBlobRef(entry.content) ? (
          <LargeResult reference={entry.content} readBlob={readBlob} />
        ) : (
          <pre className="payload">{entry.content}</pre>
        ))}
    </details>
  );
}

/**
 * A result the server replaced with a reference because it ran past 16 KiB. The
 * preview came with the event; the bytes are fetched by range only when somebody asks
 * for them, which is what keeps opening a long session cheap.
 */
function LargeResult({ reference, readBlob }: { reference: BlobRef; readBlob: (b: string) => Promise<string> }): JSX.Element {
  const [full, setFull] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  return (
    <div className="payload">
      <pre>{full ?? reference.preview ?? ""}</pre>
      {full === null && (
        <p className="note">
          {bytes(reference.size)} in total.{" "}
          <button
            className="link"
            disabled={busy}
            onClick={() => {
              setBusy(true);
              setError(null);
              readBlob(reference.blob)
                .then(setFull)
                .catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)))
                .finally(() => setBusy(false));
            }}
          >
            {busy ? "Fetching…" : "Show all of it"}
          </button>
        </p>
      )}
      {error && <p className="note error">{error}</p>}
    </div>
  );
}

/**
 * The small part of markdown an answer actually uses. Rendered, never dumped into a
 * `<pre>` — a wall of preformatted text is not what the agent wrote.
 */
function Markdown({ text }: { text: string }): JSX.Element {
  const blocks = text.split(/\n{2,}/);
  return (
    <div className="body">
      {blocks.map((block, i) => {
        const fence = block.match(/^```[\w-]*\n([\s\S]*?)\n?```$/);
        if (fence) return <pre key={i} className="payload">{fence[1]}</pre>;

        const heading = block.match(/^(#{1,4})\s+(.*)$/);
        if (heading) return <h3 key={i}>{heading[2]}</h3>;

        const lines = block.split("\n");
        if (lines.every((l) => /^\s*[-*]\s+/.test(l))) {
          return (
            <ul key={i}>
              {lines.map((l, j) => (
                <li key={j}>{inline(l.replace(/^\s*[-*]\s+/, ""))}</li>
              ))}
            </ul>
          );
        }
        if (lines.every((l) => /^\s*\d+[.)]\s+/.test(l))) {
          return (
            <ol key={i}>
              {lines.map((l, j) => (
                <li key={j}>{inline(l.replace(/^\s*\d+[.)]\s+/, ""))}</li>
              ))}
            </ol>
          );
        }
        return <p key={i}>{inline(block)}</p>;
      })}
    </div>
  );
}

/** Inline code and links, and nothing else pretending to be a markdown parser. */
function inline(text: string): (string | JSX.Element)[] {
  const out: (string | JSX.Element)[] = [];
  const pattern = /`([^`]+)`|\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)|(https?:\/\/\S+)/g;
  let at = 0;
  let m: RegExpExecArray | null;
  while ((m = pattern.exec(text))) {
    if (m.index > at) out.push(text.slice(at, m.index));
    if (m[1] !== undefined) out.push(<code key={m.index}>{m[1]}</code>);
    else if (m[2] !== undefined)
      out.push(
        <a key={m.index} href={m[3]} target="_blank" rel="noreferrer noopener">
          {m[2]}
        </a>,
      );
    else
      out.push(
        <a key={m.index} href={m[4]} target="_blank" rel="noreferrer noopener">
          {m[4]}
        </a>,
      );
    at = m.index + m[0].length;
  }
  if (at < text.length) out.push(text.slice(at));
  return out;
}

function Backstage({
  view,
  daemon,
  row,
  self,
}: {
  view: SessionHandle;
  daemon: DaemonClient | null;
  row: FleetRow | undefined;
  self: string | undefined;
}): JSX.Element {
  const [pane, setPane] = useState<"tasks" | "files">("tasks");
  const agents = Object.entries(view.state.agentState).filter(([path]) => path !== "");

  return (
    <aside className="backstage">
      <section>
        <div className="tabs">
          <button aria-selected={pane === "tasks"} onClick={() => setPane("tasks")}>
            Tasks
          </button>
          <button aria-selected={pane === "files"} onClick={() => setPane("files")}>
            Files
          </button>
        </div>
      </section>

      {pane === "tasks" ? (
        <section>
          <h3>What it is doing</h3>
          {view.state.todo.length === 0 ? (
            <p className="note">No task list yet.</p>
          ) : (
            <ul className="tasks">
              {view.state.todo.map((t) => (
                <li key={t.id} className={t.status}>
                  {t.content}
                </li>
              ))}
            </ul>
          )}
        </section>
      ) : (
        <section style={{ padding: 0 }}>
          <Files view={view.view} />
        </section>
      )}

      {agents.length > 0 && (
        <section>
          <h3>Who is working</h3>
          <ul className="tasks">
            {agents.map(([path, state]) => (
              <li key={path}>
                <span className="mono micro">{path}</span> {state}
              </li>
            ))}
          </ul>
        </section>
      )}

      {daemon && row && row.kind !== "team" && <LocalControls daemon={daemon} row={row} />}

      <section>
        <h3>This session</h3>
        <dl className="facts">
          <dt>Cost so far</dt>
          <dd>
            <Cost micros={view.state.costMicros ?? row?.costMicros} />
          </dd>
          <dt>Started</dt>
          <dd>
            <When iso={row?.lastActiveAt ?? null} />
          </dd>
          <dt>Owner</dt>
          <dd>{row?.owner === self ? "you" : (row?.owner ?? "—")}</dd>
          <dt>Configuration</dt>
          <dd>bundle {view.state.bundleVersion ?? "—"}</dd>
        </dl>
      </section>
    </aside>
  );
}

function Composer({ view, dormant, busy, live }: { view: SessionHandle; dormant: boolean; busy: boolean; live: boolean }): JSX.Element {
  const [draft, setDraft] = useState("");
  const [error, setError] = useState<string | null>(null);

  const submit = async (): Promise<void> => {
    const text = draft.trim();
    if (!text) return;
    setDraft("");
    setError(null);
    try {
      await view.send(text);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setDraft(text);
    }
  };

  return (
    <form
      className="composer"
      onSubmit={(e) => {
        e.preventDefault();
        void submit();
      }}
    >
      <textarea
        value={draft}
        onChange={(e) => setDraft(e.target.value)}
        aria-label="Message"
        placeholder="Write to the session…"
        onKeyDown={(e) => {
          if (e.key === "Enter" && !e.shiftKey) {
            e.preventDefault();
            void submit();
          }
        }}
      />
      <div className="row">
        <button type="submit" className="primary" disabled={!draft.trim()}>
          {dormant ? "Wake and send" : "Send"}
        </button>
        {busy && (
          <button type="button" onClick={() => void view.cancel()}>
            Stop
          </button>
        )}
        <span className="spacer" />
        <p className="hint">
          {dormant
            ? "This session is asleep. Sending wakes it, which takes about twenty seconds."
            : busy
              ? "The session is working. What you send is queued and goes next."
              : !live
                ? "Not connected. What you send is held and goes when the connection comes back."
                : "Enter sends, Shift+Enter starts a new line."}
        </p>
      </div>
      {error && <p className="hint error">{error}</p>}
    </form>
  );
}

/** No disabled composer: a greyed-out box invites clicking at it. */
function ReadOnly(): JSX.Element {
  return (
    <div className="instead">
      <p>You can read this session but not add to it.</p>
      <p className="muted">Ask its owner to give you access if you need to take part.</p>
    </div>
  );
}

function bytes(n: number): string {
  if (n < 1024) return `${n} bytes`;
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}
