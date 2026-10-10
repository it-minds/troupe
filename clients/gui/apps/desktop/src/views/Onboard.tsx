// Onboarding, then the librarian, at a session's start (troupe #516, Decision 835).
//
// Troupe reads its own files, `AGENTS.md` and `.agents/`, and no other tool's at run time:
// other tools' files are onboarded once into Troupe's own. A session that starts in a
// workspace where that is due asks here, where the approval and question panels sit, the
// one place on the screen a person is waited on: one question for the lot, each file's
// diff a click away, a new `AGENTS.md` asked on its own (Decision 827), and after that the
// brief, when an older survey wrote it. The plan and the writing are the daemon's
// (`StartQuestions` in the client library); this draws them. Afterwards a line says what
// was done, and where onboarding may not run, the daemon's sentence says why and nothing
// is asked.

import type { JSX } from "react";
import { describeItem } from "@troupe/client";
import type { StartAnswer, StartQuestion, StartState } from "@troupe/client";
import { Pill } from "./bits";
import { Mask } from "./brand";

export function StartPanel({ state, onAnswer }: { state: StartState; onAnswer: (answer: StartAnswer) => void }): JSX.Element | null {
  const asking = state.asking;
  if (!asking) return null;
  const busy = state.busy;

  // A new question is a new panel, scrolled to its top rather than to where the last one was left.
  const key = asking.kind === "review" || asking.kind === "create" ? `${asking.kind}-${asking.item.id}` : asking.kind;

  return (
    <section key={key} className="approval question start" aria-label={asking.kind === "brief" ? "The project brief" : "Onboarding"}>
      <header>
        <Mask size={26} />
        <Pill status="waiting" />
        <h2>{asking.text}</h2>
      </header>
      <Body asking={asking} />
      {state.error && <p className="also error">{state.error}</p>}
      <div className="answers">
        {answers(asking).map(([answer, label, kind]) => (
          <button key={answer} className={kind} onClick={() => onAnswer(answer)} disabled={busy}>
            {label}
          </button>
        ))}
      </div>
    </section>
  );
}

/** Each question's answers, the default first and filled. */
function answers(asking: StartQuestion): Array<[StartAnswer, string, "allow" | "deny"]> {
  switch (asking.kind) {
    case "onboard":
      return [
        ["onboard", asking.due === "outdated" ? "Re-run" : "Onboard", "allow"],
        ["review", "Review", "deny"],
        ["decline", "Not now", "deny"],
      ];
    case "review":
      return [
        ["write", "Write", "allow"],
        ["skip", "Skip", "deny"],
      ];
    case "create":
      return [
        ["create", `Create ${asking.item.shown}`, "allow"],
        ["skip", "Don't create", "deny"],
      ];
    case "brief":
      return [
        ["rerun", "Re-run", "allow"],
        ["decline", "Not now", "deny"],
      ];
  }
}

function Body({ asking }: { asking: StartQuestion }): JSX.Element {
  switch (asking.kind) {
    case "onboard":
      return (
        <>
          <p className="consequence">{asking.detail}</p>
          <ul className="onboard-files" aria-label="The files">
            {asking.items.map((item) => (
              <li key={item.id}>
                <span className="mono">{item.shown}</span> <span className="muted">{describeItem(item)}</span>
              </li>
            ))}
          </ul>
          {asking.skipped.length > 0 && (
            <p className="also plain">
              Not proposed: {asking.skipped.map((s) => `${s.source} (${s.reason})`).join("; ")}
            </p>
          )}
        </>
      );
    case "review":
    case "create":
      return (
        <>
          <p className="consequence">
            {describeItem(asking.item)}
            {asking.kind === "review" && ` · file ${asking.index} of ${asking.total}`}
          </p>
          {asking.item.notes.length > 0 && (
            <ul className="onboard-notes" aria-label="What was left out or changed">
              {asking.item.notes.map((note) => (
                <li key={note}>{note}</li>
              ))}
            </ul>
          )}
          <Diff text={asking.item.diff} />
        </>
      );
    case "brief":
      return <p className="consequence">{asking.detail}</p>;
  }
}

/** The plan's line diff: what is added and taken away in the diff colours, the rest as context. */
function Diff({ text }: { text: string }): JSX.Element {
  return (
    <pre className="evidence diff-lines" aria-label="What it would write">
      {text.split("\n").map((line, i) => (
        <span key={i} className={line.startsWith("+") ? "add" : line.startsWith("-") ? "del" : "ctx"}>
          {line}
        </span>
      ))}
    </pre>
  );
}

/** What the start's questions came to, or why none were asked. Nothing while a question waits with nothing said yet. */
export function StartLine({ state }: { state: StartState | null }): JSX.Element | null {
  if (!state) return null;
  if (state.refusal) {
    return (
      <div className="banner readonly" role="status">
        <p>{state.refusal}</p>
      </div>
    );
  }
  if (state.error && !state.asking) {
    return (
      <div className="banner error" role="status">
        <p>Onboarding could not go on: {state.error}</p>
      </div>
    );
  }
  if (state.said.length === 0) return null;
  return (
    <div className="banner offered" role="status">
      {state.said.map((sentence) => (
        <p key={sentence}>{sentence}</p>
      ))}
    </div>
  );
}
