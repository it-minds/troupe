// Which model a session on this computer talks to, and with what key.
//
// The daemon owns the file. A graphical client has no filesystem access by design, so
// everything here goes through `config.get`, `config.models` and `config.set` — the
// daemon reads and writes its own settings, and the client only ever holds a form.
//
// The rules a form has to get right live here rather than in a screen, because they are
// the kind a screen gets subtly wrong: an empty key field keeps the saved key rather
// than erasing it, a cleared base URL removes the override rather than saving an empty
// string, and a key is never read back — the daemon says whether one is set, not what
// it is. Keeping them pure is what lets a test say so without a browser.

import { TroupeRpcError } from "./connection.js";
import { ErrorCodes } from "./types.js";

export type ModelProvider = "anthropic" | "openai";
export type ModelAuth = "api_key" | "bearer";
export type ModelRole = "default" | "cheap" | "expensive";

/** The three roles, in the order a person reads them. */
export const MODEL_ROLES: readonly ModelRole[] = ["default", "cheap", "expensive"];

/** Where a request goes when no base URL is set, as each provider's own client defaults it. */
export const PROVIDER_DEFAULT_URLS: Record<ModelProvider, string> = {
  anthropic: "https://api.anthropic.com",
  openai: "https://api.openai.com/v1",
};

/** Something with a stronger claim than the file the panel edits. */
export interface ConfigOverride {
  source: "project" | "env" | "opencode";
  detail: string;
}

/** `config.get`, and what `config.set` answers with. */
export interface ModelConfig {
  config_dir: string;
  path: string;
  exists: boolean;
  provider: string | null;
  base_url: string | null;
  auth: ModelAuth | null;
  /** Whether a key is in effect. The key itself is never sent to a client. */
  api_key_set: boolean;
  api_key_source: "file" | "env" | "opencode" | null;
  models: Partial<Record<ModelRole, string | null>>;
  overrides: ConfigOverride[];
}

/** One model a provider offered. Every figure is null when the provider did not say. */
export interface ModelOffer {
  id: string;
  context: number | null;
  max_output: number | null;
  /** USD per million input tokens. */
  input: number | null;
  /** USD per million output tokens. */
  output: number | null;
}

export interface ModelDiscovery {
  models: ModelOffer[];
  failures: Array<{ provider: string; reason: string }>;
}

/** `config.models`. An omitted field falls back to what the daemon has saved. */
export interface ModelsParams {
  provider?: string;
  base_url?: string | null;
  api_key?: string;
  auth?: ModelAuth;
}

/**
 * `config.set`, less the command id the daemon client adds.
 *
 * `api_key` omitted keeps the saved key and `""` removes it; `base_url` null removes the
 * override; a role set to null removes that role.
 */
export interface ConfigSetParams {
  provider: string;
  base_url?: string | null;
  auth?: ModelAuth;
  api_key?: string;
  models?: Partial<Record<ModelRole, string | null>>;
}

/** The plane's `me.client_defaults`. Never a key: a plane does not hand those out. */
export interface ClientDefaults {
  configured: boolean;
  provider: string | null;
  base_url: string | null;
  auth: ModelAuth | null;
  models: Partial<Record<ModelRole, string | null>> | null;
}

/** What the panel holds while somebody edits it. Strings throughout, because inputs are. */
export interface ModelForm {
  provider: string;
  baseUrl: string;
  auth: ModelAuth;
  /** What has been typed into the key field. Empty means "keep what is saved". */
  apiKey: string;
  models: Record<ModelRole, string>;
}

type Rpc = <T>(method: string, params?: unknown) => Promise<T>;

/** Ask the plane what this organisation would have a client use. Any signed-in person may. */
export function clientDefaults(rpc: Rpc): Promise<ClientDefaults> {
  return rpc<ClientDefaults>("me.client_defaults", {});
}

/**
 * The form as the saved settings fill it.
 *
 * A daemon with nothing saved yet reports a null provider; the form starts on Anthropic
 * because a select has to show something, and saving is what makes it true.
 */
export function formFromConfig(config: ModelConfig): ModelForm {
  return {
    provider: config.provider ?? "anthropic",
    baseUrl: config.base_url ?? "",
    auth: config.auth ?? "api_key",
    apiKey: "",
    models: {
      default: config.models.default ?? "",
      cheap: config.models.cheap ?? "",
      expensive: config.models.expensive ?? "",
    },
  };
}

