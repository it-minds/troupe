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
import type { Entry } from "@troupe/client";
import { Pill } from "./bits";

export type Decision = "allow" | "deny" | "allow_session";
type Approval = Extract<Entry, { kind: "approval" }>;

/** Four words, phrased as a question, in the reader's language and not the protocol's. */
function headline(tool: string): string {
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
}: {
  entry: Approval;
  /** False on a read-only session: the buttons are absent, not disabled. */
  canAnswer: boolean;
  /** Other people who could answer this too, by display name. */
  others: string[];
  onAnswer: (decision: Decision) => Promise<void>;
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
        <header className="row">
          <Pill status={entry.decision === "deny" ? "denied" : "allowed"} />
        </header>
        <h2>{headline(entry.tool)}</h2>
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
      <header>
        <Pill status="waiting" />
      </header>
      <h2>{headline(entry.tool)}</h2>
      <p className="consequence">{consequence(entry.tool)}</p>
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
            {busy === "allow" ? "Allowing…" : "Allow"}
          </button>
          <button className="deny" onClick={() => void answer("deny")} disabled={busy !== null}>
            {busy === "deny" ? "Denying…" : "Deny"}
          </button>
          <button className="scoped" onClick={() => void answer("allow_session")} disabled={busy !== null}>
            {scopedLabel(entry.tool)}
          </button>
        </div>
      ) : (
        <p className="also">You can read this session but not answer for it.</p>
      )}
    </section>
  );
}

/** What an approval becomes in the stream once it has been answered. Never deleted. */
export function DecisionRecord({ entry, self }: { entry: Approval; self: string | undefined }): JSX.Element {
  const by = entry.resolvedBy ?? self;
  const mine = by === undefined || by === self;
  const verb = entry.decision === "deny" ? "Denied" : entry.decision === "allow_session" ? "Allowed for this session" : "Allowed";
  return (
    <div className={`decision ${entry.decision ?? "allow"}`}>
      <Pill status={entry.decision === "deny" ? "denied" : "allowed"}>{verb}</Pill>
      <span className="secondary">
        {headline(entry.tool).replace(/\?$/, "").toLowerCase()} · {mine ? "by you" : `by ${by}`}
        {entry.decision === "deny" ? " — nothing was changed" : ""}
      </span>
    </div>
  );
}
