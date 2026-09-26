// What every step of the first run shares: a heading and a sentence, the daemon's
// refusal when there is one, the buttons on and back, and the row of steps above it
// all so a person knows how much is left. Each step file holds only its question.

import type { JSX, ReactNode } from "react";
import type { SetupAnswer, SetupFlow, SetupStepName } from "@troupe/client";

export interface StepProps {
  flow: SetupFlow;
  busy: boolean;
  /** The daemon's refusal of the last answer, in one sentence. */
  error: string | null;
  onAnswer: (answer: SetupAnswer) => void;
  /** Back to the step before, or null on the first. */
  onBack: (() => void) | null;
}

const STEP_WORDS: Record<SetupStepName, string> = {
  where: "Where",
  provider: "Provider",
  key: "Key",
  models: "Models",
  workspace: "Project",
  finish: "First session",
};

/** The steps this path takes, with the one in hand marked. Read with the glyphs, not only the colour. */
export function Progress({ flow }: { flow: SetupFlow }): JSX.Element {
  return (
    <ol
      className="setup-steps micro"
      aria-label="Steps"
      style={{ display: "flex", flexWrap: "wrap", gap: "var(--space-3)", listStyle: "none", margin: 0, padding: 0 }}
    >
      {flow.steps.map((s) => {
        const current = s.name === flow.step;
        return (
          <li
            key={s.name}
            aria-current={current ? "step" : undefined}
            className={current ? "" : "muted"}
            style={{ fontWeight: current ? 800 : 400 }}
          >
            {s.done ? "✓ " : current ? "→ " : "· "}
            {STEP_WORDS[s.name]}
          </li>
        );
      })}
    </ol>
  );
}

export function StepFrame({
  flow,
  title,
  lede,
  error,
  children,
}: {
  flow: SetupFlow;
  title: string;
  lede: ReactNode;
  error: string | null;
  children: ReactNode;
}): JSX.Element {
  return (
    <section className="stack" style={{ gap: "var(--space-4)" }} aria-label={title}>
      <Progress flow={flow} />
      <header className="stack" style={{ gap: "var(--space-2)" }}>
        <h2>{title}</h2>
        <p className="copy" style={{ margin: 0, maxWidth: "var(--measure-reading)", color: "var(--text-secondary)" }}>
          {lede}
        </p>
      </header>
      {children}
      {error && (
        <div className="banner error" role="alert">
          <p>{error}</p>
        </div>
      )}
    </section>
  );
}

/** On, and back. The primary button says what pressing it does, never only "Next". */
export function Actions({
  busy,
  next,
  busyLabel,
  disabled,
  onNext,
  onBack,
  aside,
}: {
  busy: boolean;
  next: string;
  busyLabel?: string;
  disabled?: boolean;
  onNext: () => void;
  onBack: (() => void) | null;
  aside?: ReactNode;
}): JSX.Element {
  return (
    <div className="inline-form" style={{ marginBottom: 0, alignItems: "center", gap: "var(--space-4)" }}>
      <button type="button" className="primary" onClick={onNext} disabled={busy || disabled === true}>
        {busy ? (busyLabel ?? "Working…") : next}
      </button>
      {onBack && (
        <button type="button" className="link" onClick={onBack} disabled={busy}>
          Back
        </button>
      )}
      {aside}
    </div>
  );
}
