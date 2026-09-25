// A question for a person. Two askers, one panel.
//
// The agent's `ask_user` hands a decision over: a question, sometimes options, and free
// text always allowed. The harness's budget question (troupe-remote Decision 660) is the
// other asker: the budget is spent, and somebody has to say whether to buy another slice.
// Both arrive as `question_asked`, both are answered with `question.answer`, and both sit
// where the approval panel sits — the one place on the screen a person is waited on. The
// budget question speaks in consequences rather than the harness's words: "one more
// slice", not `allow`.

import { useState } from "react";
import type { JSX } from "react";
import type { Entry } from "@troupe/client";
import { Pill } from "./bits";

type Question = Extract<Entry, { kind: "question" }>;

/** The harness's three answers, in the reader's words. The wire words are the keys. */
const BUDGET_ANSWERS: Record<string, { label: string; className: string }> = {
  allow: { label: "Spend one more slice", className: "allow" },
  deny: { label: "Stop here", className: "deny" },
  // The limit the question names, and only that one (troupe-remote Decision 687).
  always: { label: "Lift this limit for the session", className: "scoped" },
};

export function QuestionPanel({
  entry,
  canAnswer,
  onAnswer,
}: {
  entry: Question;
  /** False on a read-only session: the answers are absent, not disabled. */
  canAnswer: boolean;
  onAnswer: (text: string) => Promise<void>;
}): JSX.Element {
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const answer = async (value: string): Promise<void> => {
    if (busy || !value.trim()) return;
    setBusy(value);
    setError(null);
    try {
      await onAnswer(value);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const budget = entry.asked === "budget";

  return (
    <section className="approval question">
      <header>
        <Pill status="waiting" />
      </header>
      <h2>{budget ? "Out of budget. Carry on?" : "The session has a question"}</h2>
      <p className="consequence">
        {budget
          ? `${entry.question}. One more slice is the same budget again, and it asks again when that is spent.`
          : entry.question}
      </p>
      {error && <p className="also error">{error}</p>}

      {!canAnswer ? (
        <p className="also">You can read this session but not answer for it.</p>
      ) : budget ? (
        <BudgetAnswers entry={entry} busy={busy} onAnswer={answer} />
      ) : (
        <Answers entry={entry} busy={busy} onAnswer={answer} />
      )}
    </section>
  );
}

function BudgetAnswers({ entry, busy, onAnswer }: { entry: Question; busy: string | null; onAnswer: (v: string) => Promise<void> }): JSX.Element {
  return (
    <div className="answers">
      {entry.options.map((o) => {
        const words = BUDGET_ANSWERS[o.label] ?? { label: o.label, className: "scoped" };
        return (
          <button key={o.label} className={words.className} onClick={() => void onAnswer(o.label)} disabled={busy !== null} title={o.description ?? undefined}>
            {busy === o.label ? "Answering…" : words.label}
          </button>
        );
      })}
    </div>
  );
}

/**
 * The agent's options, then a line for words of your own. A single-choice question is
 * answered by the option itself; a multiple-choice one collects ticks until sent, which
 * is what the harness expects — the chosen labels, joined with a comma.
 */
function Answers({ entry, busy, onAnswer }: { entry: Question; busy: string | null; onAnswer: (v: string) => Promise<void> }): JSX.Element {
  const [text, setText] = useState("");
  const [ticked, setTicked] = useState<string[]>([]);
  const tick = (label: string): void => setTicked((t) => (t.includes(label) ? t.filter((x) => x !== label) : [...t, label]));

  return (
    <>
      {entry.options.length > 0 && (
        <div className="answers">
          {entry.options.map((o) =>
            entry.multiple ? (
              <button key={o.label} className={ticked.includes(o.label) ? "allow" : "scoped"} aria-pressed={ticked.includes(o.label)} onClick={() => tick(o.label)} disabled={busy !== null} title={o.description ?? undefined}>
                {o.label}
              </button>
            ) : (
              <button key={o.label} className="scoped" onClick={() => void onAnswer(o.label)} disabled={busy !== null} title={o.description ?? undefined}>
                {busy === o.label ? "Answering…" : o.label}
              </button>
            ),
          )}
          {entry.multiple && (
            <button className="allow" onClick={() => void onAnswer(ticked.join(", "))} disabled={busy !== null || ticked.length === 0}>
              {ticked.length === 0 ? "Choose, then answer" : `Answer with ${ticked.length} chosen`}
            </button>
          )}
        </div>
      )}
      <form
        className="answers"
        onSubmit={(e) => {
          e.preventDefault();
          void onAnswer(text);
        }}
      >
        <input
          value={text}
          onChange={(e) => setText(e.target.value)}
          placeholder={entry.options.length > 0 ? "Or answer in your own words" : "Your answer"}
          disabled={busy !== null}
          aria-label="Your answer"
        />
        <button type="submit" className="allow" disabled={busy !== null || !text.trim()}>
          {busy === text && text ? "Answering…" : "Answer"}
        </button>
      </form>
    </>
  );
}

/** The question once answered: a calm line in the stream, so the panel can go. */
export function AnswerRecord({ entry }: { entry: Question }): JSX.Element {
  if (entry.asked === "budget") {
    const words = BUDGET_ANSWERS[entry.answer ?? ""]?.label ?? entry.answer ?? "answered";
    return <p className="note">Out of budget — {words.toLowerCase()}.</p>;
  }
  return (
    <p className="note">
      Asked: {entry.question} — answered: {entry.answer}
    </p>
  );
}
