// Worker profiles: the list, a profile read whole, and the editor.
//
// The list says, per profile, how its pods are doing, which image it runs and which teams
// may use it. A profile's page reads every field of its spec: what the editor has fields
// for, what it has none for (identities at MCP servers, what its sessions may do on GitHub,
// model prices, a server's credential settings) and anything the resource gains that this
// console has never heard of, which is listed as it is rather than left out.
//
// The editor writes the paths it has fields for and nothing else. `admin.profile.put`
// replaces the spec with what it is sent, so on load the editor keeps the spec without its
// own paths and without what the plane writes, and a save sends that back with the form
// merged over it, key by key; an MCP server row the form shows is merged over the row it
// was loaded as. A field this console does not know is therefore carried through a save
// exactly as it was. What the plane writes itself (replicas, sessions per pod, resources,
// the teams, the image's resolution) is never sent: the plane refuses it.
//
// A change, a new profile and a deletion are each previewed (the plane's own diff and what
// the cluster policy makes of it), confirmed (a deletion by typing the profile's name) and
// shown as the audit recorded it. On a plane in `gitops` mode a repository holds the
// profiles: they are shown locked, with where they come from, and nothing offers a write.
//
// A team admin is shown the profiles their teams are granted, as `admin.profiles.list`
// answers them; a profile's spec is a platform admin's to read and change.

import { useState } from "react";
import type { JSX } from "react";
import type { AdminProfile, AdminTeam, ProfileDetail, ProfileWrite } from "@troupe/client";
import { href } from "../route";
import { describeError, recorded, show, useConsole, useLoad } from "../console";
import { AuditNote, Empty, Field, Fields, GitopsProblem, Loaded, Locked, Preview, Region, Status, count, linesOf, modeOf, useChange } from "./bits";
import type { DiffLine, Done } from "./bits";
import { STATES, profileState } from "./Overview";

/** Which teams are granted each profile, from the teams this person may see. */
function grantedTo(teams: AdminTeam[]): Map<string, string[]> {
  const out = new Map<string, string[]>();
  for (const t of teams) for (const g of t.grants) out.set(g.profile, [...(out.get(g.profile) ?? []), t.name]);
  return out;
}

function gitopsOf(p: AdminProfile): ProfileDetail["gitops"] {
  return (p["gitops"] ?? null) as ProfileDetail["gitops"];
}

// -- the list ----------------------------------------------------------------------------

