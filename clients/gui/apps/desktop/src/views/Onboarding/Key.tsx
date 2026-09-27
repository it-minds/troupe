// Step 3: the key. Pasted, or kept in the environment; checked by the daemon with a
// real request before anything is written, and never shown back. There is no keychain
// in this build, and the screen says where the key goes rather than implying one.

import { useState } from "react";
import type { JSX } from "react";
import { describeCheck, vendorKeyVar } from "@troupe/client";
import { Actions, StepFrame } from "./Step";
import type { StepProps } from "./Step";

type Source = "env" | "typed" | "none";

export function Key({ flow, busy, error, onAnswer, onBack }: StepProps): JSX.Element {
  const provider = flow.answers.provider ?? {};
  const providerName = String(provider["provider"] ?? "anthropic");
  const baseUrl = (provider["base_url"] as string | null) ?? null;
  const vendorVar = vendorKeyVar(providerName, baseUrl);
  const inEnv = vendorVar !== null && flow.detected.env.includes(vendorVar);
  // A vendor wants a key; a gateway may not, and only a gateway is offered "none".
  const gateway = baseUrl !== null && vendorVar === null;
  const [source, setSource] = useState<Source>(inEnv ? "env" : "typed");
  const [key, setKey] = useState("");
  const refused = flow.check?.state === "refused";
  const label = providerName === "anthropic" ? "Anthropic" : providerName === "openai" && !gateway ? "OpenAI" : "the gateway";

  return (
    <StepFrame
      flow={flow}
      title="The key"
      lede={
        <>
          It is tried once, with a real request to {label}, before anything is kept. It goes into{" "}
          <code className="mono">{flow.key_storage.path}</code> on this computer, readable by you alone — there is no keychain in this
          build — and it is never shown back.
        </>
      }
      error={error}
    >
      {(inEnv || gateway) && (
        <div className="options">
          {inEnv && (
            <button type="button" className="option" aria-pressed={source === "env"} onClick={() => setSource("env")}>
              <span className="label">Keep it in {vendorVar}</span>
              <span className="consequence">The settings refer to the variable and never hold the key. Set it wherever the daemon starts.</span>
            </button>
          )}
          <button type="button" className="option" aria-pressed={source === "typed"} onClick={() => setSource("typed")}>
            <span className="label">Paste it</span>
            <span className="consequence">Saved into the settings file, and sent only to {label}.</span>
          </button>
          {gateway && (
            <button type="button" className="option" aria-pressed={source === "none"} onClick={() => setSource("none")}>
              <span className="label">This gateway needs no key</span>
              <span className="consequence">Nothing is sent. A gateway on your own machine or network often wants none.</span>
            </button>
          )}
        </div>
      )}

      {source === "typed" && (
        <label>
          API key
          <input
            type="password"
            value={key}
            onChange={(e) => setKey(e.target.value)}
            placeholder="Paste your key"
            autoComplete="off"
            spellCheck={false}
            aria-label="API key"
            aria-invalid={refused ? true : undefined}
          />
        </label>
      )}

      {refused && (
        <div className="banner error" role="alert">
          <p>{describeCheck(flow.check)}</p>
        </div>
      )}

      <Actions
        busy={busy}
        next="Check the key and continue"
        busyLabel={`Asking ${label}…`}
        disabled={source === "typed" && key.trim() === ""}
        onBack={onBack}
        onNext={() => onAnswer(source === "env" ? { env: vendorVar } : source === "typed" ? { api_key: key.trim() } : {})}
      />
    </StepFrame>
  );
}
