// Step 1: this machine, or an organisation's plane. A plane is signed in to on the
// sign-in screen; here the choice is recorded and the address, if known, kept.
//
// The address is known from the answer given before, the plane the daemon is linked to,
// or the one this app last signed in to (the sign-in screen's own starting point).

import { useState } from "react";
import type { JSX } from "react";
import { likelyPlaneUrl, prefs } from "../../shell";
import { Actions, StepFrame } from "./Step";
import type { StepProps } from "./Step";

export function Where({ flow, busy, error, onAnswer, onBack }: StepProps): JSX.Element {
  const earlier = flow.answers.where;
  const [choice, setChoice] = useState<"local" | "plane">(earlier?.["choice"] === "plane" ? "plane" : "local");
  const [planeUrl, setPlaneUrl] = useState<string>(
    () => (earlier?.["plane_url"] as string | null) ?? flow.detected.plane.url ?? prefs.get("planeUrl", likelyPlaneUrl()),
  );

  return (
    <StepFrame
      flow={flow}
      title="Where does the work run?"
      lede="A session is one piece of work handed to the troupe. It can run here, with a model you hold the key to, or on your organisation's Troupe."
      error={error}
    >
      <div className="options">
        <button type="button" className="option" aria-pressed={choice === "local"} onClick={() => setChoice("local")}>
          <span className="label">Use my own machine and keys</span>
          <span className="consequence">
            Sessions run in the daemon on this computer, against a model provider you give it a key for. The one thing that leaves the
            machine is the call to that provider.
          </span>
        </button>
        <button type="button" className="option" aria-pressed={choice === "plane"} onClick={() => setChoice("plane")}>
          <span className="label">Sign in to my organisation&apos;s Troupe</span>
          <span className="consequence">
            Your team&apos;s plane runs the sessions and provides the models. You sign in where you always do, and Troupe never holds a
            password of its own.
          </span>
        </button>
      </div>

      {choice === "plane" && (
        <label>
          The plane&apos;s address <small>optional — the sign-in screen asks too</small>
          <input
            value={planeUrl}
            onChange={(e) => setPlaneUrl(e.target.value)}
            placeholder="https://troupe.example"
            inputMode="url"
            spellCheck={false}
            aria-label="The plane's address"
          />
        </label>
      )}

      <Actions
        busy={busy}
        next="Continue"
        onBack={onBack}
        onNext={() => onAnswer(choice === "local" ? { choice: "local" } : { choice: "plane", ...(planeUrl.trim() ? { plane_url: planeUrl.trim() } : {}) })}
      />
    </StepFrame>
  );
}
