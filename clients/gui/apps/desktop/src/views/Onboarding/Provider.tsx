// Step 2: the provider. What is already on the machine comes first — a vendor's key in
// the environment, an opencode setup, a config.yaml that works — because the shortest
// first run is the one that reuses what a person already did. Then every way the daemon
// says a provider may be set up (troupe #658), each asking for an address only where it
// needs one: a gateway's or an Azure resource's, which has none of its own, or an Ollama
// server's, whose default an empty field takes.

import { useState } from "react";
import type { JSX } from "react";
import { asksAddress, setupKinds } from "@troupe/client";
import type { SetupAnswer, SetupKind } from "@troupe/client";
import { Actions, StepFrame } from "./Step";
import type { StepProps } from "./Step";

interface Card {
  id: string;
  label: string;
  consequence: string;
  answer: SetupAnswer;
  /** The kind whose address the card asks for, sent as `base_url`; none for a card that asks none. */
  address: SetupKind | null;
}

export function Provider({ flow, busy, error, onAnswer, onBack }: StepProps): JSX.Element {
  const earlier = flow.answers.provider;
  const detected = flow.detected;
  const kinds = setupKinds(flow);

  const already: Card[] = [
    ...kinds
      .filter((k) => k.key_var !== null && detected.env.includes(k.key_var))
      .map((k) => ({
        id: `env:${k.key_var!}`,
        label: `${k.key_var!} is set on this computer`,
        consequence: `Use ${k.label} with that key. It stays in the environment; the settings only refer to it.`,
        answer: { provider: k.provider, kind: k.id, base_url: null },
        address: null,
      })),
    ...(detected.opencode.providers.length > 0
      ? [
          {
            id: "opencode",
            label: `opencode is set up here, with ${detected.opencode.providers.join(", ")}`,
            consequence: `Copy its providers into Troupe's settings, keys as opencode has them written${detected.opencode.default ? `, and start from ${detected.opencode.default}` : ""}.`,
            answer: { reuse: "opencode" },
            address: null,
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
            address: null,
          },
        ]
      : []),
  ];
  const offered: Card[] = kinds.map((k) => ({
    id: k.id,
    label: k.label,
    consequence: k.summary,
    answer: { provider: k.provider, kind: k.id },
    address: asksAddress(k).asked ? k : null,
  }));
  const cards = [...already, ...offered];

  const [pickId, setPickId] = useState<string>(() => {
    if (earlier?.["reuse"] === "opencode" || earlier?.["reuse"] === "config") return earlier["reuse"];
    if (typeof earlier?.["kind"] === "string") return earlier["kind"];
    return already[0]?.id ?? offered[0]?.id ?? "anthropic";
  });
  const [baseUrl, setBaseUrl] = useState<string>((earlier?.["base_url"] as string | null) ?? "");
  const picked = cards.find((c) => c.id === pickId) ?? offered[0]!;
  const address = picked.address;
  const required = address !== null && asksAddress(address).required;

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
        {options(offered)}
      </div>

      {address && (
        <label>
          Address{" "}
          <small>
            {required
              ? `as its own documentation writes it, such as ${address.url_example ?? "https://…"}`
              : `leave empty for ${address.default_url ?? "its own"}`}
          </small>
          <input
            value={baseUrl}
            onChange={(e) => setBaseUrl(e.target.value)}
            placeholder={address.url_example ?? address.default_url ?? "https://…"}
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
        disabled={required && baseUrl.trim() === ""}
        onBack={onBack}
        onNext={() => onAnswer(address ? { ...picked.answer, base_url: baseUrl.trim() || null } : picked.answer)}
      />
    </StepFrame>
  );
}
