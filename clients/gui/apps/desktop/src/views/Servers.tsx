// Your own MCP servers and skills, on this computer.
//
// The daemon keeps them in two layers of files — yours, beside `config.yaml`, and a
// workspace's `.troupe/` — in the shape Claude Code, Claude Desktop, Cursor and VS Code
// already write, and this panel is a form over the seven methods that read and write
// them (troupe-remote Decision 700). It holds no path of its own: what is typed here
// is a file to import or a directory of skills to bring in, and the daemon does the
// reading, so the TUI's `/mcp` page shows the same set.
//
// A server's environment never comes back: the daemon answers with the names of its
// variables, and that is all this screen shows.

import { useCallback, useState } from "react";
import type { JSX } from "react";
import type { DaemonClient, LocalServer, LocalSkill, ScopedParams, SourceScope } from "@troupe/client";
import { useAdminQuery } from "../hooks";
import { Failed, Loading, Pill, Table } from "./bits";
import type { Status } from "./bits";

/** A server's state as a glyph and a word, the way every status on these screens is. */
function ServerState({ server }: { server: LocalServer }): JSX.Element {
  const [status, word]: [Status, string] = server.disabled
    ? ["offline", "Disabled"]
    : server.refused
      ? ["error", "Refused"]
      : server.state === "ready"
        ? ["running", "Ready"]
        : server.state === "error"
          ? ["error", "Failed"]
          : server.state === "pending"
            ? ["waiting", "Needs approval"]
            : server.state === "connecting"
              ? ["queued", "Connecting"]
              : server.state === "stopped"
                ? ["dormant", "Stopped"]
                : ["dormant", "Not checked"];
  return <Pill status={status}>{word}</Pill>;
}

function runs(server: LocalServer): string {
  if (server.url) return server.url;
  if (server.command) return [server.command, ...(server.args ?? [])].join(" ");
  return "";
}

