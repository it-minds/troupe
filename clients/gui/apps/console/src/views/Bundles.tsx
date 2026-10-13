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
// Publishing takes the document as the plane does, as JSON: checked first with the plane's
// own validation, then previewed with the plane's diff against the current version and the
// teams that lose an entry they were allowed because the new version no longer has it. A
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
import { bundleErrors } from "@troupe/client";
import type { AdminProfile, BundleDetail, BundlePreview, BundleSummary } from "@troupe/client";
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
  const [text, setText] = useState(() => JSON.stringify(initial, null, 2));
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

  return (
    <form
      className="edit bundle-editor"
      aria-label={`A new version of ${channel}`}
      onSubmit={(e) => {
        e.preventDefault();
        let content: unknown;
        try {
          content = JSON.parse(text);
        } catch {
          setProblems(["That is not JSON: the document is an object with schema, agents, skills and mcp_servers."]);
          return;
        }
        if (typeof content !== "object" || content === null || Array.isArray(content)) {
          setProblems(["The document is a JSON object, with schema, agents, skills and mcp_servers."]);
          return;
        }
        const doc = content as Record<string, unknown>;
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
      <Field
        label="The bundle document"
        hint="As the plane takes it, in JSON: its agents, skills and MCP servers. It is checked as publishing checks it before anything is published."
        error={problems ? problems.join(" ") : null}
      >
        {(p) => <textarea {...p} className="mono source" value={text} onChange={(e) => setText(e.target.value)} rows={18} spellCheck={false} />}
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

function publishWords(channel: string, preview: BundlePreview, profiles: string[]): string[] {
  const out: string[] = [];
  for (const l of preview.losers) out.push(`${l.team} loses the ${l.kind.replace("_", " ")} ${l.name} on ${l.profile}: its grant allows an entry this version no longer has.`);
  out.push(profiles.length ? `Every pod on ${profiles.join(", ")} is told to update, and new sessions there get this version.` : `No profile follows ${channel} yet: nothing runs it until one does.`);
  out.push("Sessions already running keep the version they started on.");
  out.push("History is append-only: this is a new version, and an older one's content can be published again later.");
  return out;
}
