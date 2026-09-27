// Step 7: what was set up, in a few lines, and the first session — started by the
// daemon in the chosen directory with a prompt suited to it. A plane's first run ends
// on the sign-in screen instead, since signing in is not the daemon's to do; with the
// plane's address given, that screen signs in to it without asking for it again.

import { useState } from "react";
import type { JSX } from "react";
import { PROVIDER_KINDS } from "@troupe/client";
import { Actions, StepFrame } from "./Step";
import type { StepProps } from "./Step";

/** A provider as the card the person pressed named it: a gateway is not "openai" to them. */
function providerWords(provider: Record<string, unknown> | undefined): string {
  if (provider?.["reuse"] === "opencode") return "opencode's providers, copied in";
  if (provider?.["reuse"] === "config") return "the config.yaml that was already here";
  const kind = PROVIDER_KINDS.find((k) => k.id === provider?.["kind"]);
  const name = kind?.label ?? String(provider?.["provider"] ?? "");
  return provider?.["base_url"] ? `${name} at ${String(provider["base_url"])}` : name;
}

export function Finish({ flow, busy, error, onAnswer, onBack }: StepProps): JSX.Element {
  const plane = flow.answers.where?.["choice"] === "plane";
  const [prompt, setPrompt] = useState<string>(flow.suggested_prompt ?? "");
  const provider = flow.answers.provider;
  const models = flow.answers.models;
  const workspace = flow.answers.workspace;
  const key = flow.answers.key;

  if (plane) {
    const url = (flow.answers.where?.["plane_url"] as string | null) ?? null;
    return (
      <StepFrame
        flow={flow}
        title="Sign in next"
        lede={
          url
            ? "Nothing is written on this computer for a plane: your organisation's Troupe provides the models and runs the sessions. Finishing here signs you in to it."
            : "Nothing is written on this computer for a plane: your organisation's Troupe provides the models and runs the sessions. Finishing here takes you to the sign-in screen."
        }
        error={error}
      >
        <dl className="facts wide">
          <dt>Plane</dt>
          <dd className="mono micro">{url ?? "the address the sign-in screen asks for"}</dd>
        </dl>
        <Actions busy={busy} next="Finish and sign in" busyLabel="Finishing…" onBack={onBack} onNext={() => onAnswer({})} />
      </StepFrame>
    );
  }

  return (
    <StepFrame
      flow={flow}
      title="Ready"
      lede="Everything below is saved. The first session starts in your project with the prompt you give it; change the prompt, or leave it."
      error={error}
    >
      <dl className="facts wide">
        <dt>Provider</dt>
        <dd>{providerWords(provider)}</dd>
        {models && (
          <>
            <dt>Models</dt>
            <dd className="mono micro">
              {String(models["default"])}
              {models["cheap"] && models["cheap"] !== models["default"] ? ` · ${String(models["cheap"])} for small work` : ""}
            </dd>
          </>
        )}
        {key && (
          <>
            <dt>Key</dt>
            <dd>
              {key["source"] === "env"
                ? `read from ${String(key["var"])}`
                : key["source"] === "typed"
                  ? `saved in ${flow.key_storage.path}`
                  : "none; the gateway wants none"}
            </dd>
          </>
        )}
        <dt>Project</dt>
        <dd className="mono micro">{String(workspace?.["workspace"] ?? "")}</dd>
        <dt>Approvals</dt>
        <dd>{workspace?.["approvals"] === "auto" ? "every call runs without asking" : "the agent asks before it writes or runs anything"}</dd>
      </dl>

      <label>
        What to ask first
        <textarea value={prompt} onChange={(e) => setPrompt(e.target.value)} rows={3} aria-label="What to ask first" />
      </label>

      <Actions
        busy={busy}
        next="Start the first session"
        busyLabel="Starting…"
        onBack={onBack}
        onNext={() => onAnswer({ start: true, ...(prompt.trim() ? { prompt: prompt.trim() } : {}) })}
        aside={
          <button type="button" className="link" onClick={() => onAnswer({ start: false })} disabled={busy}>
            Finish without starting one
          </button>
        }
      />
    </StepFrame>
  );
}
