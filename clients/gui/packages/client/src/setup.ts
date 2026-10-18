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

/**
 * One way a provider may be set up, as the daemon says (troupe #658): every provider type
 * a person may pick, from the one list of them, then a gateway and a LiteLLM proxy. `id` is
 * the `kind` the provider step is answered with and `provider` what is written; `url` and
 * `key` say what it asks. An address is asked where it is `required` (a gateway, Azure's
 * resource) or `server` (Ollama's, with `default_url` offered); a key unless it is `none`,
 * and `optional` lets a gateway go without.
 */
export interface SetupKind {
  id: string;
  provider: string;
  label: string;
  summary: string;
  url: "own" | "server" | "required" | "none";
  default_url: string | null;
  url_example: string | null;
  key: "required" | "optional" | "none";
  key_var: string | null;
}

/** `setup.get`, and what `setup.answer` answers with. */
export interface SetupFlow {
  needed: boolean;
  completed: SetupCompleted | null;
  step: SetupStepName | "done";
  steps: SetupStep[];
  answers: Partial<Record<SetupStepName, Record<string, unknown>>>;
  detected: SetupDetected;
  /** Absent from a daemon from before the provider types were its to say. */
  kinds?: SetupKind[];
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

/**
 * What a daemon from before the provider types were its to say takes, which it does not
 * list: Anthropic, OpenAI and the two ways to a gateway. A newer daemon's `kinds` replace
 * these; offering one of today's types to an older daemon would only be refused.
 */
export const OLDER_DAEMON_KINDS: readonly SetupKind[] = [
  {
    id: "anthropic",
    provider: "anthropic",
    label: "Anthropic",
    summary: "Claude, at Anthropic's own endpoint, with a key from console.anthropic.com.",
    url: "own",
    default_url: "https://api.anthropic.com",
    url_example: null,
    key: "required",
    key_var: "ANTHROPIC_API_KEY",
  },
  {
    id: "openai",
    provider: "openai",
    label: "OpenAI",
    summary: "GPT, at OpenAI's own endpoint, with a key from platform.openai.com.",
    url: "own",
    default_url: "https://api.openai.com",
    url_example: null,
    key: "required",
    key_var: "OPENAI_API_KEY",
  },
  {
    id: "gateway",
    provider: "openai",
    label: "An OpenAI-compatible gateway",
    summary: "Anything speaking Chat Completions at a URL of yours: vLLM, OpenRouter, a company gateway. Some want no key.",
    url: "required",
    default_url: null,
    url_example: "https://llm-gw.example/v1",
    key: "optional",
    key_var: null,
  },
  {
    id: "litellm",
    provider: "openai",
    label: "A LiteLLM proxy",
    summary: "A LiteLLM proxy at its URL. The one gateway that says what each model costs.",
    url: "required",
    default_url: null,
    url_example: "https://llm-gw.example/v1",
    key: "optional",
    key_var: null,
  },
];

/** The ways this flow's daemon says a provider may be set up, in its order. */
export function setupKinds(flow: Pick<SetupFlow, "kinds">): readonly SetupKind[] {
  return flow.kinds && flow.kinds.length > 0 ? flow.kinds : OLDER_DAEMON_KINDS;
}

/** The kind the provider step was answered with, if the flow has one. */
export function answeredKind(flow: Pick<SetupFlow, "kinds" | "answers">): SetupKind | undefined {
  const id = flow.answers.provider?.["kind"];
  return setupKinds(flow).find((k) => k.id === id);
}

/** Whether a kind asks for an address, and whether it may be left empty (a server's default). */
export function asksAddress(kind: SetupKind): { asked: boolean; required: boolean } {
  return { asked: kind.url === "required" || kind.url === "server", required: kind.url === "required" };
}

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

/**
 * The vendor's own variable for a kind at its own endpoint, which the key step may offer:
 * a key in it is sent to the vendor alone, so a provider at an address of the person's
 * is offered none.
 */
export function vendorKeyVar(kind: SetupKind | undefined, baseUrl: string | null | undefined): string | null {
  if (!kind || (baseUrl && baseUrl.trim() !== "")) return null;
  return kind.key_var;
}

/**
 * What a check said, as the sentence to show. A provider that takes no key was asked for
 * its models with none, so what failed is the listing, not a key.
 */
export function describeCheck(check: SetupCheck | null, opts: { keyless?: boolean } = {}): string | null {
  if (!check) return null;
  if (opts.keyless && check.state === "ok") return "It answered with the models it has.";
  if (opts.keyless && check.state === "unknown") {
    return `Its models could not be listed: ${check.reason ?? "it did not answer"}. You can go on and type a model id.`;
  }
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

/**
 * Whether the daemon finished a run since it said `before`: a record newer than the one it
 * had then, or a first run it no longer wants. What a screen goes by when an answer to
 * `finish` never reached it, or the socket went and came back: the daemon's record is
 * the truth about a run, whichever reply carried it.
 */
export function setupFinishedSince(before: Pick<SetupFlow, "needed" | "completed">, now: Pick<SetupFlow, "needed" | "completed">): boolean {
  if (now.completed && now.completed.completed_at !== before.completed?.completed_at) return true;
  return before.needed && !now.needed;
}

/**
 * The finished flow a lost `finish` answer would have carried, from what the person
 * answered (`before`) and what the daemon says now. The session a local run asked for is
 * not known, so it is none; a run that the record says chose a plane and that never named
 * one here ends at the sign-in form.
 */
export function finishedFlow(before: SetupFlow, now: SetupFlow): SetupFlow {
  const answers = { ...before.answers };
  if (!answers.where && now.completed?.choice === "plane") answers.where = { choice: "plane", plane_url: null };
  return { ...now, step: "done", answers, session: null };
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
