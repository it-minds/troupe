// Step 2: the provider. What is already on the machine comes first — a vendor's key in
// the environment, an opencode setup, a config.yaml that works — because the shortest
// first run is the one that reuses what a person already did.

import { useState } from "react";
import type { JSX } from "react";
import { PROVIDER_KINDS } from "@troupe/client";
import type { ProviderKind, SetupAnswer } from "@troupe/client";
import { Actions, StepFrame } from "./Step";
import type { StepProps } from "./Step";

interface Card {
  id: string;
  label: string;
  consequence: string;
  answer: SetupAnswer;
  /** The card asks for an address, sent as `base_url`. */
  url: boolean;
}

const VENDOR_OF: Record<string, ProviderKind> = {
  ANTHROPIC_API_KEY: PROVIDER_KINDS.find((k) => k.id === "anthropic")!,
  OPENAI_API_KEY: PROVIDER_KINDS.find((k) => k.id === "openai")!,
};

export function Provider({ flow, busy, error, onAnswer, onBack }: StepProps): JSX.Element {
  const earlier = flow.answers.provider;
  const detected = flow.detected;

  const already: Card[] = [
    ...detected.env
      .filter((v) => v in VENDOR_OF)
      .map((v) => ({
        id: `env:${v}`,
        label: `${v} is set on this computer`,
        consequence: `Use ${VENDOR_OF[v]!.label} with that key. It stays in the environment; the settings only refer to it.`,
        answer: { provider: VENDOR_OF[v]!.provider, kind: VENDOR_OF[v]!.id, base_url: null },
        url: false,
      })),
    ...(detected.opencode.providers.length > 0
      ? [
          {
            id: "opencode",
            label: `opencode is set up here, with ${detected.opencode.providers.join(", ")}`,
            consequence: `Copy its providers into Troupe's settings, keys as opencode has them written${detected.opencode.default ? `, and start from ${detected.opencode.default}` : ""}.`,
            answer: { reuse: "opencode" },
            url: false,
          },
        ]
      : []),
    ...(detected.config.usable
      ? [
          {
            id: "config",
            label: `A working config.yaml${detected.config.provider ? ` (${detected.config.provider})` : ""}`,
            consequence: `Keep ${detected.config.path} as it is and go straight to the first project.`,
            answer: { reuse: "config" },
            url: false,
          },
        ]
      : []),
  ];
  const kinds: Card[] = PROVIDER_KINDS.map((k) => ({
    id: k.id,
    label: k.label,
    consequence: k.consequence,
    answer: { provider: k.provider, kind: k.id },
    url: k.url,
  }));
  const cards = [...already, ...kinds];

  const [pickId, setPickId] = useState<string>(() => {
    if (earlier?.["reuse"] === "opencode" || earlier?.["reuse"] === "config") return earlier["reuse"];
    if (typeof earlier?.["kind"] === "string") return earlier["kind"];
    return already[0]?.id ?? "anthropic";
  });
  const [baseUrl, setBaseUrl] = useState<string>((earlier?.["base_url"] as string | null) ?? "");
  const picked = cards.find((c) => c.id === pickId) ?? kinds[0]!;

  const options = (list: Card[]): JSX.Element => (
    <div className="options">
      {list.map((c) => (
        <button key={c.id} type="button" className="option" aria-pressed={pickId === c.id} onClick={() => setPickId(c.id)}>
          <span className="label">{c.label}</span>
          <span className="consequence">{c.consequence}</span>
        </button>
      ))}
    </div>
  );

  return (
    <StepFrame
      flow={flow}
      title="Which model provider?"
      lede="The provider is who answers the agent. A gateway is a provider too: anything that speaks the OpenAI chat API at an address of yours."
      error={error}
    >
      {already.length > 0 && (
        <div className="stack" style={{ gap: "var(--space-2)" }}>
          <h3>Already on this computer</h3>
          {options(already)}
        </div>
      )}

      <div className="stack" style={{ gap: "var(--space-2)" }}>
        {already.length > 0 && <h3>Or set one up</h3>}
        {options(kinds)}
      </div>

      {picked.url && (
        <label>
          Address <small>ending in /v1, as the gateway&apos;s own documentation writes it</small>
          <input
            value={baseUrl}
            onChange={(e) => setBaseUrl(e.target.value)}
            placeholder="https://llm-gw.example/v1"
            inputMode="url"
            spellCheck={false}
            aria-label="Address"
          />
        </label>
      )}

      <Actions
        busy={busy}
        next="Continue"
        busyLabel={"reuse" in picked.answer ? "Copying…" : "Working…"}
        disabled={picked.url && baseUrl.trim() === ""}
        onBack={onBack}
        onNext={() => onAnswer(picked.url ? { ...picked.answer, base_url: baseUrl.trim() } : picked.answer)}
      />
    </StepFrame>
  );
}
