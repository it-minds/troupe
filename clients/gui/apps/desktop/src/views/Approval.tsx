// The approval panel. The core loop, and the only amber on the screen.
//
// It never takes over: no modal, no dimming, no countdown, no sound. It wins by
// position (sticky at the bottom of the conversation, where the thumb already is),
// colour (the reserved amber), light (the footlight, which nothing else has), and
// language — the headline is a question in four words.
//
// When somebody else answers first, the panel does not vanish. Disappearing would
// leave the reader wondering whether they pressed something; instead it is replaced in
// place by a calm record that names who decided and says nothing is waiting on them.

import { useEffect, useRef, useState } from "react";
import type { JSX } from "react";
import { BRIEF_PARTS, ruleScope } from "@troupe/client";
import type { DelegationGate, Entry, GateAnswer } from "@troupe/client";
import { Pill } from "./bits";
import { Mask } from "./brand";

export type Decision = "allow" | "deny" | "allow_session";
type Approval = Extract<Entry, { kind: "approval" }>;

/** A brief's parts by the names a person reads them by (troupe Decision 847). */
const PART_NAMES: Record<string, string> = {
  goal: "Goal",
  context: "Context",
  constraints: "Constraints",
  deliverable: "Deliverable",
  do_not: "Do not",
};

/** Four words, phrased as a question, in the reader's language and not the protocol's. */
function headline(tool: string): string {
  if (tool === "delegate") return "Hand work to a subagent?";
  if (/shell|bash|command|exec/i.test(tool)) return "Run a command?";
  if (/write|edit|patch|apply/i.test(tool)) return "Change a file?";
  if (/delete|remove|rm/i.test(tool)) return "Delete a file?";
  if (/fetch|http|web|browse/i.test(tool)) return "Open a web page?";
  return "Allow this action?";
}

/** One plain sentence about the consequence. Never a scope name, never an endpoint. */
function consequence(tool: string): string {
  if (/shell|bash|command|exec/i.test(tool)) {
    return "The session wants to run this command. It runs on the platform, not on your computer.";
  }
  if (/write|edit|patch|apply/i.test(tool)) return "The session wants to change a file in its workspace.";
  if (/delete|remove|rm/i.test(tool)) return "The session wants to delete a file from its workspace. This cannot be undone from here.";
  return `The session wants to use ${tool}.`;
}

/** The scoped answer is spelled out in full, because it is the one people regret. */
function scopedLabel(tool: string): string {
  if (/shell|bash|command|exec/i.test(tool)) return "Allow every command for this session";
  if (/write|edit|patch|apply/i.test(tool)) return "Allow every file change for this session";
  return `Allow ${tool} for this session`;
}

/** The evidence, rendered rather than dumped. */
function Evidence({ entry }: { entry: Approval }): JSX.Element | null {
  const args = (entry.args ?? {}) as Record<string, unknown>;
  const command = typeof args["command"] === "string" ? args["command"] : null;
  const path = typeof args["path"] === "string" ? args["path"] : null;

  if (command) {
    return (
      <div className="evidence">
        <div className="command">{command}</div>
        {typeof args["cwd"] === "string" && <p className="also">In {args["cwd"]}.</p>}
      </div>
    );
  }
  if (path) {
    return (
      <div className="evidence">
        <div className="command">{path}</div>
      </div>
    );
  }
  return (
    <div className="evidence">
      <pre>{JSON.stringify(entry.args, null, 2)}</pre>
    </div>
  );
}

export function ApprovalPanel({
  entry,
  canAnswer,
  others,
  onAnswer,
  onDefinition,
  onceOnly = false,
}: {
  entry: Approval;
  /** False on a read-only session: the buttons are absent, not disabled. */
  canAnswer: boolean;
  /** Other people who could answer this too, by display name. */
  others: string[];
  onAnswer: (decision: Decision, answer?: GateAnswer) => Promise<void>;
  /** Opens a delegation's agent in the agents manager, where there is one to open. */
  onDefinition?: ((agent: string) => void) | undefined;
  /**
   * A laptop's session steered from here, through the plane: a call is allowed or denied
   * once, and allowing it for the rest of the session is the laptop's person's to do there.
   */
  onceOnly?: boolean;
}): JSX.Element {
  // A delegation a person asked to see first has five answers, not three (troupe Decision 850).
  if (entry.delegation && entry.decision === undefined) {
    return (
      <DelegationPanel
        entry={entry}
        gate={entry.delegation}
        canAnswer={canAnswer}
        others={others}
        onAnswer={onAnswer}
        onDefinition={onDefinition}
        onceOnly={onceOnly}
      />
    );
  }
  return <ToolApproval entry={entry} canAnswer={canAnswer} others={others} onAnswer={onAnswer} onceOnly={onceOnly} />;
}

