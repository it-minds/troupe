// The agents a session on this computer could run, and the one place they are changed
// from this app (troupe #503, Decision 841).
//
// Everything here is the daemon's: `agents.list` says which agents a session in a
// workspace could start on and what decides whether a person wants one, `agents.get`
// gives one whole, and `agents.put` and `agents.delete` write the person's own
// (`<config>/agents/`) or the repository's (`.troupe/agents/`), checking a definition as it
// is saved. This screen never writes a directory itself, so the terminal's `/agents` and
// this one manage the same files, and `agents.changed` keeps the two lists in step.
//
// What is not a person's to change here says so: a built-in is changed by a copy, which
// is one press ("Copy into this repository"), and a profile bundle's agent is the
// console's. Before a save the screen shows what the agent may do, and asks once when the
// save lets a tool run without asking that did not before: an agent in the person's own
// layer is read by every session on this computer, and its `auto` waits for no
// workspace's trust (Decision 825 gates only a repository's).
//
// The subagents an agent delegates to are listed under the primaries and changed the same
// way; a save names the hash of the file it was opened from, so one over a file somebody
// else saved meanwhile is refused and said, as is another client's save of the agent open
// in the editor; and a file that does not parse opens to be mended (troupe Decision 852).
//
// Its list is the one agent picker's rows (troupe #594), in the manager's density: grouped
// by where each agent comes from in the four words, each with its mode, model, tools, cap on
// turns, what it stands in for and the sessions here running it. The picker's actions are
// on the one chosen (Start a session on it; Switch is a session's, so it is refused here
// with where it is done), beside the manager's own: edit, copy into a layer, a new agent
// from it as a template, and delete. A new agent or a copy, once saved, offers to start a
// session on it at once, so making one and using it are one step.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { JSX } from "react";
import { agentConflict, agentRefusal, agentTemplate, layerOf, layerWords, onThisComputer, permissionsOf, widenedAutos } from "@troupe/client";
import type { AgentDefinition, AgentLayer, AgentRow, AgentScope, AgentSkippedFile, DaemonClient, FleetRow, SessionKind } from "@troupe/client";
import { useAdminQuery } from "../hooks";
import { shell } from "../shell";
import { AgentEditor, permissionWords, scopeWords } from "./AgentEditor";
import type { Editing } from "./AgentEditor";
import { AgentRows, fromWords, runAgent } from "./AgentPicker";
import { Confirm, Failed, Loading, Table } from "./bits";

/** Switch is a session's: the manager has none, and says where it is done. */
const NO_SWITCH = "Switch is a session's: open the session and choose the agent in its head, or start a session on this one here.";

/** The sessions of this workspace running an agent now: the sessions in it and the branches made from them. */
function runningIn(rows: FleetRow[], workspace: string, name: string): FleetRow[] {
  const raw = (r: FleetRow): { workspace?: unknown; parent?: unknown } => (r.raw ?? {}) as { workspace?: unknown; parent?: unknown };
  const local = rows.filter((r) => onThisComputer(r.kind));
  const here = new Set(local.filter((r) => raw(r).workspace === workspace).map((r) => r.id));
  return local.filter((r) => r.profile === name && r.state === "active" && (here.has(r.id) || here.has(String(raw(r).parent))));
}

/** The console, where a profile bundle's agents are changed (#56), when this app knows the plane. */
async function openConsole(planeUrl: string): Promise<void> {
  const url = `${planeUrl.replace(/\/+$/, "")}/admin`;
  const open = shell()?.openExternal;
  if (open) await open(url);
  else globalThis.open?.(url, "_blank", "noopener,noreferrer");
}

/** A save about to be asked about: the tools it would newly let run without asking, or null where its permissions could not be read. */
interface Asking {
  target: SaveTarget;
  widened: string[] | null;
}

/** One save: what, where, and the permissions of the file it replaces. */
interface SaveTarget {
  name: string;
  scope: AgentScope;
  text: string;
  before: Record<string, string>;
  /** From the editor, whose fields show what the daemon found. */
  fromEditor: boolean;
  /** The hash of the file the save replaces, as it was read, when it goes back into that file. */
  ifHash?: string;
}

