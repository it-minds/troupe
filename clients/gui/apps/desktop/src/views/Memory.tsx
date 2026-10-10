// The repository's memory, in the backstage beside the tasks and the files (troupe #248).
//
// The daemon keeps facts, each with the files it rests on and how it was learned, and
// works out their status whenever they are read; `.troupe/memory.md` is written from them.
// This lists them by kind, a fact whose file changed or went since it was written marked
// "may no longer be true" in a caution colour, shows a fact's evidence when it is chosen,
// and forgets one on a second word from the person. A daemon from before facts answers
// with the brief's text, which is shown as it is. `/memory` in the composer opens it.
//
// It does what the terminal client's `/memory` does besides: Refresh has the librarian
// write the brief again, as a branch of this session and under the start's conditions,
// and the whole brief can be forgotten, on a second word. It reads the memory again when
// a librarian it knows of (the start's, or a refresh's) is done, not only when it opens.
//
// There is no warning token in the design: "may no longer be true" is drawn in the
// `offline` status colour, the amber-adjacent one for something that may have gone out of
// date, never in the reserved colour, which belongs to work waiting for a person.

import { useCallback, useEffect, useState } from "react";
import type { JSX } from "react";
import { factStatusLine, factsByKind, isDurable, learnedBy, librarianDone, mayNoLongerBeTrue, refreshNow } from "@troupe/client";
import type { DaemonClient, MemoryBrief, MemoryFact, TroupeEvent } from "@troupe/client";
import { Loading, Pill, When } from "./bits";

/** What `/memory` with an argument asks of the pane; `n` tells one asking from the next. */
export interface MemoryAsk {
  what: "refresh" | "forget";
  n: number;
}

/** The brief's status, as a person reads it. */
function briefLine(brief: MemoryBrief): string {
  switch (brief.status) {
    case "absent":
      return "There is no project brief yet.";
    case "stale":
      return "The brief is stale: older than it may be, and due to be surveyed again.";
    case "disabled":
      return "Memory is off for this workspace (memory: false in its config).";
    default:
      return "";
  }
}

