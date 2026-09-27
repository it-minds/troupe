// A fresh machine's first run: how Troupe looks, then the daemon's questions, ending on
// the session list with the first session started (troupe Decision 705). The theme
// comes first because it is the one question with no wrong answer, and it is
// pre-answered; everything after it is the daemon's flow, one screen per step.

import { useState } from "react";
import type { JSX } from "react";
import type { DaemonClient } from "@troupe/client";
import { DEFAULT_MODE, DEFAULT_THEME, THEMES } from "../../theme";
import { ModeChoice, ThemeCards } from "../Appearance";
import type { Appearance } from "../Appearance";
import { SetupSteps } from "./Setup";
import type { SetupOutcome } from "./Setup";

export function FirstRun({
  client,
  appearance,
  onDone,
}: {
  client: DaemonClient;
  appearance: Appearance;
  onDone: (outcome: SetupOutcome) => void;
}): JSX.Element {
  const [stage, setStage] = useState<"appearance" | "setup">("appearance");

  return (
    <main className="onboarding" aria-label="First run">
      <header>
        <h1>Welcome.</h1>
        <p>
          {stage === "appearance"
            ? "Pick how Troupe looks. Every theme says the same things in the same places — one colour is reserved, in each of them, for work that has stopped and needs you. You can change this any time in Appearance."
            : "A few questions, and the first session starts. Everything is written to this computer's own settings; Setup in the rail asks them again whenever you like."}
        </p>
      </header>

      {stage === "appearance" ? (
        <>
          <div className="chooser">
            <section>
              <h2>Theme</h2>
              <ThemeCards theme={appearance.theme} resolved={appearance.resolved} setTheme={appearance.setTheme} />
            </section>
            <section className="mode">
              <h2>Light or dark</h2>
              <ModeChoice mode={appearance.mode} setMode={appearance.setMode} />
            </section>
          </div>
          <footer>
            <button className="continue" onClick={() => setStage("setup")}>
              Continue
            </button>
            <button
              className="link"
              onClick={() => {
                appearance.setTheme(DEFAULT_THEME);
                appearance.setMode(DEFAULT_MODE);
                setStage("setup");
              }}
            >
              Skip — {THEMES[0]!.name}, following my system
            </button>
          </footer>
        </>
      ) : (
        <SetupSteps client={client} onDone={onDone} />
      )}
    </main>
  );
}
