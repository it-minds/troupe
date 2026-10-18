// Configuration bundles: the channels, a channel's versions, a version's contents, and
// publishing one.
//
// A profile follows a channel, not a version, so the channels are the profiles' channels
// (stable where a profile names none), each with its current version, when it was
// published and which profiles follow it. A version reads whole: its agents, skills and
// MCP servers, the Secret each server's credential needs, what changed from the version
// before it, and which profiles use it, with the pods that report it and those still
// behind.
//
// Publishing builds the document as the plane takes it: its agents in a builder (#594), each
// a form over the definition the daemon reads, checked by the plane with the daemon's own
// agent rules before it is kept, and the rest, its skills and MCP servers, as JSON. The
// whole is checked first with the plane's own validation, then previewed with the plane's
// diff against the current version and the teams that lose an entry they were allowed
// because the new version no longer has it. A
// publish that takes something away from a team is confirmed by typing the channel's name;
// otherwise a plain confirm, since history is append-only and a rollback is publishing an
// older version's content again, which a version's page offers. Retiring a version is a
// plain confirm too: nothing new starts on it, and sessions on it are untouched. Each is
// shown as the audit recorded it.
//
// A team admin reads the channels their teams' profiles follow, as the plane lets them;
// publishing and retiring are a platform admin's.

import { useState } from "react";
import type { JSX } from "react";
import { agentTemplate, bundleErrors, parseAgent, withBody, withFields } from "@troupe/client";
import type { AdminProfile, AgentFinding, BundleDetail, BundlePreview, BundleSummary } from "@troupe/client";
import { go, href } from "../route";
import { describeError, recorded, show, useConsole, useLoad } from "../console";
import { AuditNote, Diff, Empty, Field, Fields, Loaded, Preview, Region, Status, count, linesOf, useChange, when } from "./bits";
import type { Done } from "./bits";

/** The channels worth listing: every one a profile follows, and stable, which a profile naming none follows. */
function channelsOf(profiles: AdminProfile[]): string[] {
  return [...new Set(["stable", ...profiles.map((p) => p.channel ?? "stable")])].sort((a, b) => (a === "stable" ? -1 : b === "stable" ? 1 : a.localeCompare(b)));
}

/** The newest version that is not retired: what a new session on the channel gets. */
function currentOf(versions: BundleSummary[]): BundleSummary | null {
  return versions.find((v) => v.retired_at === null) ?? null;
}

function carries(summary: BundleSummary["summary"]): string {
  const n = (k: string) => (Array.isArray(summary?.[k]) ? (summary![k] as unknown[]).length : 0);
  return [count(n("agents"), "agent"), count(n("skills"), "skill"), count(n("mcp_servers"), "MCP server")].join(" · ");
}

// -- the channels ------------------------------------------------------------------------

