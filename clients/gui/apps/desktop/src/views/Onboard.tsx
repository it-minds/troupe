// Onboarding, then the librarian, at a session's start (troupe #516, Decision 835).
//
// Troupe reads its own files, `AGENTS.md` and `.agents/`, and no other tool's at run time:
// other tools' files are onboarded once into Troupe's own. A session that starts in a
// workspace where that is due asks here, where the approval and question panels sit, the
// one place on the screen a person is waited on: one question for the lot, each file's
// diff a click away, a new `AGENTS.md` asked on its own (Decision 827), and after that the
// brief, when an older survey wrote it. The plan and the writing are the daemon's
// (`StartQuestions` in the client library); this draws them. Afterwards a line in the
// transcript says what was done, and where onboarding may not run, the daemon's sentence
// says why and nothing is asked.

import type { JSX } from "react";
import { describeItem, onboardingFiles } from "@troupe/client";
import type { OnboardingSuggested, StartAnswer, StartQuestion, StartState } from "@troupe/client";
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
      {/* The files and the diff scroll; the header and the answers stay on the screen. */}
      <div className="panel-body">
        <Body asking={asking} />
      </div>
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

/**
 * The start's `onboarding_suggested` in this app's words, from what the harness's
 * sentence was made of. The harness words it for a terminal (`troupe onboard`,
 * `/memory refresh`); here the panel under the transcript asks, so the line names the
 * panel's answers while the panel asks that question, and otherwise only says what is
 * due, naming nothing that is not on the screen. Null from a daemon that sent no
 * reasons or no count of the files, whose own sentence is then drawn instead.
 */
export function onboardingNote(o: OnboardingSuggested, asking: StartQuestion | null): string | null {
  if (o.reasons.length === 0) return null;
  const onboard = asking?.kind === "onboard";
  const sentences: string[] = [];
  for (const reason of o.reasons) {
    if (reason === "first") {
      const files = onboardingFiles(o);
      if (files === undefined) return null;
      sentences.push(
        onboard
          ? `Other tools' files are here: Onboard brings in ${files} as Troupe's own files, and Review shows each as a diff first. Nothing is written until you choose.`
          : `Other tools' files are here: onboarding would bring in ${files} as Troupe's own files.`,
      );
    } else if (reason === "outdated") {
      const was = o.onboardedVersion === undefined ? "older onboarding rules" : `version ${o.onboardedVersion} of the onboarding rules`;
      const now = o.onboardingVersion === undefined ? "" : `, and this build's are version ${o.onboardingVersion}`;
      sentences.push(`This workspace was onboarded under ${was}${now}${onboard ? ": Re-run shows what they would write now." : "."}`);
    } else if (reason === "brief") {
      const was = o.briefVersion === undefined ? "an older version" : `version ${o.briefVersion}`;
      const now = o.surveyVersion === undefined ? "" : `, and this build's is version ${o.surveyVersion}`;
      sentences.push(`The project brief was written by ${was} of the librarian's survey${now}${asking?.kind === "brief" ? ": Re-run has the librarian write it again." : "."}`);
    }
  }
  return sentences.length > 0 ? sentences.join(" ") : null;
}

/**
 * Why the start asks nothing, where onboarding may not run, or why it could not go on.
 * What it came to (what onboarding wrote, the librarian it started) is a line in the
 * transcript instead, where the terminal client writes it too (`Session.tsx`).
 */
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
  return null;
}