export function MemoryPane({
  daemon,
  workspace,
  sessionId,
  librarians,
  ask,
  onAsked,
}: {
  daemon: DaemonClient;
  workspace: string | undefined;
  /** The session the pane is in: a refresh starts the librarian as a branch of it. */
  sessionId: string;
  /** The librarian sessions the start began; the pane reads the memory again when one is done. */
  librarians: string[];
  /** What `/memory refresh` or `/memory forget` asked of it, counted so each asks once. */
  ask?: MemoryAsk | null | undefined;
  /** The ask is taken: a pane opened again does not do it twice. */
  onAsked?: (() => void) | undefined;
}): JSX.Element {
  const [brief, setBrief] = useState<MemoryBrief | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [chosen, setChosen] = useState<string | null>(null);
  // What the last refresh came to, and the librarians refreshes started here.
  const [refreshed, setRefreshed] = useState<string | null>(null);
  const [asked, setAsked] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [forgetting, setForgetting] = useState(false);

  const load = useCallback(async () => {
    if (!workspace) return;
    setError(null);
    try {
      setBrief(await daemon.memory(workspace));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [daemon, workspace]);

  useEffect(() => {
    setBrief(null);
    setChosen(null);
    void load();
  }, [load]);

  // Each librarian this pane knows of is listened to, and its being done (its root's
  // `agent_done`, or its turn ending as it rests) reads the memory again. One that was
  // done already says so in its replay, which reads it once more.
  const watched = [...new Set([...librarians, ...asked])].join("\n");
  useEffect(() => {
    const stops = watched
      .split("\n")
      .filter(Boolean)
      .map((id) => {
        let live = true;
        let held = false;
        const listener = (e: TroupeEvent): void => {
          if (live && isDurable(e) && librarianDone(e)) void load();
        };
        daemon
          .open(id, {}, listener)
          .then(() => {
            if (live) held = true;
            else void daemon.close(id, listener);
          })
          .catch(() => undefined);
        return () => {
          live = false;
          if (held) void daemon.close(id, listener);
        };
      });
    return () => {
      for (const stop of stops) stop();
    };
  }, [daemon, watched, load]);

  const refresh = useCallback(async (): Promise<void> => {
    if (!workspace) return;
    setBusy(true);
    setRefreshed(null);
    try {
      const r = await refreshNow(daemon, workspace, sessionId);
      setRefreshed(r.said);
      if (r.librarian) setAsked((a) => [...a, r.librarian!]);
    } finally {
      setBusy(false);
    }
  }, [daemon, workspace, sessionId]);

  const forgetBrief = async (): Promise<void> => {
    if (!workspace) return;
    setBusy(true);
    setError(null);
    try {
      await daemon.forgetBrief(workspace);
      setForgetting(false);
      setChosen(null);
      await load();
    } catch (e) {
      setError(`Could not forget the brief: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setBusy(false);
    }
  };

  // `/memory refresh` refreshes and `/memory forget` asks the second word, as the pane's
  // own buttons do; each command once, handed back as done.
  const doing = ask?.n;
  useEffect(() => {
    if (doing === undefined || !ask || !workspace) return;
    onAsked?.();
    if (ask.what === "refresh") void refresh();
    else setForgetting(true);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [doing, workspace]);

  if (!workspace) return <Loading what="Finding where this session works…" />;
  if (error && !brief) return <p className="note error">Could not read the memory: {error}</p>;
  if (!brief) return <Loading what="Reading the memory…" />;

  const line = briefLine(brief);
  return (
    <div className="memory">
      <p className="note">
        <span className="mono micro">{brief.path}</span>
        {brief.built_at && (
          <>
            {" "}
            · built <When iso={brief.built_at} />
          </>
        )}
      </p>
      {line && <p className="note">{line}</p>}
      {error && <p className="note error">{error}</p>}

      {brief.status !== "disabled" && (
        <div className="memory-actions">
          <button onClick={() => void refresh()} disabled={busy} title="The librarian surveys the repository and writes the brief again, in a session of its own">
            Refresh
          </button>
          {brief.status !== "absent" && !forgetting && (
            <button className="danger" onClick={() => setForgetting(true)} disabled={busy}>
              Forget the brief
            </button>
          )}
        </div>
      )}
      {refreshed && <p className="note refreshed">{refreshed}</p>}
      {forgetting && (
        <div className="forget" aria-label="Forget the brief">
          <p className="note">Forget the whole brief? Every fact goes, and .troupe/memory.md with them; Refresh has the librarian write a new one.</p>
          <div className="forget-answers">
            <button className="danger" onClick={() => void forgetBrief()} disabled={busy}>
              {busy ? "Forgetting…" : "Forget all of it"}
            </button>
            <button onClick={() => setForgetting(false)} disabled={busy}>
              Keep it
            </button>
          </div>
        </div>
      )}

      {brief.facts ? (
        <Facts
          facts={brief.facts}
          generated={brief.generated === true}
          chosen={chosen}
          onChoose={(id) => setChosen((c) => (c === id ? null : id))}
          onForget={async (fact) => {
            setError(null);
            try {
              await daemon.forgetFact(workspace, fact.id);
              setChosen(null);
              await load();
            } catch (e) {
              setError(`Could not forget it: ${e instanceof Error ? e.message : String(e)}`);
            }
          }}
        />
      ) : brief.text ? (
        // A daemon from before facts keeps the brief as text; it is shown as it is.
        <pre className="payload brief-text">{brief.text}</pre>
      ) : null}
    </div>
  );
}

function Facts({
  facts,
  generated,
  chosen,
  onChoose,
  onForget,
}: {
  facts: MemoryFact[];
  generated: boolean;
  chosen: string | null;
  onChoose: (id: string) => void;
  onForget: (fact: MemoryFact) => Promise<void>;
}): JSX.Element {
  const doubtful = facts.filter(mayNoLongerBeTrue).length;
  return (
    <>
      {generated && <p className="note">.troupe/memory.md is written from these facts. Agents read the commands and conventions in every prompt and ask for the rest.</p>}
      {facts.length === 0 && <p className="note">No facts yet.</p>}
      {doubtful > 0 && (
        <p className="note doubtful">
          {doubtful === 1
            ? "1 fact may no longer be true: a file it rests on changed or went since. The librarian checks it again on its next run."
            : `${doubtful} facts may no longer be true: a file each rests on changed or went since. The librarian checks them again on its next run.`}
        </p>
      )}
      {factsByKind(facts).map((group) => (
        <section key={group.kind} className="fact-kind" aria-label={group.title}>
          <h4>{group.title}</h4>
          <ul>
            {group.facts.map((fact) => (
              <li key={fact.id} className={`fact ${fact.status}`}>
                <button className="claim" aria-expanded={chosen === fact.id} onClick={() => onChoose(fact.id)}>
                  <span className="text">
                    <Claim text={fact.claim} />
                  </span>
                  <FactStatus fact={fact} />
                </button>
                {chosen === fact.id && <Evidence fact={fact} onForget={() => onForget(fact)} />}
              </li>
            ))}
          </ul>
        </section>
      ))}
    </>
  );
}

/** A claim as written, a command or a path in backticks set as code, as the transcript sets it. */
function Claim({ text }: { text: string }): JSX.Element {
  const parts = text.split(/`([^`]+)`/);
  return <>{parts.map((part, i) => (i % 2 === 1 ? <code key={i}>{part}</code> : part))}</>;
}

/** A fact's status beside its claim: a pill when it may no longer be true, a quiet word otherwise. */
function FactStatus({ fact }: { fact: MemoryFact }): JSX.Element {
  if (mayNoLongerBeTrue(fact)) return <Pill status="offline">May no longer be true</Pill>;
  if (fact.status === "unanchored") return <span className="micro muted">not tied to a file</span>;
  return <span className="micro muted">{fact.status}</span>;
}

/** How a fact was learned and what it rests on, and forgetting it. */
function Evidence({ fact, onForget }: { fact: MemoryFact; onForget: () => Promise<void> }): JSX.Element {
  const [asking, setAsking] = useState(false);
  const [busy, setBusy] = useState(false);
  const e = fact.evidence;
  return (
    <div className="evidence-of" aria-label="Evidence">
      <p className={`note ${mayNoLongerBeTrue(fact) ? "doubtful" : ""}`}>{factStatusLine(fact)}</p>
      <dl className="facts">
        <dt>Rests on</dt>
        <dd>
          {fact.anchors.length === 0
            ? "no file"
            : fact.anchors.map((a) => (
                <span key={a.path} className="anchor">
                  <span className="mono">{a.path}</span> <span className="muted" title={a.hash}>{a.hash.slice(0, 12)}</span>
                </span>
              ))}
        </dd>
        {fact.scope && (
          <>
            <dt>About</dt>
            <dd className="mono">{fact.scope}</dd>
          </>
        )}
        <dt>Learned by</dt>
        <dd>{learnedBy(e.by)}</dd>
        {e.session && (
          <>
            <dt>In</dt>
            <dd className="mono">
              {e.session}
              {e.seq !== null && e.seq !== undefined ? ` · event ${e.seq}` : ""}
            </dd>
          </>
        )}
        {e.head && (
          <>
            <dt>At commit</dt>
            <dd className="mono">{e.head}</dd>
          </>
        )}
        {e.exit_status !== undefined && e.exit_status !== null && (
          <>
            <dt>Exit status</dt>
            <dd className="mono">{e.exit_status}</dd>
          </>
        )}
        <dt>Written</dt>
        <dd>
          <When iso={fact.created_at} />
        </dd>
        <dt>Checked</dt>
        <dd>
          <When iso={fact.verified_at} />
        </dd>
      </dl>
      {asking ? (
        <div className="forget">
          <p className="note">Forget it? It leaves the agents' prompts and .troupe/memory.md; the librarian may learn it again.</p>
          <div className="forget-answers">
            <button
              className="danger"
              disabled={busy}
              onClick={() => {
                setBusy(true);
                void onForget().finally(() => setBusy(false));
              }}
            >
              {busy ? "Forgetting…" : "Forget it"}
            </button>
            <button onClick={() => setAsking(false)} disabled={busy}>
              Keep it
            </button>
          </div>
        </div>
      ) : (
        <button className="danger" onClick={() => setAsking(true)}>
          Forget
        </button>
      )}
    </div>
  );
}