export function Servers({ client }: { client: DaemonClient }): JSX.Element {
  const [workspace, setWorkspace] = useState("");
  const [scope, setScope] = useState<SourceScope>("user");
  const [round, setRound] = useState(0);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [outcome, setOutcome] = useState<string | null>(null);
  // What a check answered, by server name: the live state rides on the row.
  const [checked, setChecked] = useState<Record<string, LocalServer>>({});

  const ws = workspace.trim();
  const load = useCallback(async () => {
    const [servers, skills] = await Promise.all([client.listServers(ws ? { workspace: ws } : {}), client.listSkills(ws || undefined)]);
    return { servers: servers.servers, warnings: servers.warnings, skills: skills.skills };
  }, [client, ws]);
  const { data, loading, error: readError } = useAdminQuery(load, [load, round]);

  const act = async (what: string, run: () => Promise<string>): Promise<void> => {
    setBusy(what);
    setError(null);
    setOutcome(null);
    try {
      setOutcome(await run());
      setRound((n) => n + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const scoped = <T extends object>(params: T): T & ScopedParams => ({ scope, ...(scope === "workspace" && ws ? { workspace: ws } : {}), ...params });

  const describeImport = (r: { added: string[]; skipped: Array<{ name: string; reason: string }>; warnings?: string[]; linked: boolean; path: string }): string => {
    const head = `${r.linked ? "Linked" : "Imported"} ${r.added.length ? r.added.join(", ") : "nothing"} into ${r.path}.`;
    const skipped = r.skipped.length ? ` Skipped ${r.skipped.map((s) => `${s.name} (${s.reason})`).join("; ")}.` : "";
    const warned = r.warnings?.length ? ` ${r.warnings.join(" ")}` : "";
    return head + skipped + warned;
  };

  const check = (server: LocalServer): Promise<void> =>
    act(`check:${server.name}`, async () => {
      const { server: result } = await client.checkServer(ws ? { workspace: ws, name: server.name } : { name: server.name });
      setChecked((c) => ({ ...c, [server.name]: result }));
      return `${server.name}: ${result.state ?? "unknown"}${result.error ? ` — ${result.error}` : result.tools.length ? `, ${result.tools.length} tools` : ""}`;
    });

  const toggle = (server: LocalServer): Promise<void> =>
    act(`toggle:${server.name}`, async () => {
      const layer: SourceScope = server.layer === "workspace" ? "workspace" : "user";
      await client.writeServer({ scope: layer, ...(layer === "workspace" && ws ? { workspace: ws } : {}), name: server.name, server: { disabled: !server.disabled } });
      return `${server.name} ${server.disabled ? "enabled" : "disabled"}; a session reads the change when it starts, or on a check.`;
    });

  const removeServer = (server: LocalServer): Promise<void> =>
    act(`remove:${server.name}`, async () => {
      const layer: SourceScope = server.layer === "workspace" ? "workspace" : "user";
      const r = await client.removeServer({ scope: layer, ...(layer === "workspace" && ws ? { workspace: ws } : {}), name: server.name });
      return `Removed ${r.removed.join(", ")} from ${r.path}.`;
    });

  const removeSkill = (skill: LocalSkill): Promise<void> =>
    act(`remove-skill:${skill.name}`, async () => {
      const layer: SourceScope = skill.layer === "workspace" ? "workspace" : "user";
      const r = await client.removeSkill({ scope: layer, ...(layer === "workspace" && ws ? { workspace: ws } : {}), name: skill.name });
      return `Removed ${r.removed.join(", ")} from ${r.path}.`;
    });

  return (
    <section className="group">
      <h3>Servers and skills</h3>
      <p className="copy">
        MCP servers and skills you keep yourself, read by every session on this computer. Bring in what you already have for Claude
        Code, Claude Desktop, Cursor or VS Code: a <code className="mono">.mcp.json</code>, or a directory of skills such as{" "}
        <code className="mono">~/.claude/skills</code>. Copying puts them in your own files; linking reads them where they are.
      </p>

      <form className="inline-form" onSubmit={(e) => e.preventDefault()}>
        <label className="inline">
          Workspace
          <input value={workspace} onChange={(e) => setWorkspace(e.target.value)} placeholder="/home/me/project (optional)" spellCheck={false} />
        </label>
        <label className="inline">
          Write to
          <select value={scope} onChange={(e) => setScope(e.target.value as SourceScope)} aria-label="Scope">
            <option value="user">my files (every workspace)</option>
            <option value="workspace" disabled={!ws}>
              this workspace&apos;s .troupe/
            </option>
          </select>
        </label>
      </form>

      <ImportForm
        what="servers"
        label="File to import"
        placeholder="/home/me/.claude/.mcp.json"
        busy={busy}
        onImport={(from, link) => act(`import:${from}`, () => client.importServers(scoped({ from, link })).then(describeImport))}
      />
      <ImportForm
        what="skills"
        label="Directory of skills"
        placeholder="/home/me/.claude/skills"
        busy={busy}
        onImport={(from, link) => act(`skills:${from}`, () => client.importSkills(scoped({ from, link })).then(describeImport))}
      />

      <Failed error={readError ?? error} />
      {outcome && <p className="note">{outcome}</p>}
      {loading && !data && <Loading what="Reading your servers and skills…" />}

      {data && data.servers.length === 0 && !loading && <p className="note">No servers yet. Import a file above, or write mcp.json beside config.yaml by hand.</p>}
      {data && data.servers.length > 0 && (
        <Table head={["Server", "Layer", "Runs", "State", "Tools", ""]}>
          {data.servers.map((server) => {
            const live = checked[server.name] ?? server;
            const editable = server.layer === "user" || server.layer === "workspace";
            return (
              <tr key={server.name}>
                <th scope="row">{server.name}</th>
                <td>
                  {server.layer}
                  {server.trust === "pending" ? " (needs approval)" : ""}
                </td>
                <td className="mono micro">{runs(server)}</td>
                <td>
                  <ServerState server={{ ...server, state: live.state, error: live.error }} />
                  {live.error ? <span className="micro"> {live.error}</span> : null}
                </td>
                <td className="micro">{live.tools.join(", ")}</td>
                <td>
                  <button onClick={() => void check(server)} disabled={busy !== null || Boolean(server.refused)}>
                    {busy === `check:${server.name}` ? "Checking…" : "Check"}
                  </button>{" "}
                  {editable && (
                    <>
                      <button onClick={() => void toggle(server)} disabled={busy !== null}>
                        {server.disabled ? "Enable" : "Disable"}
                      </button>{" "}
                      <button className="danger" onClick={() => void removeServer(server)} disabled={busy !== null}>
                        Remove
                      </button>
                    </>
                  )}
                </td>
              </tr>
            );
          })}
        </Table>
      )}
      {data && data.warnings.length > 0 && (
        <ul className="note">
          {data.warnings.map((w) => (
            <li key={w}>{w}</li>
          ))}
        </ul>
      )}

      {data && data.skills.length === 0 && !loading && <p className="note">No skills yet.</p>}
      {data && data.skills.length > 0 && (
        <Table head={["Skill", "Layer", "Description", "Source", ""]}>
          {data.skills.map((skill) => (
            <tr key={`${skill.layer}:${skill.name}`}>
              <th scope="row">{skill.name}</th>
              <td>{skill.layer}</td>
              <td>{skill.description}</td>
              <td className="mono micro">
                {skill.source}
                {skill.linked ? " (linked)" : ""}
              </td>
              <td>
                <button className="danger" onClick={() => void removeSkill(skill)} disabled={busy !== null}>
                  Remove
                </button>
              </td>
            </tr>
          ))}
        </Table>
      )}
    </section>
  );
}

function ImportForm({
  what,
  label,
  placeholder,
  busy,
  onImport,
}: {
  what: string;
  label: string;
  placeholder: string;
  busy: string | null;
  onImport: (from: string, link: boolean) => Promise<void>;
}): JSX.Element {
  const [from, setFrom] = useState("");
  const path = from.trim();

  return (
    <form
      className="inline-form"
      onSubmit={(e) => {
        e.preventDefault();
        if (path) void onImport(path, false);
      }}
    >
      <label className="inline">
        {label}
        <input value={from} onChange={(e) => setFrom(e.target.value)} placeholder={placeholder} spellCheck={false} aria-label={label} />
      </label>
      <button type="submit" className="primary" disabled={!path || busy !== null}>
        Import {what}
      </button>
      <button type="button" disabled={!path || busy !== null} onClick={() => void onImport(path, true)}>
        Link {what}
      </button>
    </form>
  );
}
