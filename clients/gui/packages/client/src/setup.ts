// The first run's questions, as the daemon asks them (troupe Decision 705).
//
// The daemon holds the flow and decides what each answer means; this is the shape of
// what it says (`setup.get`, and what `setup.answer` answers with), the words a screen
// puts on each choice, and the rules a screen would otherwise get subtly wrong — which
// provider a card means, what a check's state says to a person, what an old daemon's
// refusal means. Keeping them here is what lets a test say so without a browser.

import { TroupeRpcError } from "./connection.js";
import type { ModelOffer, ModelRole } from "./config.js";
import { ErrorCodes } from "./types.js";

export type SetupStepName = "where" | "provider" | "key" | "models" | "workspace" | "daemon" | "finish";

export interface SetupStep {
  name: SetupStepName;
  done: boolean;
}

/** What the daemon found when it tried the key: the provider's own answer, in a word. */
export interface SetupCheck {
  state: "ok" | "refused" | "unknown";
  reason: string | null;
}

export interface SetupCompleted {
  completed_at: string;
  choice: string;
  subject: string | null;
}

/** What is already on the machine, for the questions to offer. Names of variables, never values. */
export interface SetupDetected {
  env: string[];
  opencode: { path: string; providers: string[]; default: string | null };
  config: {
    exists: boolean;
    path: string;
    provider: string | null;
    base_url: string | null;
    api_key_set: boolean;
    api_key_source: string | null;
    models: Partial<Record<ModelRole, string | null>>;
    usable: boolean;
  };
  plane: { url: string | null; linked: boolean };
}

/**
 * Whether the daemon starts when this user logs in (troupe Decision 762): the platform's
 * kind of login entry, its file, and the `troupe-daemon` it starts — null when there is
 * none on this computer to start.
 */
export interface SetupDaemon {
  at_login: boolean;
  kind: "startup_folder" | "launch_agent" | "systemd" | "autostart";
  path: string;
  command: string | null;
}

/** The session `finish` started, or why it could not. */
export interface SetupSession {
  workspace: string;
  prompt: string;
  session_id?: string;
  error?: string;
}

/** `setup.get`, and what `setup.answer` answers with. */
export interface SetupFlow {
  needed: boolean;
  completed: SetupCompleted | null;
  step: SetupStepName | "done";
  steps: SetupStep[];
  answers: Partial<Record<SetupStepName, Record<string, unknown>>>;
  detected: SetupDetected;
  key_storage: { kind: "file"; path: string; keychain: boolean };
  offered: ModelOffer[];
  suggested: { default: string | null; cheap: string | null };
  check: SetupCheck | null;
  suggested_prompt: string | null;
  /** Absent from a daemon from before the `daemon` step. */
  daemon?: SetupDaemon;
  session: SetupSession | null;
}

/** One step's answer; the step decides the fields (PROTOCOL.md, `setup.answer`). */
export type SetupAnswer = Record<string, unknown>;

/** A provider as a card names it: what the daemon is told, and what it means for the reader. */
export interface ProviderKind {
  id: "anthropic" | "openai" | "gateway" | "litellm";
  provider: "anthropic" | "openai";
  label: string;
  consequence: string;
  /** Whether the card asks for a base URL. */
  url: boolean;
}

export const PROVIDER_KINDS: readonly ProviderKind[] = [
  {
    id: "anthropic",
    provider: "anthropic",
    label: "Anthropic",
    consequence: "Claude, at Anthropic's own endpoint, with a key from console.anthropic.com.",
    url: false,
  },
  {
    id: "openai",
    provider: "openai",
    label: "OpenAI",
    consequence: "GPT, at OpenAI's own endpoint, with a key from platform.openai.com.",
    url: false,
  },
  {
    id: "gateway",
    provider: "openai",
    label: "An OpenAI-compatible gateway",
    consequence: "Anything speaking Chat Completions at a URL of yours: vLLM, OpenRouter, a company gateway. Some want no key.",
    url: true,
  },
  {
    id: "litellm",
    provider: "openai",
    label: "A LiteLLM proxy",
    consequence: "A LiteLLM proxy at its URL. The one gateway that says what each model costs.",
    url: true,
  },
];

/** The approval model, as the daemon states it: two sentences each, the safe default first. */
export const APPROVAL_CHOICES: readonly { id: "ask" | "auto"; label: string; consequence: string }[] = [
  {
    id: "ask",
    label: "Ask me first",
    consequence:
      "The agent reads freely, and asks before it writes a file or runs a command. You allow once, allow for the session, or deny, and nothing changes on disk until you say so.",
  },
  {
    id: "auto",
    label: "Run everything without asking",
    consequence:
      "Every write and every command runs as soon as the agent asks for it. For a directory whose changes you can afford to throw away, and never for one you cannot.",
  },
];

/** The vendor's own variable for a provider at its own endpoint, which the key step may offer. */
export function vendorKeyVar(provider: string, baseUrl: string | null | undefined): string | null {
  if (baseUrl && baseUrl.trim() !== "") return null;
  if (provider === "anthropic") return "ANTHROPIC_API_KEY";
  if (provider === "openai") return "OPENAI_API_KEY";
  return null;
}

/** What a check said, as the sentence to show. */
export function describeCheck(check: SetupCheck | null): string | null {
  if (!check) return null;
  if (check.state === "ok") return "The provider accepted the key.";
  if (check.state === "refused") return `The provider refused the key: ${check.reason ?? "no reason given"}. Check it and try again.`;
  return `The key could not be confirmed: ${check.reason ?? "the provider did not answer"}. You can go on and type a model id.`;
}

/** The step after `step` on this flow's path, or null at the end. */
export function nextStep(flow: Pick<SetupFlow, "steps">, step: SetupStepName): SetupStepName | null {
  const at = flow.steps.findIndex((s) => s.name === step);
  return at >= 0 && at + 1 < flow.steps.length ? flow.steps[at + 1]!.name : null;
}

/** The step before `step` on this flow's path, or null at the start. */
export function previousStep(flow: Pick<SetupFlow, "steps">, step: SetupStepName): SetupStepName | null {
  const at = flow.steps.findIndex((s) => s.name === step);
  return at > 0 ? flow.steps[at - 1]!.name : null;
}

/** Whether a daemon predates the first run's questions: it answers `method_not_found`. */
export function setupUnsupported(e: unknown): boolean {
  return e instanceof TroupeRpcError && (e.code === ErrorCodes.method_not_found || e.message.includes("method_not_found"));
}

/**
 * A failed setup call, as the sentence to show. The daemon's `invalid_params` carries
 * the reason in one sentence, which is the thing to say; an old daemon is named as such.
 */
export function setupError(e: unknown): string {
  if (setupUnsupported(e)) return "This daemon does not know the first run's questions yet; update troupe-daemon.";
  if (e instanceof TroupeRpcError) {
    const reason = e.data?.["reason"];
    if (typeof reason === "string") return reason;
  }
  return e instanceof Error ? e.message : String(e);
}
