// A person's own triggers as the plane answers them (troupe #1235): `trigger.own.list`,
// `.disable`, `.enable` and `.delete`, over the rows a fake keeps, the administrative half's
// where there is one, so the console's Triggers page and a person's own list are one set.
// A trigger is a person's own where its `own_by` is them; any other in their teams is
// refused `forbidden` saying whose it is, and one outside them is `not_found`, as
// `Troupe.Plane.Triggers.Own` answers.

import type { FakeTrigger } from "./admin.js";

type Answer = { result: unknown } | { error: { code: number; message: string; data?: unknown } };

export interface OwnTriggerPlane {
  rows: FakeTrigger[];
  /** The teams the caller is in. */
  teams: string[];
  /** On a gitops plane, the refusal of a write to what a repository holds, the attempt recorded; null on a direct one. */
  held: (subject: string, action: string, name: string) => Answer | null;
  record: (actor: string, action: string, subject: string, detail: Record<string, unknown>) => void;
  now?: () => Date;
}

// The first minute after `now` a five-field cron in UTC matches, within a year: numbers,
// stars, steps, lists and ranges.
export function nextCronRun(cron: string, now: Date): string | null {
  const fields = cron.trim().split(/\s+/);
  if (fields.length !== 5) return null;
  const ranges: Array<[number, number]> = [
    [0, 59],
    [0, 23],
    [1, 31],
    [1, 12],
    [0, 7],
  ];
  const sets = fields.map((f, i) => {
    const [lo, hi] = ranges[i]!;
    const out = new Set<number>();
    for (const part of f.split(",")) {
      const [range, step] = part.split("/");
      const [a, b] = range === "*" ? [lo, hi] : range!.includes("-") ? range!.split("-").map(Number) : [Number(range), step ? hi : Number(range)];
      for (let v = a!; v <= b!; v += Number(step ?? 1)) out.add(i === 4 ? v % 7 : v);
    }
    return out;
  });
  const at = new Date(now.getTime());
  at.setUTCSeconds(0, 0);
  for (let i = 0; i < 366 * 24 * 60; i++) {
    at.setUTCMinutes(at.getUTCMinutes() + 1);
    if (sets[0]!.has(at.getUTCMinutes()) && sets[1]!.has(at.getUTCHours()) && sets[2]!.has(at.getUTCDate()) && sets[3]!.has(at.getUTCMonth() + 1) && sets[4]!.has(at.getUTCDay())) {
      return at.toISOString().replace(".000Z", "Z");
    }
  }
  return null;
}

/** What a yes to a proposal makes: the team's trigger under the person's own principal, theirs. */
export function ownTriggerRow(fields: { team: string; name: string; owner: string; cron: string; profile: string; budget_micros?: number; session_id: string; artifact_id: string | null }): FakeTrigger {
  const at = new Date().toISOString();
  return {
    id: `trg-own-${fields.team}-${fields.name}`,
    team: fields.team,
    name: fields.name,
    principal: `svc:${fields.team}/own-${fields.owner.toLowerCase().replace(/[^a-z0-9]+/g, "-")}`,
    own_by: fields.owner,
    profile: fields.profile,
    agent: null,
    enabled: true,
    source: { kind: "schedule", cron: fields.cron, tz: "UTC" },
    prompt_template: "Rerun the report.",
    terms: { budget_micros: fields.budget_micros ?? 1_000_000, approvals: "deny", allow: ["publish_artifact"] },
    visibility: "private",
    review: "required",
    notify: [fields.owner],
    notify_url: null,
    concurrency: 1,
    last_fired_at: null,
    created_by: fields.owner,
    updated_at: at,
    revisions: [],
    made: { session_id: fields.session_id, artifact_id: fields.artifact_id },
  };
}

function json(row: FakeTrigger, now: Date): Record<string, unknown> {
  const cron = row.source["kind"] === "schedule" && typeof row.source["cron"] === "string" ? (row.source["cron"] as string) : null;
  return {
    id: row.id,
    team: row.team,
    name: row.name,
    principal: row.principal,
    enabled: row.enabled,
    source: row.source,
    cron,
    next_run_at: row.enabled && cron ? nextCronRun(cron, now) : null,
    last_run: row.last_run ?? null,
    budget_micros: typeof row.terms?.["budget_micros"] === "number" ? row.terms["budget_micros"] : null,
    profile: row.profile,
    session_id: row.made?.session_id ?? null,
    artifact_id: row.made?.artifact_id ?? null,
  };
}

/** The four methods, as the plane answers them for `subject`. */
export function ownTriggerRpc(plane: OwnTriggerPlane, subject: string, method: string, params: Record<string, unknown>): Answer {
  const now = plane.now?.() ?? new Date();
  const mine = plane.rows.filter((r) => r.own_by === subject && plane.teams.includes(r.team));
  if (method === "trigger.own.list") {
    return { result: { triggers: [...mine].sort((a, b) => `${a.team}/${a.name}`.localeCompare(`${b.team}/${b.name}`)).map((r) => json(r, now)), most_per_team: 5 } };
  }
  const ref = params["trigger"];
  if (typeof ref !== "string" || ref === "") return { error: { code: -32602, message: "invalid_params", data: { missing: "trigger" } } };
  const found = plane.rows.filter((r) => plane.teams.includes(r.team) && (r.id === ref || `${r.team}/${r.name}` === ref || r.name === ref));
  const row = found[0];
  if (!row) return { error: { code: -32005, message: "not_found", data: { trigger: ref } } };
  const own = `svc:${row.team}/own-${subject.toLowerCase().replace(/[^a-z0-9]+/g, "-")}`;
  if (row.own_by !== subject) {
    return {
      error: {
        code: -32004,
        message: "forbidden",
        data: { trigger: `${row.team}/${row.name}`, principal: row.principal, reason: `${row.team}/${row.name} runs as ${row.principal}, not as your own principal ${own}; a team admin of ${row.team} switches it off or removes it` },
      },
    };
  }
  const name = `${row.team}/${row.name}`;
  if (method === "trigger.own.delete") {
    if (row.gitops?.problem !== "missing") {
      const held = plane.held(subject, "trigger.delete", name);
      if (held) return held;
    }
    plane.record(subject, "trigger.delete", name, { via: "own", principal: row.principal, enabled: row.enabled, source: row.source, profile: row.profile });
    plane.rows.splice(plane.rows.indexOf(row), 1);
    return { result: { team: row.team, name: row.name, deleted: true } };
  }
  const enabled = method === "trigger.own.enable";
  if (!enabled && method !== "trigger.own.disable") return { error: { code: -32601, message: "method_not_found", data: { method } } };
  const held = plane.held(subject, "trigger.put", name);
  if (held) return held;
  plane.record(subject, "trigger.put", name, { via: "own", principal: row.principal, ...(row.enabled !== enabled ? { enabled: { from: row.enabled, to: enabled } } : {}) });
  row.enabled = enabled;
  row.updated_at = now.toISOString();
  return { result: { trigger: json(row, now) } };
}