export function Agents({
  client,
  rows,
  workspace: given,
  agent,
  planeUrl,
  onOpenSession,
  onStarted,
}: {
  client: DaemonClient | null;
  /** The one list's rows, for the windows running each agent. */
  rows: FleetRow[];
  /** The workspace to list for, when the screen was opened from a session in it. */
  workspace?: string | undefined;
  /** An agent to open at once. */
  agent?: string | undefined;
  /** The plane this app is signed in to, for the console a bundle's agents are changed in. */
  planeUrl: string | null;
  onOpenSession: (id: string) => void;
  /** A session started here on an agent, with the workspace the daemon started it in. */
  onStarted?: (id: string, kind: SessionKind, workspace?: string) => void;
}): JSX.Element {
  if (!client) {
    return (
      <>
        <Head />
        <div className="listing">
          <section className="group">
            <h3>Agents</h3>
            <p className="copy">
              The agents a session on this computer runs are kept by its daemon, which is not connected. Connect it on This computer,
              then come back. A session on the platform runs the agents of its profile&apos;s bundle, which are changed in the console.
            </p>
          </section>
        </div>
      </>
    );
  }
  return (
    <Manager
      client={client}
      rows={rows}
      given={given}
      agent={agent}
      planeUrl={planeUrl}
      onOpenSession={onOpenSession}
      onStarted={onStarted ?? ((id) => onOpenSession(id))}
    />
  );
}

function Head(): JSX.Element {
  return (
    <header className="screen-head">
      <span className="count">Settings</span>
      <h1>Agents</h1>
      <p>
        What a session can run, where each comes from and what it may do. Yours are read by every session on this computer; a
        repository&apos;s are committed with it and shared. Built-ins are changed by a copy.
      </p>
    </header>
  );
}

