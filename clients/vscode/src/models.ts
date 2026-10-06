// The side bar's Models: what `troupe models --json` says the folder's configuration can
// address, as rows. Each model with its window and price and where they came from, the
// default, cheap and expensive ones marked, and one its provider does not serve said so.
//
// Troupe builds the list (Decision 783) from its config and the cache of what each provider
// listed; the panel reads neither. `troupe models` asks the providers again itself when
// that cache is stale (a day old, or not from the providers the config names), and every
// time with `--refresh`, which only the group's own button passes (Decision 794). A key is never in it: `key` says whether one is set.

import type { Row } from "./settings.js";

export interface Model {
  id: string;
  provider: string | null;
  model: string | null;
  context: number | null;
  input: number | null;
  output: number | null;
  price_source: string | null;
  source: string | null;
  key: boolean;
  served: boolean | null;
  nearest: string[];
}

interface Source {
  provider: string | null;
  type: string;
  url: string | null;
  models: number;
  fetched_at: string | null;
  status: string;
  error: string | null;
  failed_at: string | null;
}

export interface Models {
  models: Model[];
  roles: Partial<Record<Role, string>>;
  catalog: { path: string; fetched_at: string | null; sources: Source[] } | null;
}

type Role = "default" | "cheap" | "expensive";
const ROLES: Role[] = ["default", "cheap", "expensive"];

/** The group's `contextValue`: the button that asks the providers again is on it. */
export const MODELS_CONTEXT = "troupe.models";

// Past this many, the group starts folded, so a gateway's long list does not push the
// rest of the settings out of sight.
const UNFOLDED = 20;

/** What the command printed, or an error that says it was not that. */
export function parseModels(text: string): Models {
  const json: unknown = JSON.parse(text);
  const o = json as Partial<Models> | null;

  if (o === null || typeof o !== "object" || !Array.isArray(o.models) || o.roles === null || typeof o.roles !== "object")
    throw new Error("troupe models --json printed something other than models");

  return {
    models: o.models.map((m) => ({ ...m, nearest: Array.isArray(m.nearest) ? m.nearest : [] })),
    roles: o.roles,
    catalog: o.catalog && Array.isArray(o.catalog.sources) ? o.catalog : null,
  };
}

/** The Models group. `now` is when it is read, for "fetched 2 hours ago". */
export function modelsGroup(m: Models, now: Date): Row {
  const sessionType = m.catalog?.sources.find((s) => s.provider === null)?.type;
  const lists = (m.catalog?.sources ?? []).map((s) => sourceRow(s, now));
  const models = m.models.map((model) => modelRow(model, m.roles, sessionType, now, m.catalog));
  const count = m.models.length === 1 ? "1 model" : `${m.models.length} models`;

  return {
    label: "Models",
    description: m.catalog?.fetched_at ? `${count} · listed ${ago(m.catalog.fetched_at, now)}` : count,
    tooltip: [
      "What `troupe models` says this folder's configuration can address: each model's window and price, and where they came from.",
      "",
      "Prices are dollars a million tokens, in/out. The button beside this asks the providers again (`troupe models --refresh`).",
      ...(m.catalog ? ["", `The providers' lists are kept in \`${m.catalog.path}\`.`] : []),
    ].join("\n"),
    icon: "library",
    context: MODELS_CONTEXT,
    expanded: m.models.length <= UNFOLDED,
    children: [...lists, ...models].length > 0 ? [...lists, ...models] : [{ label: "None: set models.default or a provider" }],
  };
}

/** The group while Troupe is asked, or when it could not say. */
export function modelsPending(): Row {
  return {
    label: "Models",
    icon: "library",
    context: MODELS_CONTEXT,
    expanded: true,
    children: [{ label: "Asking Troupe…", description: "troupe models --json", icon: "loading~spin" }],
  };
}

export function modelsFailed(failure: Row): Row {
  return { label: "Models", icon: "library", context: MODELS_CONTEXT, expanded: true, children: [failure] };
}