function ToolApproval({
  entry,
  canAnswer,
  others,
  onAnswer,
  onceOnly,
}: {
  entry: Approval;
  canAnswer: boolean;
  others: string[];
  onAnswer: (decision: Decision) => Promise<void>;
  onceOnly: boolean;
}): JSX.Element {
  const [busy, setBusy] = useState<Decision | null>(null);
  const [error, setError] = useState<string | null>(null);
  const allow = useRef<HTMLButtonElement>(null);

  const answered = entry.decision !== undefined;

  // A and D answer, but never while somebody is typing, and never by moving focus.
  useEffect(() => {
    if (answered || !canAnswer) return;
    const onKey = (e: KeyboardEvent): void => {
      const target = e.target as HTMLElement | null;
      if (target && /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName)) return;
      if (target?.isContentEditable) return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key === "a" || e.key === "A") void answer("allow");
      if (e.key === "d" || e.key === "D") void answer("deny");
    };
    globalThis.addEventListener("keydown", onKey);
    return () => globalThis.removeEventListener("keydown", onKey);
  });

  const answer = async (decision: Decision): Promise<void> => {
    if (busy) return;
    setBusy(decision);
    setError(null);
    try {
      await onAnswer(decision);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  // Answered, by whoever got there first. The amber goes, the panel stays.
  if (answered) {
    const mine = entry.resolvedBy === undefined;
    return (
      <section className="approval answered" aria-live="assertive">
        <header>
          <Pill status={entry.decision === "deny" ? "denied" : "allowed"} />
          <h2>{headline(entry.tool)}</h2>
        </header>
        <p className="consequence">
          {entry.decision === "deny"
            ? `Denied${mine ? " by you" : ` by ${entry.resolvedBy}`} — nothing was changed.`
            : `Allowed${mine ? " by you" : ` by ${entry.resolvedBy}`}. Nothing is waiting for you now.`}
        </p>
      </section>
    );
  }

  return (
    <section className="approval">
      {/* The mask, lit and pulsing, then the word, then the question: the comp's header row. */}
      <header>
        <Mask size={26} />
        <Pill status="waiting" />
        <h2>{headline(entry.tool)}</h2>
      </header>
      <p className="consequence">{consequence(entry.tool)}</p>
      {/* A per-tool rule of the configuration asked (troupe #658): which, and whose. */}
      {entry.rule && (
        <p className="also asked-by">
          Asked by the rule <code>ask {entry.rule.rule}</code>, from {ruleScope(entry.rule)}
          {entry.rule.source ? ` (${entry.rule.source})` : ""}. Every call it matches asks, whatever was allowed for this session.
        </p>
      )}
      <Evidence entry={entry} />
      {others.length > 0 && (
        <p className="also">
          {others.length === 1 ? `${others[0]} can answer this too.` : `${others.slice(0, -1).join(", ")} and ${others.at(-1)} can answer this too.`}{" "}
          The first answer counts.
        </p>
      )}
      {error && <p className="also error">{error}</p>}

      {canAnswer ? (
        <div className="answers">
          <button ref={allow} className="allow" onClick={() => void answer("allow")} disabled={busy !== null}>
            {busy === "allow" ? "Allowing…" : onceOnly ? "Allow once" : "Allow"}
          </button>
          <button className="deny" onClick={() => void answer("deny")} disabled={busy !== null}>
            {busy === "deny" ? "Denying…" : "Deny"}
          </button>
          {!onceOnly && (
            <button className="scoped" onClick={() => void answer("allow_session")} disabled={busy !== null}>
              {scopedLabel(entry.tool)}
            </button>
          )}
        </div>
      ) : (
        <p className="also">You can read this session but not answer for it.</p>
      )}
    </section>
  );
}

/**
 * A delegation a person asked to see before it starts (troupe Decision 850): the agent and
 * a way to its definition, the tools and permissions the subagent will hold, its depth and
 * budget share, and the brief's five parts. The five answers: run it; edit a part in place
 * (held to the brief's shape: a part left empty is refused); send the same brief to
 * another subagent; deny it, with a word back the agent that delegated reads as the
 * answer; or let that agent run unasked for the rest of the session. The definition is
 * linked, never edited here: an edit for one run would be a fork nobody finds again.
 */
function DelegationPanel({
  entry,
  gate,
  canAnswer,
  others,
  onAnswer,
  onDefinition,
  onceOnly,
}: {
  entry: Approval;
  gate: DelegationGate;
  canAnswer: boolean;
  others: string[];
  onAnswer: (decision: Decision, answer?: GateAnswer) => Promise<void>;
  onDefinition?: ((agent: string) => void) | undefined;
  onceOnly: boolean;
}): JSX.Element {
  const [edits, setEdits] = useState<Record<string, string>>({});
  const [editing, setEditing] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [agent, setAgent] = useState(gate.agent);
  const [denying, setDenying] = useState(false);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState<Decision | null>(null);
  const [error, setError] = useState<string | null>(null);

  const answer = (): GateAnswer => ({
    ...(agent !== gate.agent ? { agent } : {}),
    ...(Object.keys(edits).length > 0 ? { brief: edits } : {}),
  });

  const send = async (decision: Decision, given: GateAnswer): Promise<void> => {
    if (busy) return;
    setBusy(decision);
    setError(null);
    try {
      await onAnswer(decision, given);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const keep = (part: string): void => {
    const text = draft.trim();
    if (text === "") {
      setError("A part of the brief cannot be empty: write none where it has nothing.");
      return;
    }
    setError(null);
    setEdits((now) => {
      const next = { ...now };
      if (text === gate.brief[part]) delete next[part];
      else next[part] = text;
      return next;
    });
    setEditing(null);
  };

  const share = gate.budgetShare === null ? null : `${Math.round(gate.budgetShare * 100)}% of the budget`;
  const switched = agent !== gate.agent ? gate.agents.find((a) => a.name === agent) : undefined;

  return (
    <section className="approval delegation" aria-label={`Delegation to ${agent}`}>
      <header>
        <Mask size={26} />
        <Pill status="waiting" />
        <h2>Hand this to {agent}?</h2>
      </header>
      <p className="consequence">
        The session wants a subagent to do this. Nothing starts until you answer, and what you change here is what it is given.
      </p>

      <dl className="facts gate">
        <dt>Agent</dt>
        <dd>
          {gate.agent}
          {gate.definition.description ? ` — ${gate.definition.description}` : ""}{" "}
          {onDefinition ? (
            <button type="button" className="link" onClick={() => onDefinition(gate.agent)}>
              Open its definition
            </button>
          ) : (
            <span className="muted">{[gate.definition.layer, gate.definition.path].filter(Boolean).join(" ")}</span>
          )}
        </dd>
        {switched && (
          <>
            <dt>Sent to</dt>
            <dd>
              {switched.name}
              {switched.description ? ` — ${switched.description}` : ""}, with its own tools and budget
            </dd>
          </>
        )}
        <dt>Depth</dt>
        <dd>
          {gate.depth ?? "?"} of {gate.maxDepth ?? "?"}
        </dd>
        {share && (
          <>
            <dt>Budget</dt>
            <dd>{share}</dd>
          </>
        )}
        <dt>Tools</dt>
        <dd>{gate.tools.length > 0 ? gate.tools.map((t) => `${t.name} ${t.permission}`).join(", ") : "its own"}</dd>
      </dl>

      <dl className="facts wide parts brief" aria-label="The brief">
        {BRIEF_PARTS.map((part) => {
          const text = edits[part] ?? gate.brief[part] ?? "";
          const edited = edits[part] !== undefined;
          return (
            <div key={part} className="gate-part">
              <dt>
                {PART_NAMES[part]}
                {edited ? " · edited" : ""}
              </dt>
              <dd>
                {editing === part ? (
                  <form
                    className="answers"
                    onSubmit={(e) => {
                      e.preventDefault();
                      keep(part);
                    }}
                  >
                    <textarea value={draft} onChange={(e) => setDraft(e.target.value)} aria-label={`Edit ${PART_NAMES[part]}`} rows={3} />
                    <button type="submit" className="deny">
                      Keep
                    </button>
                    <button type="button" className="deny" onClick={() => setEditing(null)}>
                      Back
                    </button>
                  </form>
                ) : (
                  <>
                    <span className="gate-text">{text}</span>{" "}
                    {canAnswer && editing === null && (
                      <button
                        type="button"
                        className="link"
                        aria-label={`Edit ${PART_NAMES[part]}`}
                        onClick={() => {
                          setDraft(text);
                          setEditing(part);
                        }}
                      >
                        Edit
                      </button>
                    )}
                  </>
                )}
              </dd>
            </div>
          );
        })}
      </dl>

      {others.length > 0 && <p className="also">{others.join(", ")} can answer this too. The first answer counts.</p>}
      {error && <p className="also error">{error}</p>}

      {!canAnswer ? (
        <p className="also">You can read this session but not answer for it.</p>
      ) : denying ? (
        <form
          className="answers"
          onSubmit={(e) => {
            e.preventDefault();
            const word = reason.trim();
            void send("deny", word ? { reason: word } : {});
          }}
        >
          <input
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="A word back for the agent that delegated (optional)"
            aria-label="A word back"
            disabled={busy !== null}
          />
          <button type="submit" className="deny" disabled={busy !== null}>
            {busy === "deny" ? "Denying…" : "Deny"}
          </button>
          <button type="button" className="deny" onClick={() => setDenying(false)} disabled={busy !== null}>
            Back
          </button>
        </form>
      ) : (
        <div className="answers">
          <button className="allow" onClick={() => void send("allow", answer())} disabled={busy !== null || editing !== null}>
            {busy === "allow" ? "Starting…" : "Run"}
          </button>
          <button className="deny" onClick={() => setDenying(true)} disabled={busy !== null}>
            Deny…
          </button>
          <label className="also plain">
            Send to{" "}
            <select value={agent} onChange={(e) => setAgent(e.target.value)} aria-label="Send to" disabled={busy !== null}>
              {gate.agents.map((a) => (
                <option key={a.name} value={a.name}>
                  {a.name}
                </option>
              ))}
            </select>
          </label>
          {!onceOnly && (
            <button className="scoped" onClick={() => void send("allow_session", answer())} disabled={busy !== null || editing !== null}>
              {busy === "allow_session" ? "Starting…" : `Run, and let ${agent} run unasked for this session`}
            </button>
          )}
        </div>
      )}
    </section>
  );
}

/** What an approval becomes in the stream once it has been answered. Never deleted. */
export function DecisionRecord({ entry, self }: { entry: Approval; self: string | undefined }): JSX.Element {
  const by = entry.resolvedBy ?? self;
  const mine = by === undefined || by === self;
  const verb = entry.decision === "deny" ? "Denied" : entry.decision === "allow_session" ? "Allowed for this session" : "Allowed";
  const said = entry.answered;
  // A delegation's answer says what it changed: where it went, which parts, the word back.
  const detail = said
    ? [
        said.agent && entry.delegation && said.agent !== entry.delegation.agent ? `sent to ${said.agent}` : null,
        said.edited && said.edited.length > 0 ? `edited ${said.edited.map((p) => PART_NAMES[p] ?? p).join(", ").toLowerCase()}` : null,
        said.reason ? `said: ${said.reason}` : null,
      ].filter(Boolean)
    : [];
  return (
    <div className={`decision ${entry.decision ?? "allow"}`}>
      <Pill status={entry.decision === "deny" ? "denied" : "allowed"}>{verb}</Pill>
      <span className="secondary">
        {headline(entry.tool).replace(/\?$/, "").toLowerCase()} · {mine ? "by you" : `by ${by}`}
        {detail.length > 0 ? ` · ${detail.join(" · ")}` : ""}
        {entry.decision === "deny" ? " — nothing was changed" : ""}
      </span>
    </div>
  );
}