function Manager({
  client,
  rows,
  given,
  agent,
  planeUrl,
  onOpenSession,
  onStarted,
}: {
  client: DaemonClient;
  rows: FleetRow[];
  given: string | undefined;
  agent: string | undefined;
  planeUrl: string | null;
  onOpenSession: (id: string) => void;
  onStarted: (id: string, kind: SessionKind, workspace?: string) => void;
}): JSX.Element {
  const [workspace, setWorkspace] = useState(given ?? "");
  const [recent, setRecent] = useState<string[]>([]);
  const [round, setRound] = useState(0);
  const [selected, setSelected] = useState<string | null>(agent ?? null);
  const [editing, setEditing] = useState<Editing | null>(null);
  const [asking, setAsking] = useState<Asking | null>(null);
  const [deleting, setDeleting] = useState<AgentDefinition | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [outcome, setOutcome] = useState<string | null>(null);
  // A new agent or a copy just saved, offered to start a session on (save, then start).
  const [startable, setStartable] = useState<string | null>(null);
  // A save of this screen's own is under way: its `agents.changed` is not news to the editor.
  const saving = useRef(false);
  const ws = workspace.trim();

  // The workspaces somebody has used, and the newest of them when nothing named one.
  useEffect(() => {
    let live = true;
    void client
      .recentWorkspaces()
      .then((r) => {
        if (!live) return;
        const paths = r.workspaces.map((w) => w.path);
        setRecent(paths.slice(0, 6));
        setWorkspace((w) => (w.trim() === "" && paths[0] ? paths[0] : w));
      })
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [client]);

  // Another client's save, or this one's, is the list's news; another's of the agent open
  // in the editor is the editor's too, since its save is now over a file it was not
  // opened from.
  useEffect(
    () =>
      client.onAgentsChanged((changed) => {
        setRound((n) => n + 1);
        if (saving.current) return;
        setEditing((ed) =>
          ed && ed.kind !== "new" && ed.name === changed.name
            ? {
                ...ed,
                elsewhere: `${changed.name} was ${changed.action === "deleted" ? "deleted" : "saved"} elsewhere while you had it open (${changed.path}). Saving yours is refused once, so you can read it first; the next save replaces it.`,
              }
            : ed,
        );
      }),
    [client],
  );

  const load = useCallback(
    () => (ws ? client.listAgents(ws, { subagents: true }) : Promise.resolve({ agents: [] as AgentRow[], skipped: [] as AgentSkippedFile[] })),
    [client, ws],
  );
  const { data, loading, error: readError } = useAdminQuery(load, [load, round]);

  const detail = useAgent(client, selected, ws, round);
  const subagents = (data?.agents ?? []).filter((a) => a.mode === "subagent");

  // A session on the agent, in the workspace the list is for, as the start screen makes one.
  const start = async (name: string): Promise<void> => {
    const row = data?.agents.find((a) => a.name === name) ?? { name, description: "", source: "" };
    setBusy(true);
    setError(null);
    const refused = await runAgent(row, async (as) => {
      if (!ws) throw new Error("Name a workspace first: a session starts in one.");
      const created = await client.createSession({ workspace: ws, profile: as });
      onStarted(created.session_id, "local", created.workspace);
    });
    if (refused) setError(refused);
    setBusy(false);
  };

  const save = async (target: SaveTarget): Promise<void> => {
    setBusy(true);
    saving.current = true;
    setError(null);
    setOutcome(null);
    try {
      const written = await client.putAgent({
        name: target.name,
        scope: target.scope,
        source: target.text,
        ...(ws ? { workspace: ws } : {}),
        ...(target.ifHash ? { if_hash: target.ifHash } : {}),
      });
      const warned = written.warnings.length ? ` ${written.warnings.map((w) => w.message).join("; ")}.` : "";
      setOutcome(`${written.action === "created" ? "Saved" : "Replaced"} ${written.name} in ${scopeWords(written.scope)}: ${written.path}.${warned}`);
      // A new agent, or a copy, is offered at once to start on; a subagent is delegated to, not started.
      setStartable(written.action === "created" && !/^mode:\s*["']?subagent/m.test(target.text) ? written.name : null);
      setEditing(null);
      setSelected(written.name);
      setRound((n) => n + 1);
    } catch (e) {
      const refused = agentRefusal(e);
      const conflict = agentConflict(e);
      if (conflict && target.fromEditor) {
        // Said, and the edit kept; its next save is over the file as it is now.
        setEditing((ed) => (ed ? { ...ed, conflict: conflict.reason, elsewhere: null, base: { scope: target.scope, hash: conflict.hash } } : ed));
      } else if (refused && target.fromEditor) setEditing((ed) => (ed ? { ...ed, findings: refused } : ed));
      else setError(conflict ? conflict.reason : refused ? refused.reason : e instanceof Error ? e.message : String(e));
    } finally {
      saving.current = false;
      setBusy(false);
    }
  };

  // A file that does not parse, opened as the daemon has it, to be saved back where it is.
  const mend = async (skipped: AgentSkippedFile): Promise<void> => {
    if (!skipped.name) return;
    setError(null);
    setOutcome(null);
    try {
      const broken = await client.brokenAgent({ name: skipped.name, ...(ws ? { workspace: ws } : {}) });
      if (!broken) {
        setError(`${skipped.path} is not read (${skipped.reason}), and is not one this screen can open: fix it by hand.`);
        return;
      }
      setSelected(null);
      setEditing({
        kind: "mend",
        name: skipped.name,
        scope: broken.scope,
        text: broken.text,
        original: null,
        findings: null,
        checked: false,
        base: { scope: broken.scope, hash: broken.hash },
        reason: broken.reason,
      });
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  // Asked once when the save lets a tool run without asking that did not before.
  const requestSave = (target: SaveTarget): void => {
    const after = permissionsOf(target.text);
    const widened = after === null ? null : widenedAutos(target.before, after);
    if (widened === null || widened.length > 0) setAsking({ target, widened });
    else void save(target);
  };

  const copy = (def: AgentDefinition, scope: AgentScope): void =>
    requestSave({ name: def.name, scope, text: def.text ?? "", before: {}, fromEditor: false });

  const remove = async (def: AgentDefinition): Promise<void> => {
    const scope: AgentScope = def.layer === "project" ? "project" : "user";
    setBusy(true);
    setError(null);
    setOutcome(null);
    try {
      const gone = await client.deleteAgent({ name: def.name, scope, ...(ws ? { workspace: ws } : {}) });
      setOutcome(
        `Deleted ${gone.path}. ${gone.layer ? `${gone.name} is ${layerWords(gone.layer)} again here.` : `Nothing is called ${gone.name} here any more.`}`,
      );
      setDeleting(null);
      if (!gone.layer) setSelected(null);
      setRound((n) => n + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setDeleting(null);
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <Head />
      <div className="listing">
        <section className="group">
          <h3>Which workspace</h3>
          <p className="copy">The agents a session there could start on: the built-ins, yours, and the repository&apos;s.</p>
          <form className="inline-form" onSubmit={(e) => e.preventDefault()}>
            <label className="inline">
              Workspace
              <input value={workspace} onChange={(e) => setWorkspace(e.target.value)} placeholder="/home/me/project" spellCheck={false} aria-label="Workspace" />
            </label>
          </form>
          {recent.length > 0 && (
            <div className="chips">
              {recent.map((path) => (
                <button key={path} className="chip as-button" onClick={() => setWorkspace(path)} aria-pressed={path === ws}>
                  {path}
                </button>
              ))}
            </div>
          )}
        </section>

        <section className="group">
          <h3>Agents</h3>
          <Failed error={readError ?? error} />
          {outcome && <p className="note">{outcome}</p>}
          {!ws && <p className="note">Name a workspace to see what a session there could run.</p>}
          {ws && loading && !data && <Loading what="Reading the agents…" />}
          {(data?.agents ?? []).length > 0 && (
            <AgentRows
              rows={data?.agents ?? []}
              current={null}
              picked={selected}
              onChoose={(name) => {
                setSelected(name);
                setStartable(null);
                setError(null);
              }}
              density="manager"
              running={(name) => runningIn(rows, ws, name).map((r) => r.id)}
            />
          )}
          {subagents.length > 0 && <p className="note">Subagents are what an agent delegates to: nothing a person types starts one. Each is read, copied and edited as any other.</p>}
          {startable && (
            <div className="actions start-actions">
              <button className="primary" disabled={busy} onClick={() => void start(startable)}>
                Start a session on {startable}
              </button>
            </div>
          )}
          {ws && (
            <div className="actions start-actions">
              <button
                onClick={() => {
                  setSelected(null);
                  setEditing({ kind: "new", name: "", scope: "project", text: agentTemplate(), original: null, findings: null, checked: false });
                }}
                disabled={busy}
              >
                New agent
              </button>
            </div>
          )}
          {data && (data.skipped ?? []).length > 0 && (
            <Table head={["Not read", "File", "Why", ""]}>
              {(data.skipped ?? []).map((s) => (
                <tr key={s.path}>
                  <th scope="row">{s.name ?? "(the whole directory)"}</th>
                  <td className="mono micro">{s.path}</td>
                  <td>{s.reason}</td>
                  <td>
                    {s.name && (
                      <button className="link" onClick={() => void mend(s)} disabled={busy} aria-label={`Open ${s.name} to mend it`}>
                        Mend
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </Table>
          )}
        </section>

        {editing && (
          <AgentEditor
            client={client}
            workspace={ws}
            editing={editing}
            busy={busy}
            onChange={setEditing}
            onCancel={() => setEditing(null)}
            onSave={(target) => requestSave({ ...target, fromEditor: true })}
          />
        )}

        {!editing && selected && (
          <AgentDetail
            name={selected}
            detail={detail}
            workspace={ws}
            rows={rows}
            busy={busy}
            planeUrl={planeUrl}
            onOpenSession={onOpenSession}
            onEdit={(def) => {
              const scope: AgentScope = def.layer === "project" ? "project" : "user";
              setEditing({ kind: "edit", name: def.name, scope, text: def.text ?? "", original: def, findings: null, checked: false, base: { scope, hash: def.hash ?? null } });
            }}
            onNewFrom={(def) => setEditing({ kind: "new", name: "", scope: "project", text: def.text ?? "", original: def, findings: null, checked: false })}
            onCopy={copy}
            onDelete={setDeleting}
            onStart={(name) => void start(name)}
            onSwitch={() => setError(NO_SWITCH)}
          />
        )}
      </div>

      {asking && (
        <AutoQuestion
          asking={asking}
          busy={busy}
          onBack={() => setAsking(null)}
          onSave={() => {
            const { target } = asking;
            setAsking(null);
            void save(target);
          }}
        />
      )}

      {deleting && (
        <Confirm
          what={`Delete it from ${scopeWords(deleting.layer === "project" ? "project" : "user")}`}
          identifier={deleting.name}
          consequence={`${deleting.path ?? deleting.name} is deleted. ${
            deleting.also[0]
              ? `${deleting.name} is ${layerWords(deleting.also[0].layer)} again here, from ${deleting.also[0].path}.`
              : `Nothing is called ${deleting.name} here once it is gone, and a session asked for it is refused.`
          }`}
          busy={busy}
          onCancel={() => setDeleting(null)}
          onConfirm={() => void remove(deleting)}
        />
      )}
    </>
  );
}

/** One agent whole, read again when the list changes. */
function useAgent(client: DaemonClient, name: string | null, workspace: string, round: number): { def: AgentDefinition | null; error: string | null } {
  const [state, setState] = useState<{ def: AgentDefinition | null; error: string | null }>({ def: null, error: null });
  useEffect(() => {
    if (!name) return setState({ def: null, error: null });
    let live = true;
    client
      .getAgent({ name, ...(workspace ? { workspace } : {}) })
      .then((def) => live && setState({ def, error: null }))
      .catch((e: unknown) => {
        if (!live) return;
        // A daemon older than the manager lists agents and cannot give one whole.
        const old = e instanceof Error && /method_not_found/.test(e.message);
        setState({ def: null, error: old ? "This daemon is older than the agents manager: update Troupe on this computer to read and change an agent here." : e instanceof Error ? e.message : String(e) });
      });
    return () => {
      live = false;
    };
  }, [client, name, workspace, round]);
  return state;
}

function LayerWord({ layer }: { layer: AgentLayer }): JSX.Element {
  return <span className={`chip layer-${layer}`}>{layerWords(layer)}</span>;
}

function AgentDetail({
  name,
  detail,
  workspace,
  rows,
  busy,
  planeUrl,
  onOpenSession,
  onEdit,
  onNewFrom,
  onCopy,
  onDelete,
  onStart,
  onSwitch,
}: {
  name: string;
  detail: { def: AgentDefinition | null; error: string | null };
  workspace: string;
  rows: FleetRow[];
  busy: boolean;
  planeUrl: string | null;
  onOpenSession: (id: string) => void;
  onEdit: (def: AgentDefinition) => void;
  onNewFrom: (def: AgentDefinition) => void;
  onCopy: (def: AgentDefinition, scope: AgentScope) => void;
  onDelete: (def: AgentDefinition) => void;
  onStart: (name: string) => void;
  onSwitch: () => void;
}): JSX.Element {
  const def = detail.def?.name === name ? detail.def : null;
  const running = useMemo(() => (def ? runningIn(rows, workspace, def.name) : []), [rows, workspace, def]);
  if (!def) {
    return (
      <section className="group agent-detail">
        <h3>{name}</h3>
        <Failed error={detail.error} />
        {!detail.error && <Loading what={`Reading ${name}…`} />}
      </section>
    );
  }
  const layer = layerOf(def);
  const own = layer === "user" || layer === "project";
  // A copy goes into a layer above a built-in or a bundle's, or beside the other own one,
  // and never over a file the layer already has.
  const canCopy = (scope: AgentScope): boolean => def.text !== null && layer !== scope && !def.also.some((a) => a.layer === scope) && (scope === "user" || Boolean(workspace));
  const permissions = Object.entries(def.permissions);

  return (
    <section className="group agent-detail" aria-label={`The agent ${def.name}`}>
      <h3>{def.name}</h3>
      <p className="copy">{def.description || "No description."}</p>
      <p className="note">{fromWords(def)}</p>
      <div className="actions start-actions">
        <button className="primary" onClick={() => onStart(def.name)} disabled={busy || !workspace}>
          Start a session on {def.name}
        </button>
        <button onClick={onSwitch} disabled={busy}>
          Switch to {def.name}
        </button>
      </div>
      <dl className="facts wide">
        <dt>Layer</dt>
        <dd>
          <LayerWord layer={layer} /> <span className="mono micro">{def.path ?? "no file: the bundle's"}</span>
        </dd>
        <dt>Mode</dt>
        <dd>{def.mode === "primary" ? "primary: a session or a branch runs it" : def.mode === "function" ? "function: the harness runs it for one job" : "subagent: an agent delegates to it"}</dd>
        <dt>Model</dt>
        <dd className="mono">{def.model ?? "the session's"}</dd>
        <dt>Tools</dt>
        <dd>
          {def.tools === "all" ? `every tool (${def.tool_count ?? "?"})` : def.tools.join(", ")}
          {def.read_only ? " · read only" : ""}
        </dd>
        <dt>Permissions</dt>
        <dd>
          {permissions.length === 0
            ? "Troupe's own for each tool"
            : permissions.map(([tool, p]) => (
                <span key={tool} className={`chip permission-${p}`}>
                  {tool}: {permissionWords(p)}
                </span>
              ))}
        </dd>
        <dt>Max turns</dt>
        <dd>{def.max_turns ?? "no cap of its own"}</dd>
        <dt>Budget share</dt>
        <dd>{def.budget_share ?? "the default"}</dd>
        <dt>Skills</dt>
        <dd>{def.skills === "all" ? "every skill" : def.skills.length ? def.skills.join(", ") : "none"}</dd>
        {def.worktree !== undefined && (
          <>
            <dt>Worktree</dt>
            <dd>{def.worktree ? "a session started on it here now gets a worktree of its own" : "a session started on it here now works in the checkout"}</dd>
          </>
        )}
        {def.also.length > 0 && (
          <>
            <dt>Hides</dt>
            <dd>
              {def.also.map((a) => (
                <span key={a.path} className="mono micro">
                  {layerWords(a.layer)}: {a.path}{" "}
                </span>
              ))}
            </dd>
          </>
        )}
        <dt>Running here</dt>
        <dd>
          {running.length === 0
            ? "no window"
            : running.map((r) => (
                <button key={r.id} className="link mono" onClick={() => onOpenSession(r.id)}>
                  {r.id}
                </button>
              ))}
        </dd>
        {def.available === false && (
          <>
            <dt>Cannot run</dt>
            <dd>{def.reason}</dd>
          </>
        )}
      </dl>

      {def.editable_reason && (
        <p className="note">
          {def.editable_reason}.
          {layer === "bundle" && planeUrl && (
            <>
              {" "}
              <button className="link" onClick={() => void openConsole(planeUrl)}>
                Open the console
              </button>
            </>
          )}
        </p>
      )}

      <div className="actions start-actions">
        {def.editable && own && (
          <button className="primary" onClick={() => onEdit(def)} disabled={busy}>
            Edit
          </button>
        )}
        {canCopy("project") && (
          <button className={def.editable ? "" : "primary"} onClick={() => onCopy(def, "project")} disabled={busy}>
            Copy into this repository
          </button>
        )}
        {canCopy("user") && (
          <button onClick={() => onCopy(def, "user")} disabled={busy}>
            Copy into my agents
          </button>
        )}
        {def.text !== null && (
          <button onClick={() => onNewFrom(def)} disabled={busy}>
            New agent from this
          </button>
        )}
        {def.editable && own && (
          <button className="danger" onClick={() => onDelete(def)} disabled={busy}>
            Delete from {scopeWords(layer === "project" ? "project" : "user")}
          </button>
        )}
      </div>

      <h4 className="instruction-head">The instruction</h4>
      <pre className="payload instruction" aria-label={`The instruction of ${def.name}`}>
        {def.prompt || "(empty: it runs on Troupe's prompt alone)"}
      </pre>
    </section>
  );
}

/** The one question before a save that lets a tool run without asking that did not before. */
function AutoQuestion({ asking, busy, onBack, onSave }: { asking: Asking; busy: boolean; onBack: () => void; onSave: () => void }): JSX.Element {
  const { target, widened } = asking;
  const tools = widened?.join(", ") ?? "";
  return (
    <div className="scrim" onClick={onBack}>
      <div className="dialog" role="dialog" aria-modal="true" aria-label="Let it run without asking" onClick={(e) => e.stopPropagation()}>
        <h1>{widened ? `Let ${tools} run without asking?` : "Save permissions this screen cannot read?"}</h1>
        <p className="copy">
          {!widened
            ? `The permissions of ${target.name} are written in a way this screen does not read, so it cannot say what runs without asking. Read them in the File tab first; the daemon checks them as it saves.`
            : target.scope === "user"
            ? `${target.name} goes into your agents, which every session on this computer reads, in every workspace. With permissions: auto, ${tools} runs without asking you first, wherever ${target.name} runs, and no workspace's trust is asked for it.`
            : `${target.name} goes into this repository's .troupe/agents, which is committed and shared. With permissions: auto, ${tools} runs without asking once this workspace is trusted, for anybody whose session runs ${target.name}.`}
        </p>
        <div className="actions">
          <button onClick={onBack}>Back</button>
          <button className="primary" disabled={busy} onClick={onSave}>
            {busy ? "Saving…" : "Save, and let it run"}
          </button>
        </div>
      </div>
    </div>
  );
}
