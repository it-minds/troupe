// Step 4: the main model and the small one, from what the provider listed, each with
// its context and its price. The daemon's suggestion is pressed already, so pressing
// Continue without reading is a safe answer.

import { useState } from "react";
import type { JSX } from "react";
import { describeCheck, describeOffer } from "@troupe/client";
import type { ModelOffer } from "@troupe/client";
import { Actions, StepFrame } from "./Step";
import type { StepProps } from "./Step";

export function PickModels({ flow, busy, error, onAnswer, onBack }: StepProps): JSX.Element {
  const earlier = flow.answers.models;
  const [main, setMain] = useState<string>((earlier?.["default"] as string | null) ?? flow.suggested.default ?? "");
  const [small, setSmall] = useState<string>((earlier?.["cheap"] as string | null) ?? flow.suggested.cheap ?? "");
  const offered = flow.offered;
  const unconfirmed = flow.check?.state === "unknown" ? describeCheck(flow.check) : null;

  return (
    <StepFrame
      flow={flow}
      title="Which models?"
      lede="The main model does the editing — usually the capable, expensive one. The small model explores, summarises and answers quick questions. Prices are per million tokens, in and out, where the provider says."
      error={error}
    >
      {unconfirmed && <p className="note">{unconfirmed}</p>}

      {offered.length > 0 ? (
        <>
          <div className="stack" style={{ gap: "var(--space-2)" }}>
            <h3>Main model</h3>
            <div className="options" role="radiogroup" aria-label="Main model">
              {offered.map((m) => (
                <OfferCard key={m.id} offer={m} pressed={main === m.id} suggested={flow.suggested.default === m.id} onPick={() => setMain(m.id)} />
              ))}
            </div>
          </div>

          <label>
            Small model <small>the same as the main model is fine</small>
            <select value={small} onChange={(e) => setSmall(e.target.value)} aria-label="Small model">
              {offered.map((m) => (
                <option key={m.id} value={m.id}>
                  {m.id}
                  {flow.suggested.cheap === m.id ? " · suggested" : ""}
                </option>
              ))}
            </select>
          </label>
        </>
      ) : (
        <>
          <label>
            Main model <small>the id the provider knows it by</small>
            <input value={main} onChange={(e) => setMain(e.target.value)} className="mono" spellCheck={false} aria-label="Main model" placeholder="a model id" />
          </label>
          <label>
            Small model <small>optional — the main model stands in</small>
            <input value={small} onChange={(e) => setSmall(e.target.value)} className="mono" spellCheck={false} aria-label="Small model" />
          </label>
        </>
      )}

      <Actions
        busy={busy}
        next="Save these models and continue"
        busyLabel="Saving…"
        disabled={main.trim() === ""}
        onBack={onBack}
        onNext={() => onAnswer({ default: main.trim(), cheap: small.trim() || null })}
      />
    </StepFrame>
  );
}

function OfferCard({ offer, pressed, suggested, onPick }: { offer: ModelOffer; pressed: boolean; suggested: boolean; onPick: () => void }): JSX.Element {
  const detail = describeOffer(offer);
  return (
    <button type="button" className="option" role="radio" aria-checked={pressed} aria-pressed={pressed} onClick={onPick}>
      <span className="label mono">
        {offer.id}
        {suggested && <span className="micro"> · suggested</span>}
      </span>
      <span className="consequence">{detail || "The provider said nothing about its size or price."}</span>
    </button>
  );
}