/**
 * What to send `config.set` for this form.
 *
 * Every field but the key is sent, because the form started from what was saved and so
 * an empty one is somebody having cleared it: an empty base URL or role is sent as null,
 * which removes it. The key is the exception — the field starts empty whether or not a
 * key is saved, so empty has to mean "leave it alone", and removing a key is its own
 * action (`removeKey`) that sends the empty string the daemon reads as "delete".
 */
export function configSetParams(form: ModelForm, opts: { removeKey?: boolean } = {}): ConfigSetParams {
  const key = form.apiKey.trim();
  return {
    provider: form.provider,
    base_url: form.baseUrl.trim() || null,
    auth: form.auth,
    ...(opts.removeKey ? { api_key: "" } : key ? { api_key: key } : {}),
    models: {
      default: form.models.default.trim() || null,
      cheap: form.models.cheap.trim() || null,
      expensive: form.models.expensive.trim() || null,
    },
  };
}

/**
 * What to send `config.models` for this form — the unsaved values, so a person can find
 * out whether a key works before keeping it. A key field left empty is omitted, and the
 * daemon tries the saved key.
 */
export function discoveryParams(form: ModelForm): ModelsParams {
  const key = form.apiKey.trim();
  return {
    provider: form.provider,
    base_url: form.baseUrl.trim() || null,
    auth: form.auth,
    ...(key ? { api_key: key } : {}),
  };
}

/**
 * The organisation's defaults laid over the form.
 *
 * A null from the plane means it has no opinion, and the form keeps what it had — with
 * one exception. When the provider changes, the base URL and any role the plane did not
 * name belonged to the old provider: a gateway address or a model id from one is
 * nonsense sent to the other, so those are cleared rather than kept. The key field is
 * never touched; the plane has no key to give.
 */
export function applyClientDefaults(form: ModelForm, defaults: ClientDefaults): ModelForm {
  if (!defaults.configured) return form;
  const switching = defaults.provider !== null && defaults.provider !== form.provider;
  const role = (r: ModelRole): string => defaults.models?.[r] ?? (switching ? "" : form.models[r]);
  return {
    provider: defaults.provider ?? form.provider,
    baseUrl: defaults.base_url ?? (switching ? "" : form.baseUrl),
    auth: defaults.auth ?? form.auth,
    apiKey: form.apiKey,
    models: { default: role("default"), cheap: role("cheap"), expensive: role("expensive") },
  };
}

/** One override, as the sentence a person reads. */
export function describeOverride(o: ConfigOverride): string {
  const who =
    o.source === "project"
      ? "a project's own settings"
      : o.source === "env"
        ? "an environment variable"
        : "OpenCode's settings";
  return `This is overridden by ${who}: ${o.detail}.`.replace(/\.\.$/, ".");
}

/** `200000` as `200k`, `1000000` as `1M`. Token counts are round numbers; say them that way. */
export function tokenCount(n: number): string {
  if (n >= 1_000_000) return `${+(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${+(n / 1_000).toFixed(1)}k`;
  return String(n);
}

function dollars(n: number): string {
  return `$${n < 1 ? n.toFixed(3).replace(/0$/, "") : n.toFixed(2)}`;
}

/**
 * What a model is, in one line: how much it reads and what it costs. Whatever the
 * provider did not report is left out rather than shown as zero — an unknown price is
 * not a free one.
 */
export function describeOffer(offer: ModelOffer): string {
  const parts: string[] = [];
  if (offer.context !== null) parts.push(`${tokenCount(offer.context)} tokens of context`);
  if (offer.input !== null && offer.output !== null) {
    parts.push(`${dollars(offer.input)} in, ${dollars(offer.output)} out per million tokens`);
  } else if (offer.input !== null) {
    parts.push(`${dollars(offer.input)} per million tokens in`);
  } else if (offer.output !== null) {
    parts.push(`${dollars(offer.output)} per million tokens out`);
  }
  return parts.join(" · ");
}

/**
 * A failed model-settings call, as the sentence to show.
 *
 * `method_not_found` is the one worth translating: it means the daemon predates these
 * methods, and "method not found" reads like a bug in this window rather than an old
 * program on the machine. `forbidden` names the scope, and anything else is already the
 * daemon's own words.
 */
export function modelConfigError(e: unknown): string {
  if (e instanceof TroupeRpcError) {
    if (e.code === ErrorCodes.method_not_found || e.message.includes("method_not_found")) {
      return "This daemon does not support model settings yet; update troupe-daemon.";
    }
    if (e.code === ErrorCodes.forbidden) {
      const scope = e.data?.["required_scope"];
      return `The daemon refused: this needs the ${typeof scope === "string" ? scope : "admin"} scope, which this connection does not have.`;
    }
  }
  return e instanceof Error ? e.message : String(e);
}