export function Profiles(): JSX.Element {
  const { admin, role } = useConsole();
  const platform = role === "platform_admin";
  const [load, reload] = useLoad(() => Promise.all([admin.profiles(), admin.teams(), admin.provisioningMode().catch(() => null)]), [admin]);
  const [creating, setCreating] = useState(false);
  const { done, apply } = useChange(reload);

  return (
    <div className="page">
      <Loaded load={load} what="the profiles" retry={reload}>
        {([profiles, teams, mode]) => {
          const locked = modeOf(mode) === "gitops";
          const granted = grantedTo(teams);
          const source = profiles.map((p) => gitopsOf(p)?.source).find(Boolean);
          return (
            <>
              <p className="lead">
                {platform
                  ? "A worker profile is a named answer to what an agent of its kind may reach: its image, its model, its egress and its MCP servers. Pods are pooled per profile, and a team uses one once it is granted it."
                  : "The profiles your teams are granted, and how their pods are doing. A profile's settings are a platform admin's to read and change."}
              </p>
              {locked && <Locked things="profiles" source={source} />}
              {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
              {profiles.length === 0 ? (
                <Empty title={platform ? "No profile yet" : "No profile granted to your teams"}>
                  {platform ? (locked ? "A profile is a manifest in the repository; the plane lists it here once it is in the cluster." : "Make one below.") : "A platform admin grants a team a profile."}
                </Empty>
              ) : (
                <div className="scroll">
                  <table className="profiles">
                    <thead>
                      <tr>
                        <th>Profile</th>
                        <th>State</th>
                        <th className="num">Pods</th>
                        <th>Image</th>
                        <th>Size</th>
                        <th>Channel</th>
                        <th>Teams</th>
                      </tr>
                    </thead>
                    <tbody>
                      {profiles.map((p) => {
                        const s = STATES[profileState(p)];
                        const g = gitopsOf(p);
                        return (
                          <tr key={p.name}>
                            <td>{platform ? <a href={href({ page: "profiles", path: [p.name] })}>{p.name}</a> : p.name}</td>
                            <td>
                              <Status kind={s.kind} glyph={s.glyph}>
                                {s.word}
                              </Status>
                              {g?.problem && (
                                <>
                                  {" "}
                                  <Status kind={g.problem === "refused" ? "denied" : "waiting"} glyph={g.problem === "refused" ? "✕" : "◆"}>
                                    {g.problem.replace("_", " ")}
                                  </Status>
                                </>
                              )}
                            </td>
                            <td className="num">
                              {p.pods.length} / {p.replicas ?? "—"}
                            </td>
                            <td className="mono">{p.image ?? <span className="muted">{String(p["provisioner"] ?? "none")}</span>}</td>
                            <td>{show(p["size_class"])}</td>
                            <td>{p.channel ? <a href={href({ page: "bundles", path: [p.channel] })}>{p.channel}</a> : "—"}</td>
                            <td>{(granted.get(p.name) ?? []).join(", ") || <span className="muted">none</span>}</td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              )}
              {platform && !locked && !creating && (
                <button type="button" onClick={() => setCreating(true)}>
                  New profile
                </button>
              )}
              {creating && (
                <ProfileEditor
                  detail={null}
                  names={profiles.map((p) => p.name)}
                  onCancel={() => setCreating(false)}
                  onConfirm={async (draft) => {
                    await apply("profile.put", draft.name, () => admin.putProfile(draft), `${draft.name} is a profile. Grant it to a team on the team's Access tab.`, (a) => (a as { changes?: Record<string, unknown> }).changes);
                    setCreating(false);
                  }}
                />
              )}
            </>
          );
        }}
      </Loaded>
    </div>
  );
}

// -- a profile ---------------------------------------------------------------------------

export function Profile({ name }: { name: string }): JSX.Element {
  const { admin, me, notify } = useConsole();
  const [load, reload] = useLoad(() => Promise.all([admin.profile(name), admin.teams(), admin.provisioningMode().catch(() => null)]), [admin, name]);
  const [editing, setEditing] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [done, setDone] = useState<Done | null>(null);
  const [gone, setGone] = useState<Done | null>(null);

  if (gone) {
    // The profile is gone, so its page is not read again: what was done stays on the screen.
    return (
      <div className="page">
        <AuditNote action={gone.action} subject={gone.subject} detail={gone.detail} />
        <p>
          {name} is no longer a profile. <a href={href({ page: "profiles" })}>All profiles</a>
        </p>
      </div>
    );
  }

  return (
    <div className="page">
      <Loaded load={load} what={`profile ${name}`} retry={reload}>
        {([detail, teams, mode]) => {
          const p = detail.profile;
          const locked = modeOf(mode) === "gitops";
          const granted = grantedTo(teams).get(name) ?? [];
          const s = STATES[profileState(p)];
          const deletable = !locked || detail.gitops?.problem === "missing";
          const busy = editing || deleting;
          return (
            <>
              <p className="team-meta">
                <Status kind={s.kind} glyph={s.glyph}>
                  {s.word}
                </Status>{" "}
                · {p.pods.length} of {count(p.replicas ?? 0, "pod")} · {granted.length ? `granted to ${granted.join(", ")}` : "granted to no team"} ·{" "}
                <a href={href({ page: "profiles" })}>All profiles</a>
              </p>
              {locked && (
                <Locked things="profiles" source={detail.gitops?.source}>
                  {detail.gitops?.generation !== null && detail.gitops?.generation !== undefined && <p className="note">What is below is what the plane read, at generation {detail.gitops.generation}.</p>}
                  <GitopsProblem gitops={detail.gitops} />
                </Locked>
              )}
              {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
              {!editing && <ProfileReading detail={detail} granted={granted} />}
              {!busy && !locked && (
                <div className="actions">
                  <button type="button" onClick={() => setEditing(true)}>
                    Change {name}
                  </button>
                  <button type="button" className="danger" onClick={() => setDeleting(true)}>
                    Delete {name}
                  </button>
                </div>
              )}
              {!busy && locked && deletable && (
                <button type="button" className="danger" onClick={() => setDeleting(true)}>
                  Delete {name}'s row
                </button>
              )}
              {editing && (
                <ProfileEditor
                  detail={detail}
                  names={[]}
                  onCancel={() => setEditing(false)}
                  onConfirm={async (draft) => {
                    const answer = await admin.putProfile(draft);
                    setEditing(false);
                    setDone({ action: "profile.put", subject: name, detail: answer.changes });
                    notify(`${name} is changed.`);
                    reload();
                  }}
                />
              )}
              {deleting && (
                <Preview
                  title={`profile/${name}`}
                  lines={[{ field: "profile", from: name, to: null }]}
                  effects={[
                    granted.length ? `Every grant goes: ${granted.join(", ")} ${granted.length === 1 ? "loses" : "lose"} ${name}. A team cannot be granted a profile that does not exist.` : "No team is granted it.",
                    `The sessions that ran on ${name} turn read-only rather than being erased: what was done on it stays readable.`,
                    locked ? "The cluster has no resource for it, so this deletes the plane's row and nothing else." : "Its pods go, as the cluster removes them.",
                  ]}
                  verb={`Delete ${name}`}
                  typeToConfirm={name}
                  onCancel={() => setDeleting(false)}
                  onConfirm={async () => {
                    await admin.deleteProfile(name);
                    setGone({ action: "profile.delete", subject: name, detail: await recorded(admin, me.subject, "profile.delete", name) });
                    notify(`${name} is deleted.`);
                  }}
                />
              )}
            </>
          );
        }}
      </Loaded>
    </div>
  );
}

// -- reading one -------------------------------------------------------------------------

/** The spec paths a section of this page reads; whatever else the spec holds is listed as it is. */
const READ_HERE = [
  "llm.endpoint",
  "llm.provider",
  "llm.model",
  "llm.smallModel",
  "llm.secretRef",
  "llm.prices",
  "egress.fqdns",
  "egress.gitHosts",
  "storage.storageClassName",
  "mcpServers",
  "mcpIdentities",
  "github.permissions",
  "configBundleChannel",
  "orgMount",
  "repositoryOverridesBundle",
  "personalTools",
];

/** What the plane writes into the resource itself, which a spec read back may hold. */
const PLANE_WRITTEN = ["replicas", "sessionsPerPod", "resources", "teams", "image", "storage.size"];

/** Every leaf of a spec as a dotted path and its value; a list is a leaf. */
function leaves(value: unknown, path: string[] = []): Array<[string, unknown]> {
  if (typeof value === "object" && value !== null && !Array.isArray(value) && Object.keys(value).length > 0) {
    return Object.entries(value as Record<string, unknown>).flatMap(([k, v]) => leaves(v, [...path, k]));
  }
  return path.length ? [[path.join("."), value]] : [];
}

const under = (path: string, prefixes: string[]) => prefixes.some((p) => path === p || path.startsWith(`${p}.`));

function at(spec: Record<string, unknown>, path: string): unknown {
  return path.split(".").reduce<unknown>((v, k) => (typeof v === "object" && v !== null ? (v as Record<string, unknown>)[k] : undefined), spec);
}

function ProfileReading({ detail, granted }: { detail: ProfileDetail; granted: string[] }): JSX.Element {
  const p = detail.profile;
  const spec = detail.spec ?? {};
  const servers = (Array.isArray(spec["mcpServers"]) ? spec["mcpServers"] : []) as Array<Record<string, unknown>>;
  const identities = (Array.isArray(spec["mcpIdentities"]) ? spec["mcpIdentities"] : []) as Array<Record<string, unknown>>;
  const permissions = (at(spec, "github.permissions") ?? {}) as Record<string, unknown>;
  const prices = (at(spec, "llm.prices") ?? {}) as Record<string, { input?: unknown; output?: unknown }>;
  const rest = leaves(spec).filter(([path]) => !under(path, READ_HERE) && !under(path, PLANE_WRITTEN));
  const written = leaves(spec).filter(([path]) => under(path, PLANE_WRITTEN));
  const verdict = detail.policy;
  const missing = (p["missing_guarantees"] ?? []) as string[];
  const bundle = detail.bundle;
  return (
    <>
      <Region>What runs</Region>
      <Fields
        rows={[
          ["Image", <span className="mono">{show(p.image)}</span>],
          ["How demanding", <>{show(p["size_class"])}{typeof p["size_class_summary"] === "string" && <span className="hint"> {p["size_class_summary"]}</span>}</>],
          ["Most sessions at once", p["max_sessions"] === null || p["max_sessions"] === undefined ? "no ceiling" : show(p["max_sessions"])],
          ["Workers kept warm", show(p["warm_workers"] ?? 0)],
          ["Pods, as the plane runs them", `${show(p.replicas)} × ${show(p.sessions_per_pod)} sessions`],
          ["Made by", <>{show(p["provisioner"])}{missing.length > 0 && <span className="hint"> without {missing.join(", ")}</span>}</>],
          ["Teams granted", granted.length ? granted.join(", ") : "none"],
        ]}
      />

      <Region>The model</Region>
      <Fields
        rows={[
          ["Endpoint", <span className="mono">{show(at(spec, "llm.endpoint"))}</span>],
          ["Provider", show(at(spec, "llm.provider"))],
          ["Model", show(at(spec, "llm.model"))],
          ["Small model", show(at(spec, "llm.smallModel"))],
          ["Credential", at(spec, "llm.secretRef") ? <span className="mono">{`${show(at(spec, "llm.secretRef.name"))} · ${show(at(spec, "llm.secretRef.key") ?? "api-key")}`}</span> : "—"],
          ["Prices, per million tokens", Object.keys(prices).length ? Object.entries(prices).map(([m, v]) => `${m}: ${show(v?.input)} in, ${show(v?.output)} out`).join("; ") : "none: the gateway's"],
        ]}
      />

      <Region>What the pods may reach</Region>
      <Fields
        rows={[
          ["Allowed hosts", <span className="mono">{show(at(spec, "egress.fqdns"))}</span>],
          ["Git hosts", <span className="mono">{show(at(spec, "egress.gitHosts"))}</span>],
          ["Storage class", show(at(spec, "storage.storageClassName") ?? "the cluster's default")],
          ["On GitHub", Object.keys(permissions).length ? Object.entries(permissions).map(([k, v]) => `${k}: ${show(v)}`).join(", ") : "clone, and no more"],
        ]}
      />

      <Region>MCP servers</Region>
      {servers.length === 0 ? (
        <Empty title="None of its own">Sessions on it get what its configuration bundle gives them.</Empty>
      ) : (
        <div className="scroll">
          <table>
            <thead>
              <tr>
                <th>Name</th>
                <th>URL</th>
                <th>Credential</th>
                <th>Header</th>
                <th className="num">Timeout</th>
                <th>Also</th>
              </tr>
            </thead>
            <tbody>
              {servers.map((s, i) => {
                const { name, url, credentialRef, header, timeoutMs, ...also } = s;
                return (
                  <tr key={`${String(name)}-${i}`}>
                    <td>{show(name)}</td>
                    <td className="mono">{show(url)}</td>
                    <td className="mono">{show(credentialRef)}</td>
                    <td className="mono">{show(header)}</td>
                    <td className="num">{timeoutMs ? `${show(timeoutMs)} ms` : "—"}</td>
                    <td className="mono">
                      {Object.keys(also).length
                        ? Object.entries(also)
                            .map(([k, v]) => `${k}: ${show(v)}`)
                            .join("; ")
                        : "—"}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      <Region>Who it is at MCP servers</Region>
      {identities.length === 0 ? (
        <Empty title="No identity">It calls no server as itself with client credentials.</Empty>
      ) : (
        <div className="scroll">
          <table>
            <thead>
              <tr>
                <th>Server</th>
                <th>Client</th>
                <th>Scope</th>
                <th>Token URL</th>
                <th>Signing key</th>
              </tr>
            </thead>
            <tbody>
              {identities.map((m, i) => (
                <tr key={`${String(m["server"])}-${i}`}>
                  <td>{show(m["server"])}</td>
                  <td className="mono">{show(m["clientId"])}</td>
                  <td className="mono">{show(m["scope"])}</td>
                  <td className="mono">{show(m["tokenUrl"])}</td>
                  <td className="mono">
                    {[m["transitKey"], m["keyVersion"] !== undefined ? `v${String(m["keyVersion"])}` : null, m["algorithm"], m["certificateThumbprint"]].filter(Boolean).map(String).join(" · ") || "—"}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {detail.identity_problems.length > 0 && (
        <ul className="effects">
          {detail.identity_problems.map((w) => (
            <li key={w}>{w}</li>
          ))}
        </ul>
      )}

      <Region>Configuration</Region>
      <Fields
        rows={[
          ["Bundle channel", <a href={href({ page: "bundles", path: [String(spec["configBundleChannel"] ?? bundle?.channel ?? "stable")] })}>{show(spec["configBundleChannel"] ?? bundle?.channel ?? "stable")}</a>],
          [
            "Its pods have",
            bundle?.published === null || bundle?.published === undefined
              ? "nothing published on that channel"
              : `v${bundle.published}${bundle["adopted?"] ? ", on every pod" : bundle["adopted?"] === false ? `, not on ${count(Array.isArray(bundle.stale) ? bundle.stale.length : 0, "pod")} yet` : ""}`,
          ],
          ["Org volume", spec["orgMount"] ? "mounted, read-only" : "not mounted"],
          ["A repository's agents and skills", spec["repositoryOverridesBundle"] ? "replace the bundle's" : "lose to the bundle's"],
          ["People's own signed-in tools", spec["personalTools"] === "forbid" ? "kept off these pods" : "allowed"],
        ]}
      />

      {rest.length > 0 && (
        <>
          <Region>Everything else in its spec</Region>
          <p className="note">Fields this console has no section for, as the plane holds them. The editor carries them through a save unchanged.</p>
          <Fields paths rows={rest.map(([path, v]) => [path, <span className="mono">{show(v)}</span>])} />
        </>
      )}
      {written.length > 0 && (
        <>
          <Region>Written by the plane</Region>
          <Fields paths rows={written.map(([path, v]) => [path, <span className="mono">{show(v)}</span>])} />
        </>
      )}

      <Region>What the cluster policy makes of it</Region>
      {verdict === null || verdict["allowed?"] ? (
        <p>
          <Status kind="running" glyph="●">
            allowed
          </Status>{" "}
          The cluster policy allows this profile.
        </p>
      ) : (
        <ul className="effects">
          {verdict.violations.map((v) => (
            <li key={violation(v)}>{violation(v)}</li>
          ))}
        </ul>
      )}

      <Region>What the cluster says</Region>
      {p.conditions === null ? (
        <p className="hint">Unknown: the plane could not ask the cluster.</p>
      ) : p.conditions.length === 0 ? (
        <p className="hint">No conditions reported.</p>
      ) : (
        <Fields rows={p.conditions.map((c): [string, JSX.Element] => [show(c.type), <>{c.status === "True" ? "yes" : c.status === "False" ? "no" : show(c.status)}{c.message && <span className="hint"> {c.message}</span>}</>])} />
      )}

      <Region>Pods</Region>
      {p.pods.length === 0 ? (
        <Empty title="No pod">{p["warm_workers"] ? "One starts as the plane brings the profile up." : "None kept warm: the next session starts one."}</Empty>
      ) : (
        <div className="scroll">
          <table>
            <thead>
              <tr>
                <th>Pod</th>
                <th>State</th>
                <th className="num">Sessions</th>
                <th>Version</th>
                <th>Bundle</th>
              </tr>
            </thead>
            <tbody>
              {p.pods.map((pod) => (
                <tr key={pod.pod}>
                  <td className="mono">{pod.pod}</td>
                  <td>{pod.draining ? "draining" : pod.healthy ? "healthy" : pod.last_seen_at ? "broken" : "never reported"}</td>
                  <td className="num">
                    {pod.active_sessions} / {pod.capacity}
                  </td>
                  <td className="mono">{show(pod.version)}</td>
                  <td className="mono">{show(pod.bundle_hash)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}

/** A policy violation in words: the plane's sentence, or the parts of one it sent. */
function violation(v: unknown): string {
  if (typeof v === "string") return v;
  if (typeof v === "object" && v !== null && typeof (v as { message?: unknown }).message === "string") return (v as { message: string }).message;
  return show(v);
}

// -- the editor --------------------------------------------------------------------------

/** The spec paths the editor writes. Everything else the spec holds is carried through a save as it was loaded. */
const FORM_PATHS = [
  ["llm", "endpoint"],
  ["llm", "provider"],
  ["llm", "model"],
  ["llm", "smallModel"],
  ["llm", "secretRef"],
  ["egress", "fqdns"],
  ["egress", "gitHosts"],
  ["storage"],
  ["mcpServers"],
  ["configBundleChannel"],
  ["orgMount"],
  ["repositoryOverridesBundle"],
  ["personalTools"],
];

/** What the plane writes into the resource itself: never sent back, and refused if it were. */
const NOT_SENT = ["replicas", "sessionsPerPod", "resources", "teams", "image"];

type Plain = Record<string, unknown>;

const isPlain = (v: unknown): v is Plain => typeof v === "object" && v !== null && !Array.isArray(v);

function without(map: Plain, [key, ...rest]: string[]): Plain {
  if (key === undefined) return map;
  if (rest.length === 0) {
    const { [key]: _gone, ...kept } = map;
    return kept;
  }
  const inner = map[key];
  return isPlain(inner) ? { ...map, [key]: without(inner, rest) } : map;
}

/** The loaded spec without what the form writes or the plane does: what a save carries as it was. */
export function keptOf(spec: Plain): Plain {
  const dropped = Object.fromEntries(Object.entries(spec).filter(([k]) => !NOT_SENT.includes(k)));
  return FORM_PATHS.reduce(without, dropped);
}

function deepMerge(under: Plain, over: Plain): Plain {
  const out: Plain = { ...under };
  for (const [k, v] of Object.entries(over)) out[k] = isPlain(out[k]) && isPlain(v) ? deepMerge(out[k] as Plain, v) : v;
  return out;
}

/** Absent, not empty: a blank field is one nobody filled in, and the branch it is in goes if nothing under it is set. */
function compact(map: Plain): Plain {
  return Object.fromEntries(
    Object.entries(map).filter(([, v]) => !(v === undefined || v === null || v === "" || (Array.isArray(v) && v.length === 0) || (isPlain(v) && Object.keys(v).length === 0))),
  );
}

const split = (text: string): string[] => text.split(/[\s,]+/).filter(Boolean);

function whole(text: string): number | null {
  const t = text.trim();
  return /^\d+$/.test(t) ? Number(t) : null;
}

/** The `llm` fields a profile may set only beside `llm.endpoint`, as the plane names them. */
const LLM_FIELDS = ["provider", "model", "smallModel", "secretRef", "prices"];

/**
 * The plane's rule, said at the field before anything is sent: every `llm` field but the
 * endpoint needs `llm.endpoint`, since the pods are given the model settings only with one.
 * Prices count though the form has no field for them: they are carried from the loaded spec.
 */
export function llmWithoutEndpoint(llm: Plain): string | null {
  const set = LLM_FIELDS.filter((f) => !(llm[f] === undefined || llm[f] === null || llm[f] === "" || (isPlain(llm[f]) && Object.keys(llm[f] as Plain).length === 0))).map((f) => `llm.${f}`);
  if (set.length === 0 || (typeof llm["endpoint"] === "string" && llm["endpoint"] !== "")) return null;
  const listed = set.length === 1 ? set[0] : `${set.slice(0, -1).join(", ")} and ${set.at(-1)}`;
  return `${listed} ${set.length === 1 ? "is" : "are"} set without an endpoint. The pods are given the model settings only with one, and would run on Troupe's built-in model settings instead: set the endpoint, or take ${set.length === 1 ? "it" : "them"} out.`;
}

interface Form {
  name: string;
  image: string;
  sizeClass: string;
  maxSessions: string;
  warmWorkers: string;
  endpoint: string;
  provider: string;
  model: string;
  smallModel: string;
  secretName: string;
  secretKey: string;
  fqdns: string;
  gitHosts: string;
  storageClass: string;
  channel: string;
  orgMount: boolean;
  repositoryOverridesBundle: boolean;
  forbidPersonalTools: boolean;
}

const SERVER_FIELDS = ["name", "url", "credentialRef", "header", "timeoutMs"] as const;

function formOf(detail: ProfileDetail | null): Form {
  const spec = detail?.spec ?? {};
  const text = (v: unknown) => (v === undefined || v === null ? "" : String(v));
  const lines = (v: unknown) => (Array.isArray(v) ? v.join("\n") : text(v));
  return {
    name: detail?.profile.name ?? "",
    image: text(detail?.profile.image),
    sizeClass: text(detail?.profile["size_class"] ?? "standard"),
    maxSessions: text(detail?.profile["max_sessions"]),
    warmWorkers: text(detail?.profile["warm_workers"] ?? (detail ? 0 : 1)),
    endpoint: text(at(spec, "llm.endpoint")),
    provider: text(at(spec, "llm.provider")),
    model: text(at(spec, "llm.model")),
    smallModel: text(at(spec, "llm.smallModel")),
    secretName: text(at(spec, "llm.secretRef.name")),
    secretKey: text(at(spec, "llm.secretRef.key")),
    fqdns: lines(at(spec, "egress.fqdns")),
    gitHosts: lines(at(spec, "egress.gitHosts")),
    storageClass: text(at(spec, "storage.storageClassName")),
    channel: text(spec["configBundleChannel"]),
    orgMount: spec["orgMount"] === true,
    repositoryOverridesBundle: spec["repositoryOverridesBundle"] === true,
    forbidPersonalTools: spec["personalTools"] === "forbid",
  };
}

/**
 * The profile the form describes, as `admin.profile.put` takes it: what the form says,
 * merged key by key over what was loaded without the form's paths, so nothing the form
 * has no field for is lost. Exported for the test that holds the mapping.
 */
export function draftOf(form: Form, servers: Plain[], kept: Plain): ProfileWrite {
  const typed = compact({
    llm: compact({
      endpoint: form.endpoint.trim(),
      provider: form.provider.trim(),
      model: form.model.trim(),
      smallModel: form.smallModel.trim(),
      secretRef: compact({ name: form.secretName.trim(), key: form.secretKey.trim() }),
    }),
    egress: compact({ fqdns: split(form.fqdns), gitHosts: split(form.gitHosts) }),
    storage: compact({ storageClassName: form.storageClass.trim() }),
    mcpServers: servers
      .map((s) => compact(Object.fromEntries(Object.entries(s).map(([k, v]) => [k, k === "timeoutMs" ? (typeof v === "number" ? v : whole(String(v ?? ""))) : v]))))
      .filter((s) => typeof s["url"] === "string" && s["url"] !== ""),
    configBundleChannel: form.channel.trim(),
    // Written whichever way they are: false is a value here, and an absent one could never be turned off from this form.
    orgMount: form.orgMount,
    repositoryOverridesBundle: form.repositoryOverridesBundle,
    personalTools: form.forbidPersonalTools ? "forbid" : "allow",
  });
  return {
    name: form.name.trim(),
    image: form.image.trim(),
    size_class: form.sizeClass,
    // Sent when blank too, as null: a ceiling taken away is a change.
    max_sessions: whole(form.maxSessions),
    warm_workers: whole(form.warmWorkers) ?? 0,
    spec: compact(deepMerge(kept, typed)),
  };
}

/** A profile's name, as a Kubernetes resource is named. */
const NAME = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/;

export function ProfileEditor({
  detail,
  names,
  onCancel,
  onConfirm,
}: {
  detail: ProfileDetail | null;
  names: string[];
  onCancel: () => void;
  onConfirm: (draft: ProfileWrite) => Promise<void>;
}): JSX.Element {
  const { admin } = useConsole();
  const creating = detail === null;
  const [form, setForm] = useState<Form>(() => formOf(detail));
  // Each row as it was loaded; the form's fields go over it, so a server's credential settings survive an edit to its URL.
  const [servers, setServers] = useState<Plain[]>(() => ((detail?.spec?.["mcpServers"] ?? []) as Plain[]).map((s) => ({ ...s })));
  const [kept] = useState<Plain>(() => keptOf(detail?.spec ?? {}));
  const [checked, setChecked] = useState<Record<number, { host: string; allowed: boolean } | string>>({});
  const [preview, setPreview] = useState<{ lines: DiffLine[]; effects: string[] } | null>(null);
  const [asking, setAsking] = useState(false);
  const [error, setError] = useState<unknown>(null);

  const draft = draftOf(form, servers, kept);
  const llm = (draft.spec?.["llm"] ?? {}) as Plain;
  const llmProblem = llmWithoutEndpoint(llm);
  const nameProblem = creating
    ? form.name.trim() === ""
      ? null
      : names.includes(form.name.trim())
        ? `${form.name.trim()} is a profile already; open it to change it.`
        : NAME.test(form.name.trim())
          ? null
          : "Lowercase letters, digits and dashes, starting and ending with a letter or digit: it is the name of a resource in the cluster."
    : null;
  const blocked = Boolean(llmProblem || nameProblem) || draft.name === "" || draft.image === "";
  const set = (patch: Partial<Form>) => {
    setForm({ ...form, ...patch });
    setError(null);
  };

  if (preview) {
    return (
      <Preview
        title={`profile/${draft.name}`}
        lines={preview.lines}
        effects={preview.effects}
        verb={creating ? `Create ${draft.name}` : "Apply"}
        onCancel={() => setPreview(null)}
        onConfirm={() => onConfirm(draft)}
      />
    );
  }

  return (
    <form
      className="edit grid profile-editor"
      aria-label={creating ? "A new profile" : `Changing ${draft.name}`}
      onSubmit={(e) => {
        e.preventDefault();
        setAsking(true);
        setError(null);
        admin.previewProfile(draft).then(
          (answer) => {
            setAsking(false);
            const lines = linesOf(answer.changes);
            setPreview({ lines, effects: effectsOf(answer.policy, answer.mode, draft, detail, lines) });
          },
          (e: unknown) => {
            setAsking(false);
            setError(e);
          },
        );
      }}
    >
      <Region>What runs</Region>
      <Field label="Name" hint={creating ? "The profile's name, and the name of its resource in the cluster." : "A different name is a different profile, not a rename."} error={nameProblem}>
        {(p) => <input {...p} value={form.name} onChange={(e) => set({ name: e.target.value })} readOnly={!creating} autoComplete="off" spellCheck={false} />}
      </Field>
      <Field label="Image" hint="repository:tag, or repository@sha256:… A digest pins it; a tag does not. Or release, for the worker image of the release this plane runs.">
        {(p) => <input {...p} value={form.image} onChange={(e) => set({ image: e.target.value })} autoComplete="off" spellCheck={false} />}
      </Field>
      <Field label="How demanding" hint="Standard puts several sessions on a worker; heavy gives each more CPU, memory and disk. A question about resources, not safety.">
        {(p) => (
          <select {...p} value={form.sizeClass} onChange={(e) => set({ sizeClass: e.target.value })}>
            {!["standard", "heavy"].includes(form.sizeClass) && <option value={form.sizeClass}>{form.sizeClass}</option>}
            <option value="standard">standard</option>
            <option value="heavy">heavy</option>
          </select>
        )}
      </Field>
      <Field label="Most sessions at once" hint="How far it may grow, in sessions. Empty is no ceiling, bounded by the team's budget.">
        {(p) => <input {...p} value={form.maxSessions} onChange={(e) => set({ maxSessions: e.target.value })} inputMode="numeric" />}
      </Field>
      <Field label="Workers kept warm" hint="How many stay up when nothing runs. 0 costs the next session a cold start of about half a minute.">
        {(p) => <input {...p} value={form.warmWorkers} onChange={(e) => set({ warmWorkers: e.target.value })} inputMode="numeric" />}
      </Field>

      <Region>The model</Region>
      <Field label="Endpoint" hint="The base URL a session's model calls go to, usually a gateway. Egress must allow its host." error={llmProblem}>
        {(p) => <input {...p} value={form.endpoint} onChange={(e) => set({ endpoint: e.target.value })} autoComplete="off" spellCheck={false} />}
      </Field>
      <Field label="Provider" hint="The API the endpoint speaks, as the plane names its provider types: openai for Chat Completions, which a gateway serves, anthropic for the Messages API.">
        {(p) => <input {...p} value={form.provider} onChange={(e) => set({ provider: e.target.value })} autoComplete="off" spellCheck={false} />}
      </Field>
      <Field label="Model" hint="What a session uses for its work.">
        {(p) => <input {...p} value={form.model} onChange={(e) => set({ model: e.target.value })} autoComplete="off" spellCheck={false} />}
      </Field>
      <Field label="Small model" hint="Used only to summarise a long conversation.">
        {(p) => <input {...p} value={form.smallModel} onChange={(e) => set({ smallModel: e.target.value })} autoComplete="off" spellCheck={false} />}
      </Field>
      <Field label="Credential: secret name" hint="A Secret in the worker's namespace, read by the pod at call time. Nothing here holds its value.">
        {(p) => <input {...p} value={form.secretName} onChange={(e) => set({ secretName: e.target.value })} autoComplete="off" spellCheck={false} />}
      </Field>
      <Field label="Credential: key" hint="The key inside that Secret. Empty means api-key.">
        {(p) => <input {...p} value={form.secretKey} onChange={(e) => set({ secretKey: e.target.value })} autoComplete="off" spellCheck={false} />}
      </Field>

      <Region>What the pods may reach</Region>
      <Field label="Allowed hosts" hint="One per line: the model's endpoint, and anything a skill calls. The cluster's network policy enforces it.">
        {(p) => <textarea {...p} value={form.fqdns} onChange={(e) => set({ fqdns: e.target.value })} rows={3} spellCheck={false} />}
      </Field>
      <Field label="Git hosts" hint="One per line: where a session may clone from and push to.">
        {(p) => <textarea {...p} value={form.gitHosts} onChange={(e) => set({ gitHosts: e.target.value })} rows={3} spellCheck={false} />}
      </Field>
      <Field label="Storage class" hint="Where a worker's disk comes from: one the cluster policy allows. Empty is the cluster's default. Fixed once pods exist.">
        {(p) => <input {...p} value={form.storageClass} onChange={(e) => set({ storageClass: e.target.value })} autoComplete="off" spellCheck={false} />}
      </Field>

      <Region>MCP servers</Region>
      <div className="servers">
        {servers.length === 0 && <p className="note">None of its own: sessions get what the bundle gives them.</p>}
        {servers.map((s, i) => (
          <fieldset key={i} className="server">
            <legend>Server {i + 1}</legend>
            {SERVER_FIELDS.map((f) => (
              <Field key={f} label={SERVER_LABELS[f]} hint={SERVER_HINTS[f]}>
                {(p) => (
                  <input
                    {...p}
                    value={s[f] === undefined || s[f] === null ? "" : String(s[f])}
                    onChange={(e) => {
                      setServers(servers.map((row, j) => (j === i ? { ...row, [f]: e.target.value } : row)));
                      if (f === "url") setChecked({ ...checked, [i]: "" });
                    }}
                    inputMode={f === "timeoutMs" ? "numeric" : undefined}
                    autoComplete="off"
                    spellCheck={false}
                  />
                )}
              </Field>
            ))}
            {Object.keys(s).some((k) => !(SERVER_FIELDS as readonly string[]).includes(k)) && (
              <p className="note">
                Kept as it is: {Object.keys(s)
                  .filter((k) => !(SERVER_FIELDS as readonly string[]).includes(k))
                  .join(", ")}
                .
              </p>
            )}
            <div className="actions">
              {typeof s["url"] === "string" && s["url"] !== "" && (
                <button
                  type="button"
                  onClick={() =>
                    admin.mcpCheck(String(s["url"])).then(
                      (answer) => setChecked({ ...checked, [i]: answer }),
                      (e: unknown) => setChecked({ ...checked, [i]: describeError(e) }),
                    )
                  }
                >
                  Can a pod reach it?
                </button>
              )}
              <button type="button" onClick={() => setServers(servers.filter((_, j) => j !== i))}>
                Remove server {i + 1}
              </button>
              {checked[i] && (
                <span className="hint" role="status">
                  {typeof checked[i] === "string"
                    ? checked[i]
                    : (checked[i] as { allowed: boolean }).allowed
                      ? `The egress policy allows ${(checked[i] as { host: string }).host}.`
                      : `The egress policy does not allow ${(checked[i] as { host: string }).host}: a session's calls to it would time out.`}
                </span>
              )}
            </div>
          </fieldset>
        ))}
        <button type="button" onClick={() => setServers([...servers, {}])}>
          Add a server
        </button>
      </div>

      <Region>Configuration</Region>
      <Field label="Bundle channel" hint="Which channel's agents, skills and servers its pods follow. Empty is stable.">
        {(p) => <input {...p} value={form.channel} onChange={(e) => set({ channel: e.target.value })} autoComplete="off" spellCheck={false} />}
      </Field>
      <Field label="Org volume" hint="Read-only, always: the volume the cluster policy names, for what every team may read.">
        {(p) => (
          <select {...p} value={String(form.orgMount)} onChange={(e) => set({ orgMount: e.target.value === "true" })}>
            <option value="false">not mounted</option>
            <option value="true">mounted</option>
          </select>
        )}
      </Field>
      <Field label="A repository's agents and skills" hint="Whether a working copy's .troupe/agents and .troupe/skills replace the bundle's of the same name.">
        {(p) => (
          <select {...p} value={String(form.repositoryOverridesBundle)} onChange={(e) => set({ repositoryOverridesBundle: e.target.value === "true" })}>
            <option value="false">lose to the bundle's</option>
            <option value="true">replace the bundle's</option>
          </select>
        )}
      </Field>
      <Field label="People's own signed-in tools" hint="Whether a person may offer a session here the MCP servers they signed in to on their own machine.">
        {(p) => (
          <select {...p} value={String(form.forbidPersonalTools)} onChange={(e) => set({ forbidPersonalTools: e.target.value === "true" })}>
            <option value="false">allowed</option>
            <option value="true">kept off these pods</option>
          </select>
        )}
      </Field>

      {Object.keys(kept).length > 0 && (
        <p className="note kept">
          Carried through unchanged, with no field here: {leaves(kept)
            .filter(([, v]) => !(isPlain(v) && Object.keys(v).length === 0))
            .map(([path]) => path)
            .join(", ")}
          .
        </p>
      )}
      {error !== null && (
        <p className="field-error" role="alert">
          {describeError(error)}
        </p>
      )}
      <div className="actions">
        <button type="submit" className="primary" disabled={blocked || asking}>
          {asking ? "Asking the plane…" : "Preview"}
        </button>
        <button type="button" onClick={onCancel}>
          Cancel
        </button>
      </div>
    </form>
  );
}

const SERVER_LABELS: Record<(typeof SERVER_FIELDS)[number], string> = {
  name: "Name",
  url: "URL",
  credentialRef: "Credential variable",
  header: "Header",
  timeoutMs: "Timeout (ms)",
};

const SERVER_HINTS: Record<(typeof SERVER_FIELDS)[number], string> = {
  name: "What sessions call it.",
  url: "https:// or a cluster-internal http:// .svc address.",
  credentialRef: "The environment variable the pod finds its token in; the token is a Secret the operator mounts.",
  header: "Where the token goes. Empty is authorization.",
  timeoutMs: "Empty is 30000.",
};

function effectsOf(policy: { "allowed?": boolean; violations: unknown[] }, mode: string, draft: ProfileWrite, detail: ProfileDetail | null, lines: DiffLine[]): string[] {
  const out: string[] = [];
  if (!policy["allowed?"]) for (const v of policy.violations) out.push(`The plane will refuse this: ${violation(v)}.`);
  const theirs = lines.filter((l) => NOT_SENT.includes(l.field.split(".")[1] ?? "") && l.field.startsWith("spec.")).map((l) => l.field);
  if (theirs.length) out.push(`${theirs.join(", ")} ${theirs.length === 1 ? "is" : "are"} the plane's to write, from the size class and what runs: not sent back, and written again by the plane.`);
  out.push(mode === "direct" ? "Applying changes the cluster now. Running sessions keep the pods they are on." : "This plane did not say how it provisions; applying may not reach the cluster.");
  if (detail === null) out.push(`No team may use ${draft.name} until a platform admin grants it to one, on the team's Access tab.`);
  const channel = String(draft.spec?.["configBundleChannel"] ?? "stable");
  if (detail && channel !== String(detail.spec?.["configBundleChannel"] ?? detail.bundle?.channel ?? "stable")) out.push(`Its pods follow ${channel} from now, and are told to update.`);
  return out;
}