export function Bundles(): JSX.Element {
  const { admin } = useConsole();
  const [load, reload] = useLoad(async () => {
    const profiles = await admin.profiles();
    const channels = channelsOf(profiles);
    const versions = await Promise.all(channels.map((c) => admin.bundles(c)));
    return { profiles, rows: channels.map((c, i) => ({ channel: c, versions: versions[i]! })) };
  }, [admin]);
  const [other, setOther] = useState("");

  return (
    <div className="page">
      <p className="lead">A bundle is a versioned set of agents, skills and MCP servers. A profile follows a channel, not a version: publishing to a channel reaches every pod on it.</p>
      <Loaded load={load} what="the channels" retry={reload}>
        {({ profiles, rows }) => (
          <div className="scroll">
            <table className="channels">
              <thead>
                <tr>
                  <th>Channel</th>
                  <th>Current</th>
                  <th>Carries</th>
                  <th>Published</th>
                  <th>Profiles</th>
                </tr>
              </thead>
              <tbody>
                {rows.map(({ channel, versions }) => {
                  const current = currentOf(versions);
                  const following = profiles.filter((p) => (p.channel ?? "stable") === channel).map((p) => p.name);
                  return (
                    <tr key={channel}>
                      <td>
                        <a href={href({ page: "bundles", path: [channel] })}>{channel}</a>
                      </td>
                      <td>{current ? `v${current.version}` : <span className="muted">nothing published</span>}</td>
                      <td>{current ? carries(current.summary) : "—"}</td>
                      <td>{current ? `${when(current.published_at)} by ${show(current.published_by)}` : "—"}</td>
                      <td>{following.join(", ") || <span className="muted">none</span>}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </Loaded>
      <form
        className="edit"
        onSubmit={(e) => {
          e.preventDefault();
          if (other.trim()) go({ page: "bundles", path: [other.trim()] });
        }}
      >
        <Field label="Another channel" hint="A channel no profile follows yet, by its name: to read it, or to publish its first version.">
          {(p) => <input {...p} value={other} onChange={(e) => setOther(e.target.value)} autoComplete="off" spellCheck={false} />}
        </Field>
        <div className="actions">
          <button type="submit" disabled={!other.trim()}>
            Open
          </button>
        </div>
      </form>
    </div>
  );
}

// -- a channel ---------------------------------------------------------------------------

export function Channel({ channel }: { channel: string }): JSX.Element {
  const { admin, role } = useConsole();
  const platform = role === "platform_admin";
  const [load, reload] = useLoad(() => Promise.all([admin.bundles(channel), admin.profiles()]), [admin, channel]);
  const [publishing, setPublishing] = useState<Record<string, unknown> | null>(null);
  const { done, apply } = useChange(reload);

  return (
    <div className="page">
      <p className="team-meta">
        <a href={href({ page: "bundles" })}>All channels</a>
      </p>
      {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
      <Loaded load={load} what={`the ${channel} channel`} retry={reload}>
        {([versions, profiles]) => {
          const current = currentOf(versions);
          const following = profiles.filter((p) => (p.channel ?? "stable") === channel);
          return (
            <>
              <Fields
                rows={[
                  ["Current", current ? <a href={href({ page: "bundles", path: [channel, String(current.version)] })}>v{current.version}</a> : "nothing published"],
                  ["It carries", current ? carries(current.summary) : "—"],
                  ["Versions", String(versions.length)],
                  ["Profiles that follow it", following.length ? following.map((p) => p.name).join(", ") : "none"],
                ]}
              />
              <Region>Versions</Region>
              {versions.length === 0 ? (
                <Empty title="Nothing published on this channel">{platform ? "Publish its first version below." : "A platform admin publishes one."}</Empty>
              ) : (
                <div className="scroll">
                  <table className="versions">
                    <thead>
                      <tr>
                        <th>Version</th>
                        <th>State</th>
                        <th>Carries</th>
                        <th>Published</th>
                        <th>Hash</th>
                      </tr>
                    </thead>
                    <tbody>
                      {versions.map((v) => (
                        <tr key={v.version}>
                          <td>
                            <a href={href({ page: "bundles", path: [channel, String(v.version)] })}>v{v.version}</a>
                          </td>
                          <td>
                            <VersionState version={v} current={current} />
                          </td>
                          <td>{carries(v.summary)}</td>
                          <td>
                            {when(v.published_at)} by {show(v.published_by)}
                          </td>
                          <td className="mono">{v.hash}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
              {platform && publishing === null && !current && (
                <button type="button" onClick={() => setPublishing(BLANK)}>
                  {versions.length ? "Publish a new version" : "Publish the first version"}
                </button>
              )}
              {platform && publishing === null && current && <PublishFrom channel={channel} version={current.version} onOpen={setPublishing} />}
              {publishing !== null && (
                <BundleEditor
                  channel={channel}
                  initial={publishing}
                  profiles={following.map((p) => p.name)}
                  onCancel={() => setPublishing(null)}
                  onPublish={async (content) => {
                    await apply("bundle.publish", channel, () => admin.publishBundle(channel, content), `A new version of ${channel} is published.`);
                    setPublishing(null);
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

const BLANK: Record<string, unknown> = { schema: 1, agents: [], skills: [], mcp_servers: [] };

/** Publishing starts from the current version's document, read whole first. */
function PublishFrom({ channel, version, onOpen }: { channel: string; version: number; onOpen: (content: Record<string, unknown>) => void }): JSX.Element {
  const { admin } = useConsole();
  const [error, setError] = useState<unknown>(null);
  return (
    <>
      <button
        type="button"
        onClick={() =>
          admin.bundle(channel, version).then(
            (b) => onOpen(b.content),
            (e: unknown) => setError(e),
          )
        }
      >
        Publish a new version
      </button>
      {error !== null && (
        <p className="field-error" role="alert">
          {describeError(error)}
        </p>
      )}
    </>
  );
}

function VersionState({ version, current }: { version: BundleSummary; current: BundleSummary | null }): JSX.Element {
  if (version.retired_at) {
    return (
      <Status kind="muted" glyph="○">
        retired {when(version.retired_at)}
      </Status>
    );
  }
  if (current && version.version === current.version) {
    return (
      <Status kind="running" glyph="●">
        current
      </Status>
    );
  }
  return (
    <Status kind="dormant" glyph="◑">
      older
    </Status>
  );
}

// -- a version ---------------------------------------------------------------------------

export function Version({ channel, version }: { channel: string; version: number }): JSX.Element {
  const { admin, me, role, notify } = useConsole();
  const platform = role === "platform_admin";
  const [load, reload] = useLoad(async () => {
    const [bundle, versions] = await Promise.all([admin.bundle(channel, version), admin.bundles(channel)]);
    const before = versions.find((v) => v.version < version);
    // What changed from the version before it, from the plane's diff. A version an older
    // plane published may not validate any more, and has no diff to show.
    const changed = before ? await admin.previewBundle(channel, bundle.content, before.version).catch(() => null) : null;
    return { bundle, versions, before: before?.version ?? null, changed };
  }, [admin, channel, version]);
  const [retiring, setRetiring] = useState(false);
  const [republishing, setRepublishing] = useState(false);
  const [done, setDone] = useState<Done | null>(null);

  return (
    <div className="page">
      <p className="team-meta">
        <a href={href({ page: "bundles", path: [channel] })}>All of {channel}</a>
      </p>
      {done && <AuditNote action={done.action} subject={done.subject} detail={done.detail} />}
      <Loaded load={load} what={`${channel} v${version}`} retry={reload}>
        {({ bundle, versions, before, changed }) => {
          const current = currentOf(versions);
          const isCurrent = current?.version === bundle.version;
          return (
            <>
              <Fields
                rows={[
                  ["State", <VersionState version={bundle} current={current} />],
                  ["Published", `${when(bundle.published_at)} by ${show(bundle.published_by)}`],
                  ["Hash", <span className="mono">{bundle.hash}</span>],
                  ["Carries", carries(bundle.summary)],
                ]}
              />
              <Contents bundle={bundle} />

              <Region>Which profiles use it</Region>
              <Adoption bundle={bundle} isCurrent={isCurrent} />

              <Region>{before === null ? "The first version" : `What changed from v${before}`}</Region>
              {before === null ? (
                <p className="note">Nothing was published on {channel} before it.</p>
              ) : changed ? (
                <Diff title={`${channel} v${before} → v${bundle.version}`} lines={linesOf(changed.changes)} />
              ) : (
                <p className="note">v{before} cannot be compared with it here: one of the two no longer validates.</p>
              )}

              {platform && !retiring && !republishing && (
                <div className="actions">
                  {!isCurrent && (
                    <button type="button" onClick={() => setRepublishing(true)}>
                      Publish this content again
                    </button>
                  )}
                  {!bundle.retired_at && (
                    <button type="button" onClick={() => setRetiring(true)}>
                      Retire v{bundle.version}
                    </button>
                  )}
                </div>
              )}
              {republishing && (
                <BundleEditor
                  channel={channel}
                  initial={bundle.content}
                  profiles={bundle.adoption.map((a) => String(a.profile ?? "")).filter(Boolean)}
                  onCancel={() => setRepublishing(false)}
                  onPublish={async (content) => {
                    const published = await admin.publishBundle(channel, content);
                    setRepublishing(false);
                    setDone({ action: "bundle.publish", subject: channel, detail: await recorded(admin, me.subject, "bundle.publish", channel) });
                    notify(`v${bundle.version}'s content is published again as v${published.version}.`);
                    reload();
                  }}
                />
              )}
              {retiring && (
                <Preview
                  title={`bundle/${channel}`}
                  lines={[{ field: `v${bundle.version}`, from: "live", to: "retired" }]}
                  effects={[
                    `Nothing new starts on v${bundle.version}; sessions already running on it are untouched.`,
                    isCurrent ? (versions.find((v) => v.version < bundle.version && !v.retired_at) ? `${channel}'s current version becomes v${versions.find((v) => v.version < bundle.version && !v.retired_at)!.version}.` : `${channel} has no live version after this: a new session on it gets no bundle.`) : `${channel}'s current version stays v${current?.version ?? "—"}.`,
                    "A retired version stays retired: to bring its content back, publish it again as a new version.",
                  ]}
                  verb={`Retire v${bundle.version}`}
                  onCancel={() => setRetiring(false)}
                  onConfirm={async () => {
                    await admin.retireBundle(channel, bundle.version);
                    setRetiring(false);
                    setDone({ action: "bundle.retire", subject: channel, detail: await recorded(admin, me.subject, "bundle.retire", channel) });
                    notify(`v${bundle.version} of ${channel} is retired.`);
                    reload();
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

function Contents({ bundle }: { bundle: BundleDetail }): JSX.Element {
  const d = bundle.detail;
  if (!d) {
    return <p className="note">This version was published by an older plane and cannot be read in full here.</p>;
  }
  return (
    <>
      <Region>Agents</Region>
      {(d.agents ?? []).length === 0 ? (
        <Empty title="No agent" />
      ) : (
        <div className="scroll">
          <table>
            <thead>
              <tr>
                <th>Agent</th>
                <th>Mode</th>
                <th>What it is for</th>
                <th>Skills</th>
              </tr>
            </thead>
            <tbody>
              {d.agents!.map((a) => (
                <tr key={a.name}>
                  <td>{a.name}</td>
                  <td>{show(a.mode)}</td>
                  <td>{show(a.description)}</td>
                  <td>{show(a.skills)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <Region>Skills</Region>
      {(d.skills ?? []).length === 0 ? (
        <Empty title="No skill" />
      ) : (
        <div className="scroll">
          <table>
            <thead>
              <tr>
                <th>Skill</th>
                <th>What it is for</th>
                <th>Files</th>
              </tr>
            </thead>
            <tbody>
              {d.skills!.map((s) => (
                <tr key={s.name}>
                  <td>{s.name}</td>
                  <td>{show(s.description)}</td>
                  <td className="mono">{show(s.files)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <Region>MCP servers</Region>
      {(d.mcp_servers ?? []).length === 0 ? (
        <Empty title="No MCP server" />
      ) : (
        <div className="scroll">
          <table>
            <thead>
              <tr>
                <th>Server</th>
                <th>URL</th>
                <th>Credential</th>
                <th>Permission</th>
                <th>Tools</th>
              </tr>
            </thead>
            <tbody>
              {d.mcp_servers!.map((m) => (
                <tr key={m.name}>
                  <td>{m.name}</td>
                  <td className="mono">{m.url}</td>
                  <td className="mono">{m.credential_ref ? `${m.credential_ref}${m.secret ? `, from the Secret ${m.secret}` : ""}` : "—"}</td>
                  <td>{show(m.permission)}</td>
                  <td>{m.tools && m.tools.length ? m.tools.join(", ") : "all it offers"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}

function Adoption({ bundle, isCurrent }: { bundle: BundleDetail; isCurrent: boolean }): JSX.Element {
  const { role } = useConsole();
  if (bundle.adoption.length === 0) return <Empty title="No profile follows this channel" />;
  return (
    <div className="scroll">
      <table className="adoption">
        <thead>
          <tr>
            <th>Profile</th>
            <th className="num">Pods</th>
            <th>Report this version</th>
            <th>Behind</th>
          </tr>
        </thead>
        <tbody>
          {bundle.adoption.map((a) => {
            const name = String(a.profile ?? "");
            const stale = a.stale ?? [];
            return (
              <tr key={name}>
                <td>{role === "platform_admin" ? <a href={href({ page: "profiles", path: [name] })}>{name}</a> : name}</td>
                <td className="num">{show(a.pods ?? 0)}</td>
                <td>{(a.current ?? []).length ? (a.current ?? []).join(", ") : <span className="muted">none</span>}</td>
                <td>
                  {stale.length
                    ? stale.map((s) => `${s.pod} (on ${show(s.reported)})`).join(", ")
                    : isCurrent
                      ? (
                          <Status kind="running" glyph="●">
                            none
                          </Status>
                        )
                      : "—"}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

// -- publishing --------------------------------------------------------------------------

/** A bundle's agent in a draft: its name, its definition, and whatever else its entry says (`override`). */
interface DraftAgent {
  name: string;
  definition: string;
  rest: Record<string, unknown>;
}

function agentsOf(content: Record<string, unknown>): DraftAgent[] {
  const listed = Array.isArray(content["agents"]) ? (content["agents"] as unknown[]) : [];
  return listed
    .filter((a): a is Record<string, unknown> => typeof a === "object" && a !== null)
    .map(({ name, definition, ...rest }) => ({ name: String(name ?? ""), definition: typeof definition === "string" ? definition : "", rest }));
}

/** The document without its agents, which the builder holds: what the JSON below it edits. */
function withoutAgents(content: Record<string, unknown>): Record<string, unknown> {
  const { agents: _agents, ...rest } = content;
  return rest;
}

/** The draft whole again: the JSON's keys, and the builder's agents where the document had them. */
function draftOf(rest: Record<string, unknown>, agents: DraftAgent[], had: boolean): Record<string, unknown> {
  if (!had && agents.length === 0) return rest;
  return { ...rest, agents: agents.map((a) => ({ name: a.name, definition: a.definition, ...a.rest })) };
}

function BundleEditor({
  channel,
  initial,
  profiles,
  onCancel,
  onPublish,
}: {
  channel: string;
  initial: Record<string, unknown>;
  profiles: string[];
  onCancel: () => void;
  onPublish: (content: Record<string, unknown>) => Promise<void>;
}): JSX.Element {
  const { admin } = useConsole();
  const had = Array.isArray(initial["agents"]);
  const [agents, setAgents] = useState<DraftAgent[]>(() => agentsOf(initial));
  const [editing, setEditing] = useState<number | "new" | null>(null);
  const [text, setText] = useState(() => JSON.stringify(withoutAgents(initial), null, 2));
  const [problems, setProblems] = useState<string[] | null>(null);
  const [checked, setChecked] = useState<{ content: Record<string, unknown>; preview: BundlePreview } | null>(null);
  const [asking, setAsking] = useState(false);

  if (checked) {
    const { preview, content } = checked;
    return (
      <Preview
        title={`bundle/${channel} ${preview.from === null ? "(first version)" : `v${preview.from} → next`}`}
        lines={linesOf(preview.changes)}
        effects={publishWords(channel, preview, profiles)}
        verb={`Publish to ${channel}`}
        typeToConfirm={preview.losers.length ? channel : null}
        onCancel={() => setChecked(null)}
        onConfirm={() => onPublish(content)}
      />
    );
  }

  const keep = (index: number | "new", agent: DraftAgent): void => {
    setAgents((list) => (index === "new" ? [...list, agent] : list.map((a, i) => (i === index ? agent : a))));
    setEditing(null);
    setProblems(null);
  };

  return (
    <form
      className="edit bundle-editor"
      aria-label={`A new version of ${channel}`}
      onSubmit={(e) => {
        e.preventDefault();
        let rest: unknown;
        try {
          rest = JSON.parse(text);
        } catch {
          setProblems(["That is not JSON: the rest of the document is an object with schema, skills and mcp_servers."]);
          return;
        }
        if (typeof rest !== "object" || rest === null || Array.isArray(rest)) {
          setProblems(["The rest of the document is a JSON object, with schema, skills and mcp_servers."]);
          return;
        }
        if ("agents" in rest) {
          setProblems(["The agents are the builder's, above: take agents out of the document and add them there."]);
          return;
        }
        if (editing !== null) {
          setProblems(["Keep or cancel the agent being edited first."]);
          return;
        }
        const doc = draftOf(rest as Record<string, unknown>, agents, had);
        setAsking(true);
        setProblems(null);
        // Validated first, for the plane's sentence per problem; then the diff and who loses what.
        const checking = admin.validateBundle(doc).then(() => admin.previewBundle(channel, doc));
        checking.then(
          (preview) => {
            setAsking(false);
            setChecked({ content: doc, preview });
          },
          (err: unknown) => {
            setAsking(false);
            setProblems(bundleErrors(err) ?? [describeError(err)]);
          },
        );
      }}
    >
      <Region>Its agents</Region>
      <p className="note">
        Each one is a definition the daemon would accept: Markdown with frontmatter, checked here by the rules it checks a person's agent with. A
        profile usually runs one primary agent, and the subagents it delegates to.
      </p>
      {agents.length === 0 ? (
        <Empty title="No agent">A session on this channel runs the agents Troupe ships.</Empty>
      ) : (
        <div className="scroll">
          <table className="draft-agents">
            <thead>
              <tr>
                <th>Agent</th>
                <th>Mode</th>
                <th>What it is for</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {agents.map((a, i) => {
                const fields = parseAgent(a.definition).fields;
                return (
                  <tr key={`${a.name}-${i}`}>
                    <td className="mono">{a.name}</td>
                    <td>{show(fields?.mode || null)}</td>
                    <td>{show(fields?.description || null)}</td>
                    <td className="actions">
                      <button type="button" onClick={() => setEditing(i)} disabled={editing !== null}>
                        Edit {a.name}
                      </button>
                      <button type="button" onClick={() => setAgents((list) => list.filter((_, j) => j !== i))} disabled={editing !== null}>
                        Remove {a.name}
                      </button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      {editing === null ? (
        <div className="actions">
          <button type="button" onClick={() => setEditing("new")}>
            Add an agent
          </button>
        </div>
      ) : (
        <AgentBuilder
          key={String(editing)}
          initial={editing === "new" ? null : agents[editing]!}
          taken={agents.filter((_, i) => i !== editing).map((a) => a.name)}
          onKeep={(agent) => keep(editing, agent)}
          onCancel={() => setEditing(null)}
        />
      )}

      <Region>The rest of the bundle</Region>
      <Field
        label="Skills and MCP servers"
        hint="As the plane takes them, in JSON: the document without its agents, which are the builder's above. It is checked as publishing checks it before anything is published."
        error={problems ? problems.join(" ") : null}
      >
        {(p) => <textarea {...p} className="mono source" value={text} onChange={(e) => setText(e.target.value)} rows={14} spellCheck={false} />}
      </Field>
      {problems && problems.length > 1 && (
        <ul className="effects" role="alert">
          {problems.map((m) => (
            <li key={m}>{m}</li>
          ))}
        </ul>
      )}
      <div className="actions">
        <button type="submit" className="primary" disabled={asking}>
          {asking ? "Checking…" : "Check and preview"}
        </button>
        <button type="button" onClick={onCancel}>
          Cancel
        </button>
      </div>
    </form>
  );
}

/** What the builder's fields are called where a finding names them. */
const BUILDER_FIELDS = ["name", "mode", "description", "model", "tools", "prompt"] as const;

/**
 * One agent of the draft as fields (troupe #594): its name, whether it is a primary agent
 * or a subagent, what it is for, its model, its tools and its instruction. The definition
 * it makes is shown as the file it is, every line the fields do not edit kept as the
 * definition had it, and it is checked by the plane with the rules the daemon's
 * `agents.validate` applies before it is kept, each finding at its field in the daemon's
 * words. A definition the fields cannot read is edited as its text.
 */
function AgentBuilder({
  initial,
  taken,
  onKeep,
  onCancel,
}: {
  initial: DraftAgent | null;
  taken: string[];
  onKeep: (agent: DraftAgent) => void;
  onCancel: () => void;
}): JSX.Element {
  const { admin } = useConsole();
  const base = initial?.definition || agentTemplate();
  const parsed = parseAgent(base);
  const [name, setName] = useState(initial?.name ?? "");
  const [mode, setMode] = useState(parsed.fields?.mode || "primary");
  const [description, setDescription] = useState(parsed.fields?.description ?? "");
  const [model, setModel] = useState(parsed.fields?.model ?? "");
  const [tools, setTools] = useState(parsed.fields && parsed.fields.tools !== "all" ? parsed.fields.tools.join("\n") : "");
  const [prompt, setPrompt] = useState(parsed.body);
  const [raw, setRaw] = useState(base);
  const [findings, setFindings] = useState<AgentFinding[] | null>(null);
  const [warnings, setWarnings] = useState<AgentFinding[]>([]);
  const [asking, setAsking] = useState(false);
  const formed = parsed.fields !== null;

  const listed = tools
    .split(/[\n,]/)
    .map((t) => t.trim())
    .filter(Boolean);
  const definition = formed ? withBody(withFields(base, { mode, description, model, tools: listed.length ? listed : "all" }), prompt) : raw;
  const at = (field: string): string | null => {
    const found = (findings ?? []).filter((f) => f.field === field);
    return found.length ? found.map((f) => f.message).join(" ") : null;
  };
  const elsewhere = (findings ?? []).filter((f) => !(BUILDER_FIELDS as readonly string[]).includes(f.field) || !formed);

  const check = async (): Promise<void> => {
    if (taken.includes(name)) {
      setFindings([{ field: "name", message: `${name} is in this draft already: an agent's name is its own` }]);
      return;
    }
    setAsking(true);
    try {
      const result = await admin.checkAgent(name, definition);
      setWarnings(result.warnings);
      if (result.ok) onKeep({ name, definition, rest: initial?.rest ?? {} });
      else setFindings(result.errors);
    } catch (e) {
      setFindings([{ field: "", message: describeError(e) }]);
    } finally {
      setAsking(false);
    }
  };

  return (
    <div className="agent-builder" role="group" aria-label={initial ? `Edit ${initial.name}` : "A new agent"}>
      <Field label="Name" hint="Lowercase letters, digits and dashes: what a session and a grant name it by." error={at("name")}>
        {(p) => <input {...p} value={name} onChange={(e) => setName(e.target.value)} autoComplete="off" spellCheck={false} />}
      </Field>
      {formed ? (
        <>
          <Field label="Mode" hint="A primary agent is what a session runs; a subagent is one an agent delegates to." error={at("mode")}>
            {(p) => (
              <select {...p} value={mode} onChange={(e) => setMode(e.target.value)}>
                <option value="primary">primary</option>
                <option value="subagent">subagent</option>
              </select>
            )}
          </Field>
          <Field label="Description" hint="One line, which a picker shows beside the name." error={at("description")}>
            {(p) => <input {...p} value={description} onChange={(e) => setDescription(e.target.value)} />}
          </Field>
          <Field label="Model" hint="A model the profile's provider serves, or empty for the session's own." error={at("model")}>
            {(p) => <input {...p} value={model} onChange={(e) => setModel(e.target.value)} autoComplete="off" spellCheck={false} />}
          </Field>
          <Field label="Tools" hint="One per line; empty is every tool the harness has." error={at("tools")}>
            {(p) => <textarea {...p} className="mono" value={tools} onChange={(e) => setTools(e.target.value)} rows={4} spellCheck={false} />}
          </Field>
          <Field label="Instruction" hint="What it is told: the definition's body." error={at("prompt")}>
            {(p) => <textarea {...p} value={prompt} onChange={(e) => setPrompt(e.target.value)} rows={8} />}
          </Field>
        </>
      ) : (
        <Field label="Definition" hint={parsed.problem ?? "Markdown with frontmatter."} error={null}>
          {(p) => <textarea {...p} className="mono source" value={raw} onChange={(e) => setRaw(e.target.value)} rows={12} spellCheck={false} />}
        </Field>
      )}
      {elsewhere.length > 0 && (
        <ul className="effects" role="alert">
          {elsewhere.map((f) => (
            <li key={`${f.field}:${f.message}`}>{f.message}</li>
          ))}
        </ul>
      )}
      {warnings.length > 0 && (
        <ul className="effects" aria-label="Not checked">
          {warnings.map((f) => (
            <li key={`${f.field}:${f.message}`}>{f.message}</li>
          ))}
        </ul>
      )}
      <Region>The file it makes</Region>
      <pre className="mono source" aria-label="The definition">
        {definition}
      </pre>
      <div className="actions">
        <button type="button" className="primary" disabled={asking || !name} onClick={() => void check()}>
          {asking ? "Checking…" : initial ? `Check and keep ${name}` : "Check and add it"}
        </button>
        <button type="button" onClick={onCancel}>
          Cancel the agent
        </button>
      </div>
    </div>
  );
}

function publishWords(channel: string, preview: BundlePreview, profiles: string[]): string[] {
  const out: string[] = [];
  for (const l of preview.losers) out.push(`${l.team} loses the ${l.kind.replace("_", " ")} ${l.name} on ${l.profile}: its grant allows an entry this version no longer has.`);
  out.push(profiles.length ? `Every pod on ${profiles.join(", ")} is told to update, and new sessions there get this version.` : `No profile follows ${channel} yet: nothing runs it until one does.`);
  out.push("Sessions already running keep the version they started on.");
  out.push("History is append-only: this is a new version, and an older one's content can be published again later.");
  return out;
}