// One model: its roles, then its window, its price and where they came from, as
// `troupe models` prints them. One its provider does not list is said to be not served,
// and has no window: the number in the JSON is Troupe's fallback, which nothing said. A
// price the config gives it is still said: someone wrote it down.
function modelRow(model: Model, roles: Models["roles"], sessionType: string | undefined, now: Date, catalog: Models["catalog"]): Row {
  const its = ROLES.filter((r) => roles[r] === model.id);
  const who = model.provider ?? sessionType ?? "its provider";
  const what = its.length > 0 ? `**${model.id}**: the ${its.join(", ").replace(/, ([^,]+)$/, " and $1")} model.` : `**${model.id}**`;
  const from = facts(model, who);
  const cost = model.input !== null && model.output !== null ? { input: usd(model.input), output: usd(model.output) } : null;
  const byConfig = model.price_source === "config";
  const price = cost ? `${cost.input}/${cost.output}${byConfig ? " (models.prices)" : ""}` : "";
  const priceLine = cost
    ? `Price: ${cost.input} in, ${cost.output} out, a million tokens, ${byConfig ? "from models.prices in your config" : from}.`
    : "Price: none. Its calls count as free wherever spend is added up, unless the provider prices them itself.";

  if (model.served === false) {
    const listed = catalog?.sources.find((s) => s.provider === model.provider);
    const when = listed?.fetched_at ? `, fetched ${ago(listed.fetched_at, now)},` : "";
    const nearest = model.nearest.length > 0 ? ` It serves ${model.nearest.join(", ")}.` : "";

    return {
      label: model.id,
      description: [list(its), `not served by ${who}`, price].filter((x) => x !== "").join(" · "),
      tooltip: [what, "", `**Not served:** ${who}'s list${when} does not have it, so a turn on it fails.${nearest}`, ...(cost ? ["", priceLine] : [])].join("\n"),
      icon: "warning",
    };
  }

  const window = model.context === null ? "window not known" : `${size(model.context)} window`;
  const tooltip = [what, ""];
  tooltip.push(model.context === null ? "Window: not known." : `Window: ${model.context.toLocaleString("en-US")} tokens, ${from}.`);
  tooltip.push(priceLine);
  if (!model.key) tooltip.push("", `No key is set for ${who}.`);
  if (model.served === null && model.model !== null) tooltip.push("", `Whether ${who} serves it is not known: it has not listed its models yet.`);

  return {
    label: model.id,
    description: [list(its), window, price || "no price", from, model.key ? "" : "no key"].filter((x) => x !== "").join(" · "),
    tooltip: tooltip.join("\n"),
    icon: its.length > 0 ? "star-full" : "circle-small",
  };
}

// Where a model's facts came from: its provider's own list, or the files that name it.
function facts(model: Model, who: string) {
  switch (model.source) {
    case "catalog":
      return `from ${who}'s list`;
    case "opencode":
      return "from opencode";
    default:
      return "from your config";
  }
}

// One provider's list: how many models and when, or why it did not answer.
function sourceRow(s: Source, now: Date): Row {
  const who = s.provider ?? s.type;
  const count = s.models === 1 ? "1 model" : `${s.models} models`;
  const at = s.url ? ` at \`${s.url}\`` : "";

  switch (s.status) {
    case "failed":
      return {
        label: `${who}'s list`,
        description: `did not answer ${ago(s.failed_at, now)}: ${s.error ?? "no reason given"}`,
        tooltip: `${who}${at} did not answer ${ago(s.failed_at, now)}: ${s.error ?? "no reason given"}.\n\n${s.models > 0 ? `${count} of it are from the cache, fetched ${ago(s.fetched_at, now)}.` : "Nothing of it is cached."}`,
        icon: "warning",
      };
    case "not_asked":
      return { label: `${who}'s list`, description: "not asked yet", tooltip: `${who} has not been asked what it serves yet.`, icon: "cloud" };
    default:
      return {
        label: `${who}'s list`,
        description: `${count}, fetched ${ago(s.fetched_at, now)}`,
        tooltip: `${count} from ${who}${at}, fetched ${ago(s.fetched_at, now)}.`,
        icon: "cloud",
      };
  }
}

function list(roles: Role[]) {
  return roles.join(", ");
}

// A window as `troupe models` writes it: whole thousands, or millions past a million.
function size(tokens: number) {
  if (tokens >= 1_000_000) return `${Math.floor(tokens / 100_000) / 10}M`;
  if (tokens >= 1_000) return `${Math.floor(tokens / 1_000)}k`;
  return String(tokens);
}

// Dollars a million tokens, to the places `troupe models` prints.
function usd(dollars: number) {
  if (dollars >= 10) return `$${dollars.toFixed(0)}`;
  if (dollars >= 0.1) return `$${dollars.toFixed(2)}`;
  return `$${dollars.toFixed(3)}`;
}

function ago(at: string | null, now: Date) {
  if (at === null) return "never";
  const s = Math.floor((now.getTime() - Date.parse(at)) / 1000);
  if (Number.isNaN(s)) return "at a time not known";
  if (s < 60) return "just now";
  if (s < 3_600) return plural(Math.floor(s / 60), "minute");
  if (s < 86_400) return plural(Math.floor(s / 3_600), "hour");
  return plural(Math.floor(s / 86_400), "day");
}

function plural(n: number, word: string) {
  return `${n} ${word}${n === 1 ? "" : "s"} ago`;
}
