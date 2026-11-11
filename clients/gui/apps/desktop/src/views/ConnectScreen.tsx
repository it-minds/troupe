// Tools and skills: your own MCP servers and skills, which every session on this computer
// starts with your sign-ins, your keychain and your environment.
//
// A server is a row that says in words how it stands and offers the one thing that fixes
// it: a missing secret is pasted into the row (kept in this computer's keychain, the file
// getting a `{secret:…}` reference and never the value), a sign-in that ran out is signed
// in again, a server nobody checked is checked. Its details say what it can do, as the
// server describes each tool and whether it only reads, and how it starts.
//
// Servers come in two ways, each a drawer: brought in from another app's file (read where
// it is, so it follows that app, or copied), or set up by hand (`serverChanges` turns the
// form into a merge-patch for `mcp.add` and the keychain's `mcp.secret`s). Skills come from
// the directories other tools keep, which the daemon finds (`skills.discover`).
//
// Everything here is the daemon's: this screen holds no path of its own, and the TUI's
// `/mcp` page shows and changes the same set.

import { useCallback, useEffect, useState } from "react";
import type { JSX, ReactNode } from "react";
import { draftOf, draftProblems, joinCommand, pairsFromText, pairsToText, revocationText, serverChanges, serverTrial, splitCommand } from "@troupe/client";
import type { DaemonClient, DraftOAuth, FoundSkills, LocalServer, LocalSkill, ServerDraft, SkippedSkill, SourceScope, ToolAbout } from "@troupe/client";
import { useAdminQuery } from "../hooks";
import { shell } from "../shell";
import { Failed, Loading } from "./bits";

type Tone = "ready" | "attention" | "failed" | "idle" | "busy";

interface Standing {
  tone: Tone;
  label: string;
  detail: string;
}

/** Where a server's file came from, for its chip: your settings, or another app's file it follows. */
function origin(server: LocalServer): { label: string; note: string; follows: boolean } {
  const source = server.source ?? "";
  if (server.layer === "config") return { label: "FROM CONFIG.YAML", note: "Written in config.yaml. Changes here are written over it in your own file.", follows: false };
  if (!server.linked) return { label: server.layer === "workspace" ? "IN THE PROJECT'S SETTINGS" : "IN YOUR SETTINGS", note: `Lives in ${source || "your Troupe settings"}.`, follows: false };
  const file = source.split(/[\\/]/).slice(-2).join("/");
  return { label: `↻ FOLLOWS ${file.toUpperCase()}`, note: `Read from ${source} each time. Change it there and it changes here.`, follows: true };
}

/** How a server stands, in words: from a check or sign-in if there was one, else from the listing. */
function standing(server: LocalServer, live: LocalServer | undefined, busy: boolean): Standing {
  const state = live?.state ?? server.state;
  const error = live?.error ?? server.error ?? server.refused ?? null;
  const missing = server.missing ?? [];
  if (busy) return { tone: "busy", label: "Checking…", detail: "Starting it and asking for tools" };
  if (server.disabled) return { tone: "idle", label: "Paused", detail: "Agents don't get its tools until you resume it" };
  if (missing.length) return { tone: "attention", label: "Needs a secret", detail: `${missing.join(", ")} ${missing.length === 1 ? "is" : "are"} not set` };
  if (server.auth?.state === "signing_in") return { tone: "busy", label: "Signing in…", detail: "Finish in your browser" };
  if (state === "sign_in" || (server.auth && server.auth.state !== "signed_in"))
    return { tone: "attention", label: "Needs you to sign in", detail: server.auth?.state === "expired" ? "Your sign-in ran out" : "It acts as you, so it needs your sign-in" };
  if (server.trust === "pending" || state === "pending") return { tone: "attention", label: "Waits for approval", detail: "A project's server starts once you allow it in a session" };
  if (server.refused || state === "error") return { tone: "failed", label: "Can't connect", detail: error ?? "It did not start" };
  if (state === "ready") {
    const n = live?.tools.length ?? server.tools.length;
    const who = server.auth?.state === "signed_in" && server.auth.account ? ` · as ${server.auth.account}` : "";
    return { tone: "ready", label: "Ready", detail: `${n} ${n === 1 ? "tool" : "tools"} available${who}` };
  }
  if (state === "connecting") return { tone: "busy", label: "Connecting…", detail: "Starting it" };
  return { tone: "idle", label: "Not checked yet", detail: "We haven't started it yet" };
}

const humanize = (n: string): string => {
  const s = n.replace(/[_-]+/g, " ").trim();
  return s.charAt(0).toUpperCase() + s.slice(1);
};

const firstSentence = (text: string | null): string | null => {
  if (!text) return null;
  const m = /^(.+?[.!?])(\s|$)/s.exec(text.trim());
  return (m?.[1] ?? text).trim();
};

async function openExternal(url: string): Promise<void> {
  const open = shell()?.openExternal;
  if (open) await open(url);
  else globalThis.open?.(url, "_blank", "noopener,noreferrer");
}

/** Another app's file of servers, offered as a place to look: which it is, and where. */
const KNOWN_FILES: Array<{ app: string; file: string }> = [
  { app: "Claude Code", file: "~/.claude.json" },
  { app: "Claude Code (a project)", file: ".mcp.json" },
  { app: "Claude Desktop", file: "~/.config/Claude/claude_desktop_config.json" },
  { app: "Cursor", file: "~/.cursor/mcp.json" },
  { app: "VS Code", file: ".vscode/mcp.json" },
  { app: "Codex", file: "~/.codex/config.toml" },
];

type Drawer = { kind: "import" } | { kind: "manual"; server?: LocalServer } | null;

export function ConnectScreen({ client, workspace: initial }: { client: DaemonClient | null; workspace?: string | undefined }): JSX.Element {
  return (
    <div className="cx-page">
      {client ? (
        <Connect client={client} initialProject={initial ?? ""} />
      ) : (
        <>
          <Head onImport={null} onManual={null} />
          <p className="note cx-main">Your servers are kept by this computer&apos;s daemon, which is not connected. This computer, in the rail, says why and finds it.</p>
        </>
      )}
    </div>
  );
}

function Head({ onImport, onManual, tabs }: { onImport: (() => void) | null; onManual: (() => void) | null; tabs?: ReactNode }): JSX.Element {
  return (
    <header className="cx-header">
      <div className="cx-header-top">
        <div className="cx-intro">
          <div className="cx-eyebrow">// YOUR TOOLS</div>
          <h1 className="cx-h1">Tools and skills</h1>
          <p className="cx-lead">Servers and skills your agents can use on this computer. Bring them over from the apps you already use, or set one up by hand.</p>
        </div>
        {onImport && onManual && (
          <div className="cx-head-actions">
            <button type="button" className="cx-btn cx-btn-primary" onClick={onImport}>
              Bring in from another app
            </button>
            <button type="button" className="cx-btn cx-btn-lg" onClick={onManual}>
              Set one up by hand
            </button>
          </div>
        )}
      </div>
      {tabs}
    </header>
  );
}

function Connect({ client, initialProject }: { client: DaemonClient; initialProject: string }): JSX.Element {
  const [tab, setTab] = useState<"servers" | "skills">("servers");
  const [drawer, setDrawer] = useState<Drawer>(null);
  const [project, setProject] = useState(initialProject);
  const [round, setRound] = useState(0);
  const [toast, setToast] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  // What a check answered, by server: its live state and what each tool is.
  const [live, setLive] = useState<Record<string, LocalServer>>({});
  const [checking, setChecking] = useState<Set<string>>(new Set());
  const [open, setOpen] = useState<string | null>(null);

  const ws = project.trim();
  const load = useCallback(async () => {
    const [servers, skills, found] = await Promise.all([
      client.listServers(ws ? { workspace: ws } : {}),
      client.listSkills(ws || undefined),
      client.discoverSkills(ws || undefined).catch(() => ({ found: [] as FoundSkills[] })),
    ]);
    return { servers: servers.servers, warnings: servers.warnings, skills: skills.skills, skipped: skills.skipped ?? [], found: found.found };
  }, [client, ws]);
  const { data, loading, error: readError } = useAdminQuery(load, [load, round]);
  const reread = (): void => setRound((n) => n + 1);

  // While a browser is out for a sign-in, read again every two seconds.
  const signingIn = data?.servers.some((s) => s.auth?.state === "signing_in") ?? false;
  useEffect(() => {
    if (!signingIn) return;
    const timer = setTimeout(reread, 2000);
    return () => clearTimeout(timer);
  }, [signingIn, data]);

  const scoped = (server: LocalServer): { workspace?: string } => (ws ? { workspace: ws } : {});
  const layerOf = (server: LocalServer): SourceScope => (server.layer === "workspace" ? "workspace" : "user");

  const check = async (server: LocalServer): Promise<void> => {
    setChecking((c) => new Set(c).add(server.name));
    try {
      const { server: result } = await client.checkServer({ ...scoped(server), name: server.name });
      setLive((l) => ({ ...l, [server.name]: result }));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setChecking((c) => {
        const next = new Set(c);
        next.delete(server.name);
        return next;
      });
      reread();
    }
  };

  const forget = (name: string): void => setLive((l) => Object.fromEntries(Object.entries(l).filter(([k]) => k !== name)));

  const act = async (run: () => Promise<string | null>): Promise<void> => {
    setError(null);
    try {
      const said = await run();
      if (said) setToast(said);
      reread();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  const signIn = (server: LocalServer): Promise<void> =>
    act(async () => {
      const started = await client.signInServer({ ...scoped(server), name: server.name });
      forget(server.name);
      await openExternal(started.url);
      return `${server.name}: finish signing in in your browser. Sessions waiting for it carry on once you have.`;
    });

  const signOut = (server: LocalServer): Promise<void> =>
    act(async () => {
      const out = await client.signOutServer({ ...scoped(server), name: server.name });
      forget(server.name);
      return `${server.name}: signed out on this computer; ${revocationText(out.revocation)}.`;
    });

  const pause = (server: LocalServer): Promise<void> =>
    act(async () => {
      const layer = layerOf(server);
      await client.writeServer({ scope: layer, ...(layer === "workspace" && ws ? { workspace: ws } : {}), name: server.name, server: { disabled: !server.disabled } });
      forget(server.name);
      return server.disabled ? `${server.name} resumed. Sessions get its tools when they start, or when you restart it in one.` : `${server.name} paused. New sessions don't get its tools.`;
    });

  const remove = (server: LocalServer): Promise<void> =>
    act(async () => {
      const layer = layerOf(server);
      const r = await client.removeServer({ scope: layer, ...(layer === "workspace" && ws ? { workspace: ws } : {}), name: server.name });
      setOpen(null);
      forget(server.name);
      return `${r.removed.join(", ")} removed. Agents lose its tools in new sessions.`;
    });

  const keepSecret = async (server: LocalServer, key: string, value: string): Promise<void> => {
    const layer = layerOf(server);
    const field = (server.headers ?? []).includes(key) ? "headers" : "env";
    await act(async () => {
      await client.setServerSecret({ scope: layer, ...(layer === "workspace" && ws ? { workspace: ws } : {}), name: server.name, key, field, value });
      return `Kept ${key} in your keychain.`;
    });
    await check(server);
  };

  const servers = data?.servers ?? [];
  const skills = data?.skills ?? [];

  return (
    <>
      <Head
        onImport={() => {
          setTab("servers");
          setDrawer({ kind: "import" });
        }}
        onManual={() => {
          setTab("servers");
          setDrawer({ kind: "manual" });
        }}
        tabs={
          <div className="cx-tabs" role="tablist" aria-label="What to show">
            <button type="button" role="tab" className="cx-tab" aria-selected={tab === "servers"} onClick={() => setTab("servers")}>
              Servers <span className="cx-count">{servers.length}</span>
            </button>
            <button type="button" role="tab" className="cx-tab" aria-selected={tab === "skills"} onClick={() => setTab("skills")}>
              Skills <span className="cx-count">{skills.length}</span>
            </button>
          </div>
        }
      />
      <div className="cx-body">
        <main className="cx-main">
          {toast && (
            <div className="cx-notice" role="status">
              <span aria-hidden="true" className="cx-ok">
                ✓
              </span>
              <span className="cx-grow">{toast}</span>
              <button type="button" aria-label="Dismiss" className="cx-quiet" onClick={() => setToast(null)}>
                ✕
              </button>
            </div>
          )}
          <Failed error={readError ?? error} />
          <div className="cx-project">
            <span>Also show a project&apos;s own servers and skills</span>
            <input type="text" value={project} onChange={(e) => setProject(e.target.value)} placeholder="~/dev/my-project" spellCheck={false} aria-label="Project folder" />
          </div>
          {loading && !data && <Loading what="Reading your servers and skills…" />}
          {data && tab === "servers" && (
            <>
              {servers.length === 0 && (
                <div className="cx-empty">
                  <p className="cx-empty-title">No servers yet</p>
                  <p className="cx-muted">
                    Servers give your agents tools like your issue tracker, your time sheets or a database. Start with the ones you already set up in Claude Code or Cursor.
                  </p>
                </div>
              )}
              <ul className="cx-rows">
                {servers.map((server) => (
                  <ServerRow
                    key={`${server.layer}:${server.name}`}
                    client={client}
                    server={server}
                    live={live[server.name]}
                    busy={checking.has(server.name)}
                    project={ws}
                    open={open === server.name}
                    onToggle={() => setOpen(open === server.name ? null : server.name)}
                    onCheck={() => void check(server)}
                    onSignIn={() => void signIn(server)}
                    onSignOut={() => void signOut(server)}
                    onPause={() => void pause(server)}
                    onRemove={() => void remove(server)}
                    onEdit={() => setDrawer({ kind: "manual", server })}
                    onSecret={(key, value) => keepSecret(server, key, value)}
                    onTools={(about) => setLive((l) => ({ ...l, [server.name]: { ...(l[server.name] ?? server), about } }))}
                  />
                ))}
              </ul>
              {data.warnings.length > 0 && (
                <ul className="note">
                  {data.warnings.map((w) => (
                    <li key={w}>{w}</li>
                  ))}
                </ul>
              )}
            </>
          )}
          {data && tab === "skills" && (
            <SkillsTab
              client={client}
              project={ws}
              skills={skills}
              skipped={data.skipped}
              found={data.found}
              onDone={(said) => {
                setToast(said);
                reread();
              }}
              onError={setError}
            />
          )}
        </main>
        {drawer?.kind === "import" && (
          <ImportDrawer
            client={client}
            project={ws}
            onClose={() => setDrawer(null)}
            onDone={(said, added) => {
              setDrawer(null);
              setToast(said);
              reread();
              for (const name of added) {
                const server = { name, layer: "user", source: null, state: null, tools: [], error: null } as LocalServer;
                void check(server);
              }
            }}
          />
        )}
        {drawer?.kind === "manual" && (
          <ManualDrawer
            key={drawer.server?.name ?? "new"}
            client={client}
            server={drawer.server}
            project={ws}
            onClose={() => setDrawer(null)}
            onDone={(name, said, result) => {
              setDrawer(null);
              setToast(said);
              if (result) setLive((l) => ({ ...l, [name]: result }));
              else forget(name);
              setOpen(null);
              reread();
            }}
          />
        )}
      </div>
    </>
  );
}

// -- a server -------------------------------------------------------------------------

function ServerRow({
  client,
  server,
  live,
  busy,
  project,
  open,
  onToggle,
  onCheck,
  onSignIn,
  onSignOut,
  onPause,
  onRemove,
  onEdit,
  onSecret,
  onTools,
}: {
  client: DaemonClient;
  server: LocalServer;
  live: LocalServer | undefined;
  busy: boolean;
  project: string;
  open: boolean;
  onToggle: () => void;
  onCheck: () => void;
  onSignIn: () => void;
  onSignOut: () => void;
  onPause: () => void;
  onRemove: () => void;
  onEdit: () => void;
  onSecret: (key: string, value: string) => Promise<void>;
  onTools: (about: ToolAbout[]) => void;
}): JSX.Element {
  const s = standing(server, live, busy);
  const from = origin(server);
  const missing = server.missing ?? [];
  const remote = Boolean(server.url);
  const short = remote ? (server.url ?? "") : joinCommand(server.command ?? "", server.args ?? []);
  const wantsSignIn = Boolean(server.auth) && (server.auth?.state !== "signed_in" || Boolean(server.auth?.step_up)) && server.auth?.state !== "signing_in";

  let fix: JSX.Element | null = null;
  if (!busy && !server.disabled) {
    if (missing.length)
      fix = (
        <button
          type="button"
          className="cx-btn cx-btn-solid cx-attention"
          onClick={() => {
            if (!open) onToggle();
          }}
        >
          Add {missing[0]}
        </button>
      );
    else if (wantsSignIn)
      fix = (
        <button type="button" className="cx-btn cx-btn-solid cx-attention" onClick={onSignIn}>
          {server.auth?.state === "expired" ? "Sign in again" : server.auth?.step_up ? `Allow ${server.auth.step_up}` : "Sign in"}
        </button>
      );
    else if (s.tone === "failed")
      fix = (
        <button type="button" className="cx-btn cx-btn-solid cx-failed" onClick={onCheck}>
          Try again
        </button>
      );
    else if (s.tone === "idle")
      fix = (
        <button type="button" className="cx-btn cx-btn-solid cx-ready" onClick={onCheck}>
          Check it
        </button>
      );
  }

  return (
    <li className={`cx-row cx-tone-${s.tone}`}>
      <div className="cx-row-head">
        <span aria-hidden="true" className={`cx-dot${s.tone === "busy" ? " cx-pulse" : ""}`} />
        <div className="cx-row-main">
          <div className="cx-row-title">
            <h3>{server.name}</h3>
            <span className="cx-mono cx-dim">{remote ? "REMOTE" : "RUNS HERE"}</span>
          </div>
          <div className="cx-code cx-muted cx-ellipsis">{short}</div>
          <div className="cx-chips">
            <span className="cx-chip">{server.layer === "workspace" ? `ONLY ${project || "THIS PROJECT"}` : "EVERY PROJECT"}</span>
            <span className={`cx-chip${from.follows ? " cx-chip-follows" : ""}`}>{from.label}</span>
          </div>
        </div>
        <div className="cx-status">
          <div className="cx-status-label">{s.label}</div>
          <div className="cx-status-detail">{s.detail}</div>
        </div>
        <div className="cx-row-buttons">
          {fix}
          <button type="button" className="cx-btn" aria-expanded={open} aria-label={`${open ? "Hide" : "Show"} details for ${server.name}`} onClick={onToggle}>
            {open ? "Hide" : "Details"}
          </button>
        </div>
      </div>
      {open && (
        <ServerDetails
          client={client}
          server={server}
          live={live}
          busy={busy}
          project={project}
          originNote={from.note}
          onSecret={onSecret}
          onTools={onTools}
          onCheck={onCheck}
        />
      )}
      {open && (
        <div className="cx-actions">
          <button type="button" className="cx-btn" disabled={busy || server.disabled} onClick={onCheck}>
            Check again
          </button>
          <button type="button" className="cx-btn" onClick={onEdit}>
            Edit
          </button>
          {server.auth?.state === "signed_in" && (
            <button type="button" className="cx-btn" onClick={onSignOut}>
              Sign out
            </button>
          )}
          {server.layer !== "config" && (
            <button type="button" className="cx-btn cx-btn-soft" onClick={onPause}>
              {server.disabled ? "Resume" : "Pause for now"}
            </button>
          )}
          {server.layer !== "config" && (
            <button type="button" className="cx-btn cx-btn-quiet cx-danger cx-push" onClick={onRemove}>
              Remove
            </button>
          )}
        </div>
      )}
    </li>
  );
}

function ServerDetails({
  client,
  server,
  live,
  busy,
  project,
  originNote,
  onSecret,
  onTools,
  onCheck,
}: {
  client: DaemonClient;
  server: LocalServer;
  live: LocalServer | undefined;
  busy: boolean;
  project: string;
  originNote: string;
  onSecret: (key: string, value: string) => Promise<void>;
  onTools: (about: ToolAbout[]) => void;
  onCheck: () => void;
}): JSX.Element {
  const [tab, setTab] = useState<"tools" | "tech">("tools");
  const [asking, setAsking] = useState(false);
  const missing = server.missing ?? [];
  const about = live?.about;
  const ready = (live?.state ?? server.state) === "ready" || (about?.length ?? 0) > 0;

  // What it can do is asked for once the details are open: a URL server is listed with
  // your sign-in (`mcp.tools`); a command is started once by a check.
  useEffect(() => {
    if (about || busy || missing.length || server.disabled || server.refused || asking) return;
    if (server.auth && server.auth.state !== "signed_in") return;
    setAsking(true);
    if (server.url) {
      client
        .serverTools({ name: server.name, ...(project ? { workspace: project } : {}) })
        .then((r) => onTools(r.tools.map((t) => ({ name: t.name, title: t.title ?? null, summary: t.summary ?? null, read_only: t.read_only === true }))))
        .catch(() => onCheck())
        .finally(() => setAsking(false));
    } else {
      onCheck();
      setAsking(false);
    }
  }, [about, busy]);

  const tools = (about ?? []).map((t) => ({ ...t, shown: t.title ?? humanize(t.name), said: firstSentence(t.summary) ?? "No description given by the server." }));
  const writes = tools.some((t) => !t.read_only);
  const noTools = busy || asking
    ? "Asking it what it can do…"
    : missing.length
      ? "Add the missing value above and we'll list what it can do."
      : server.auth && server.auth.state !== "signed_in"
        ? "Sign in and we'll list what it can do."
        : server.disabled
          ? "It's paused. Resume it to see what it can do."
          : (live?.state ?? server.state) === "error" || server.refused
            ? "We can't ask it what it can do until it connects."
            : "Check it to see what it can do.";

  const how = server.url
    ? `${server.url}${server.oauth ? "\nsign-in: OAuth (browser)" : ""}`
    : [server.command ?? "", ...(server.args ?? [])].join(" \\\n  ") + (server.cd ? `\n(in ${server.cd})` : "");
  const keys = [...(server.env ?? []), ...(server.headers ?? [])];

  return (
    <div className="cx-details">
      {missing.length > 0 && !busy && <SecretForm server={server} keyName={missing[0]!} onSecret={onSecret} />}
      <div className="cx-tabs cx-tabs-small" role="tablist" aria-label={`About ${server.name}`}>
        <button type="button" role="tab" className="cx-tab" aria-selected={tab === "tools"} onClick={() => setTab("tools")}>
          What it can do {ready && about ? <span className="cx-count">{about.length}</span> : null}
        </button>
        <button type="button" role="tab" className="cx-tab" aria-selected={tab === "tech"} onClick={() => setTab("tech")}>
          Technical
        </button>
      </div>
      {tab === "tools" ? (
        <div role="tabpanel" className="cx-panel">
          {tools.length === 0 && <p className="cx-muted">{noTools}</p>}
          <ul>
            {tools.map((t) => (
              <li key={t.name} className="cx-tool">
                <div className="cx-grow">
                  <div className="cx-tool-title">{t.shown}</div>
                  <div className="cx-tool-said">{t.said}</div>
                </div>
                <span className={`cx-chip${t.read_only ? "" : " cx-chip-writes"}`}>{t.read_only ? "READS ONLY" : "CHANGES THINGS"}</span>
              </li>
            ))}
          </ul>
          {writes && (
            <p className="cx-muted cx-small">
              Agents ask you before using anything marked <span className="cx-mono cx-writes">CHANGES THINGS</span>, unless you let it run without asking. A server says
              which of its tools only read; Troupe takes its word.
            </p>
          )}
        </div>
      ) : (
        <div role="tabpanel" className="cx-tech">
          <div>
            <div className="cx-eyebrow">// HOW IT STARTS</div>
            <pre className="cx-cmd">{how}</pre>
            <p className="cx-muted cx-small">{originNote}</p>
          </div>
          <div>
            <div className="cx-eyebrow">// SECRETS AND SETTINGS</div>
            {keys.length === 0 && <p className="cx-muted cx-small">{server.url ? (server.oauth ? "Signs in through your browser. Nothing to paste." : "None needed.") : "None needed."}</p>}
            <ul className="cx-keys">
              {keys.map((k) => {
                const isMissing = missing.includes(k);
                const inKeychain = (server.secrets ?? []).includes(k);
                return (
                  <li key={k}>
                    <code className="cx-code">{k}</code>{" "}
                    <span className={`cx-mono ${isMissing ? "cx-writes" : "cx-ok"}`}>{isMissing ? "○ MISSING" : inKeychain ? "● IN KEYCHAIN" : "● SET"}</span>
                  </li>
                );
              })}
            </ul>
          </div>
          <div>
            <div className="cx-eyebrow">// TOOL NAMES</div>
            {tools.length === 0 && <p className="cx-muted cx-small">Not known until it connects.</p>}
            <div className="cx-names">
              {tools.map((t) => (
                <code key={t.name} className="cx-code cx-name">
                  mcp.{server.name}.{t.name}
                </code>
              ))}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

/** The value a server is missing, pasted into its row: kept in the keychain, never shown again. */
function SecretForm({ server, keyName, onSecret }: { server: LocalServer; keyName: string; onSecret: (key: string, value: string) => Promise<void> }): JSX.Element {
  const [value, setValue] = useState("");
  const [busy, setBusy] = useState(false);
  const id = `secret-${server.name}`;
  return (
    <form
      className="cx-secret"
      onSubmit={(e) => {
        e.preventDefault();
        if (!value.trim() || busy) return;
        setBusy(true);
        void onSecret(keyName, value.trim()).finally(() => {
          setBusy(false);
          setValue("");
        });
      }}
    >
      <label htmlFor={id} className="cx-secret-label">
        Paste your {keyName}
      </label>
      <span className="cx-muted cx-small">
        {server.name} needs this to start. You get it from whoever runs the service. We keep it in this computer&apos;s keychain, and your settings only point to it.
      </span>
      <div className="cx-secret-row">
        <input id={id} type="password" value={value} onChange={(e) => setValue(e.target.value)} autoComplete="off" spellCheck={false} placeholder="Paste it here" aria-label={`Value for ${keyName}`} />
        <button type="submit" className="cx-btn cx-btn-solid cx-attention" disabled={!value.trim() || busy}>
          {busy ? "Saving…" : "Save and check"}
        </button>
      </div>
    </form>
  );
}

// -- drawers --------------------------------------------------------------------------

function DrawerHead({ eyebrow, title, onClose }: { eyebrow: string; title: string; onClose: () => void }): JSX.Element {
  return (
    <div className="cx-drawer-head">
      <div className="cx-grow">
        <div className="cx-eyebrow">{eyebrow}</div>
        <h2 className="cx-h2">{title}</h2>
      </div>
      <button type="button" className="cx-icon-btn" aria-label="Close" onClick={onClose}>
        ✕
      </button>
    </div>
  );
}

/** Every project (your own settings), or one project's (its `.troupe/`). */
function ScopeChoices({ name, scope, folder, onScope, onFolder }: { name: string; scope: SourceScope; folder: string; onScope: (s: SourceScope) => void; onFolder: (f: string) => void }): JSX.Element {
  return (
    <>
      <label className="cx-choice">
        <input type="radio" name={name} checked={scope === "user"} onChange={() => onScope("user")} />
        <span>
          <span className="cx-choice-title">Every project</span>
          <span className="cx-choice-note">Any session on this computer.</span>
        </span>
      </label>
      <label className="cx-choice">
        <input type="radio" name={name} checked={scope === "workspace"} onChange={() => onScope("workspace")} />
        <span>
          <span className="cx-choice-title">One project</span>
          <span className="cx-choice-note">Only sessions started in this folder. Kept in its .troupe/, so whoever opens the repository has it too.</span>
        </span>
      </label>
      {scope === "workspace" && (
        <label className="cx-field cx-indent">
          <span className="cx-hint">Project folder</span>
          <input type="text" value={folder} onChange={(e) => onFolder(e.target.value)} placeholder="~/dev/my-project" spellCheck={false} aria-label="Project folder for it" className="cx-mono-input" />
        </label>
      )}
    </>
  );
}

function ImportDrawer({ client, project, onClose, onDone }: { client: DaemonClient; project: string; onClose: () => void; onDone: (said: string, added: string[]) => void }): JSX.Element {
  const [from, setFrom] = useState("");
  const [scope, setScope] = useState<SourceScope>("user");
  const [folder, setFolder] = useState(project);
  const [mode, setMode] = useState<"follow" | "copy">("follow");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const blocked = !from.trim() || (scope === "workspace" && !folder.trim());

  const bring = async (): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      const r = await client.importServers({ from: from.trim(), link: mode === "follow", scope, ...(scope === "workspace" ? { workspace: folder.trim() } : {}) });
      const head = r.added.length ? `Added ${r.added.join(", ")}${mode === "follow" ? `, following ${r.from ?? from}` : ""}. Checking them now.` : "Nothing new to add from that file.";
      const skipped = r.skipped.length ? ` Skipped ${r.skipped.map((s) => `${s.name} (${s.reason})`).join("; ")}.` : "";
      const needs = r.warnings?.length ? " Some need a secret: their rows say which." : "";
      onDone(head + skipped + needs, r.added);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setBusy(false);
    }
  };

  return (
    <aside className="cx-drawer" aria-label="Bring in servers">
      <DrawerHead eyebrow="// FROM ANOTHER APP" title="Bring in servers" onClose={onClose} />
      <fieldset className="cx-fieldset">
        <legend className="cx-legend">1. Pick the file</legend>
        <div className="cx-source">
          {KNOWN_FILES.map((k) => (
            <label key={k.file} className="cx-source-item">
              <input type="radio" name="from" checked={from === k.file} onChange={() => setFrom(k.file)} />
              <span className="cx-grow">
                <span className="cx-source-app">{k.app}</span>
                <span className="cx-code cx-muted cx-ellipsis cx-block">{k.file}</span>
              </span>
            </label>
          ))}
        </div>
        <label className="cx-field">
          <span className="cx-hint">Or a file somewhere else (a project&apos;s file is read from the project folder)</span>
          <input type="text" value={from} onChange={(e) => setFrom(e.target.value)} placeholder="~/somewhere/.mcp.json" spellCheck={false} aria-label="File to bring in" className="cx-mono-input" />
        </label>
      </fieldset>
      <fieldset className="cx-fieldset">
        <legend className="cx-legend">2. Where agents can use them</legend>
        <ScopeChoices name="import-scope" scope={scope} folder={folder} onScope={setScope} onFolder={setFolder} />
      </fieldset>
      <fieldset className="cx-fieldset">
        <legend className="cx-legend">3. When you change them in the other app</legend>
        <label className="cx-choice">
          <input type="radio" name="mode" checked={mode === "follow"} onChange={() => setMode("follow")} />
          <span>
            <span className="cx-choice-title">
              Follow along <span className="cx-mono cx-ok">SUGGESTED</span>
            </span>
            <span className="cx-choice-note">Troupe reads their file every time, so one place stays the truth.</span>
          </span>
        </label>
        <label className="cx-choice">
          <input type="radio" name="mode" checked={mode === "copy"} onChange={() => setMode("copy")} />
          <span>
            <span className="cx-choice-title">Keep my own copy</span>
            <span className="cx-choice-note">A snapshot in your Troupe settings. A key in it becomes a secret to paste here, never copied out of their file.</span>
          </span>
        </label>
      </fieldset>
      <Failed error={error} />
      <div className="cx-drawer-foot">
        <button type="button" className="cx-btn cx-btn-primary cx-grow" disabled={blocked || busy} onClick={() => void bring()}>
          {busy ? "Bringing them in…" : from.trim() ? "Bring them in" : "Pick a file"}
        </button>
        <button type="button" className="cx-btn cx-btn-quiet cx-btn-lg" onClick={onClose}>
          Cancel
        </button>
        <p className="cx-muted cx-small cx-full">We check each one right after adding it, so you see straight away if anything needs a secret.</p>
      </div>
    </aside>
  );
}

const NO_OAUTH: DraftOAuth = { clientId: "", scopes: "", issuer: "", redirectUri: "", resource: true };

function ManualDrawer({
  client,
  server,
  project,
  onClose,
  onDone,
}: {
  client: DaemonClient;
  server?: LocalServer | undefined;
  project: string;
  onClose: () => void;
  onDone: (name: string, said: string, checked: LocalServer | null) => void;
}): JSX.Element {
  const editing = Boolean(server);
  const [draft, setDraft] = useState<ServerDraft>(() => draftOf(server));
  const [line, setLine] = useState(() => (server && !server.url ? joinCommand(server.command ?? "", server.args ?? []) : ""));
  const [secretsText, setSecretsText] = useState(() => pairsToText(server?.url ? draftOf(server).headers : draftOf(server).env));
  const [scope, setScope] = useState<SourceScope>(server?.layer === "workspace" ? "workspace" : "user");
  const [folder, setFolder] = useState(project);
  const [busy, setBusy] = useState<"try" | "save" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tried, setTried] = useState<LocalServer | null>(null);
  const local = draft.transport === "stdio";

  // The command line into the entry's command and arguments, and the secrets' lines into rows.
  const words = splitCommand(line);
  const had = local ? draftOf(server).env : draftOf(server).headers;
  const rows = pairsFromText(secretsText, server && Boolean(server.url) === !local ? had : []);
  const full: ServerDraft = { ...draft, command: words[0] ?? "", args: words.slice(1).join("\n"), ...(local ? { env: rows, headers: [] } : { headers: rows, env: [] }) };
  const problems = draftProblems(full, { editing });
  const blocked = problems.length > 0 || (scope === "workspace" && !folder.trim());
  const ws = scope === "workspace" ? folder.trim() : project;

  const change = (patch: Partial<ServerDraft>): void => {
    setDraft((d) => ({ ...d, ...patch }));
    setTried(null);
  };

  const tryIt = async (): Promise<void> => {
    setBusy("try");
    setError(null);
    try {
      const { server: result } = await client.checkServer({ name: full.name, server: serverTrial(full).server, ...(ws ? { workspace: ws } : {}) });
      setTried(result);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const save = async (): Promise<void> => {
    setBusy("save");
    setError(null);
    try {
      const { patch, secrets } = serverChanges(full, server);
      const where = { scope, ...(scope === "workspace" ? { workspace: folder.trim() } : {}) };
      if (!editing || Object.keys(patch).length) await client.writeServer({ ...where, name: full.name, server: patch });
      for (const s of secrets) await client.setServerSecret({ ...where, name: full.name, key: s.key, field: s.field, value: s.value });
      const { server: checked } = await client.checkServer({ name: full.name, ...(ws ? { workspace: ws } : {}) });
      const kept = secrets.filter((s) => s.value !== null).map((s) => s.key);
      const keptSaid = kept.length ? ` ${kept.join(", ")} kept in your keychain.` : "";
      const n = checked.tools.length;
      const state = checked.state === "ready" ? `Ready, ${n} ${n === 1 ? "tool" : "tools"}.` : checked.state === "sign_in" ? "Sign in to use it: its row has the button." : (checked.error ?? "Saved.");
      onDone(full.name, `${editing ? "Saved" : "Added"} ${full.name}.${keptSaid} ${state}`, checked);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setBusy(null);
    }
  };

  return (
    <aside className="cx-drawer" aria-label={editing ? `Edit ${draft.name}` : "Set up a server by hand"}>
      <DrawerHead eyebrow={editing ? "// EDIT" : "// BY HAND"} title={editing ? `Edit ${draft.name}` : "Set up a server"} onClose={onClose} />
      <div className="cx-seg" role="group" aria-label="Where the server runs">
        <button type="button" aria-pressed={local} onClick={() => change({ transport: "stdio" })}>
          Runs on this computer
        </button>
        <button type="button" aria-pressed={!local} onClick={() => change({ transport: "http" })}>
          Lives at a URL
        </button>
      </div>
      <label className="cx-field">
        <span className="cx-field-label">Name</span>
        <input type="text" value={draft.name} onChange={(e) => change({ name: e.target.value })} disabled={editing} placeholder="linear" spellCheck={false} aria-label="Name" />
        <span className="cx-hint">Short, so agents can tell tools apart: mcp.{draft.name || "linear"}.create_issue.</span>
      </label>
      {local ? (
        <label className="cx-field">
          <span className="cx-field-label">Command</span>
          <textarea
            rows={2}
            value={line}
            onChange={(e) => {
              setLine(e.target.value);
              setTried(null);
            }}
            spellCheck={false}
            placeholder="npx -y @linear/mcp-server"
            aria-label="Command"
          />
          <span className="cx-hint">Paste the whole line, the way you would type it in a terminal.</span>
        </label>
      ) : (
        <>
          <label className="cx-field">
            <span className="cx-field-label">URL</span>
            <input type="text" value={draft.url} onChange={(e) => change({ url: e.target.value })} placeholder="https://mcp.example.com/mcp" spellCheck={false} aria-label="URL" className="cx-mono-input" />
          </label>
          <label className="cx-choice">
            <input type="checkbox" checked={draft.oauth !== null} onChange={(e) => change({ oauth: e.target.checked ? (draft.oauth ?? NO_OAUTH) : null })} aria-label="Signs me in" />
            <span>
              <span className="cx-choice-title">It signs me in</span>
              <span className="cx-choice-note">It acts as you. We open its sign-in in your browser after you add it, and keep the sign-in on this computer.</span>
            </span>
          </label>
        </>
      )}
      <label className="cx-field">
        <span className="cx-field-label">
          {local ? "Secrets and settings" : "Headers"} <span className="cx-optional">(optional)</span>
        </span>
        <textarea
          rows={3}
          value={secretsText}
          onChange={(e) => {
            setSecretsText(e.target.value);
            setTried(null);
          }}
          spellCheck={false}
          placeholder={local ? "LINEAR_API_KEY=lin_api_…" : "Authorization=Bearer …"}
          aria-label={local ? "Secrets and settings" : "Headers"}
        />
        <span className="cx-hint">
          One per line, NAME=value. Values go to your keychain; {"{env:NAME}"} reads one from the environment instead.
          {editing ? " A name alone keeps the value it has." : ""}
        </span>
      </label>
      {!editing && (
        <fieldset className="cx-fieldset">
          <legend className="cx-field-label">Use it in</legend>
          <ScopeChoices name="manual-scope" scope={scope} folder={folder} onScope={setScope} onFolder={setFolder} />
        </fieldset>
      )}
      <details className="cx-more">
        <summary>More options</summary>
        <label className="cx-choice">
          <input type="checkbox" checked={draft.permission === "auto"} onChange={(e) => change({ permission: e.target.checked ? "auto" : "ask" })} aria-label="Run without asking" />
          <span>
            <span className="cx-choice-title">Run its tools without asking</span>
            <span className="cx-choice-note">Otherwise agents ask you before each call.</span>
          </span>
        </label>
        <label className="cx-choice">
          <input type="checkbox" checked={draft.storesFiles} onChange={(e) => change({ storesFiles: e.target.checked })} aria-label="Stores files" />
          <span>
            <span className="cx-choice-title">Where my organisation keeps files</span>
            <span className="cx-choice-note">A file you ask an agent for goes here first.</span>
          </span>
        </label>
        {draft.storesFiles && (
          <label className="cx-field">
            <span className="cx-hint">Tools that save a file, comma-separated; empty: all of them</span>
            <input type="text" value={draft.files} onChange={(e) => change({ files: e.target.value })} spellCheck={false} aria-label="Tools that save a file" className="cx-mono-input" />
          </label>
        )}
        {local && (
          <label className="cx-field">
            <span className="cx-hint">Working directory; empty: the session&apos;s project</span>
            <input type="text" value={draft.cd} onChange={(e) => change({ cd: e.target.value })} spellCheck={false} aria-label="Working directory" className="cx-mono-input" />
          </label>
        )}
        <label className="cx-field">
          <span className="cx-hint">Start timeout in milliseconds; empty: 30000</span>
          <input type="text" value={draft.timeoutMs} onChange={(e) => change({ timeoutMs: e.target.value })} inputMode="numeric" aria-label="Start timeout" />
        </label>
        {!local && draft.oauth && (
          <>
            <label className="cx-field">
              <span className="cx-hint">Client ID; empty: Troupe introduces itself</span>
              <input type="text" value={draft.oauth.clientId} onChange={(e) => change({ oauth: { ...draft.oauth!, clientId: e.target.value } })} spellCheck={false} aria-label="Client ID" className="cx-mono-input" />
            </label>
            <label className="cx-field">
              <span className="cx-hint">Scopes, space-separated; empty: what the server asks for</span>
              <input type="text" value={draft.oauth.scopes} onChange={(e) => change({ oauth: { ...draft.oauth!, scopes: e.target.value } })} spellCheck={false} aria-label="Scopes" className="cx-mono-input" />
            </label>
            <label className="cx-field">
              <span className="cx-hint">Issuer, for a server that names no authorization server</span>
              <input type="text" value={draft.oauth.issuer} onChange={(e) => change({ oauth: { ...draft.oauth!, issuer: e.target.value } })} spellCheck={false} aria-label="Issuer" className="cx-mono-input" />
            </label>
            <label className="cx-field">
              <span className="cx-hint">Redirect URI, for a client registered with one port</span>
              <input type="text" value={draft.oauth.redirectUri} onChange={(e) => change({ oauth: { ...draft.oauth!, redirectUri: e.target.value } })} spellCheck={false} aria-label="Redirect URI" className="cx-mono-input" />
            </label>
            <label className="cx-choice">
              <input type="checkbox" checked={draft.oauth.resource} onChange={(e) => change({ oauth: { ...draft.oauth!, resource: e.target.checked } })} aria-label="Resource indicator" />
              <span>
                <span className="cx-choice-title">Send the resource indicator</span>
                <span className="cx-choice-note">Off for Microsoft Entra ID&apos;s v2.0 endpoint.</span>
              </span>
            </label>
          </>
        )}
      </details>
      {problems.length > 0 && (draft.name || line || draft.url) && (
        <ul className="cx-problems">
          {problems.map((p) => (
            <li key={p}>{p}</li>
          ))}
        </ul>
      )}
      <Failed error={error} />
      {(busy === "try" || tried) && (
        <div role="status" className={`cx-test${tried?.state === "ready" ? " cx-test-ok" : ""}`}>
          {busy === "try"
            ? "Starting it…"
            : tried?.state === "ready"
              ? `It started and offered ${tried.tools.length} ${tried.tools.length === 1 ? "tool" : "tools"}: ${tried.tools.join(", ")}. Nothing is kept until you add it.`
              : tried?.state === "sign_in"
                ? "It wants you signed in. Add it, then sign in from its row."
                : `It did not start: ${tried?.error ?? tried?.state ?? "no answer"}`}
        </div>
      )}
      <div className="cx-drawer-foot">
        <button type="button" className="cx-btn cx-btn-primary cx-grow" disabled={blocked || busy !== null} onClick={() => void save()}>
          {busy === "save" ? "Saving…" : editing ? "Save" : "Add server"}
        </button>
        <button type="button" className="cx-btn cx-btn-lg" disabled={blocked || busy !== null} onClick={() => void tryIt()}>
          {busy === "try" ? "Trying…" : "Try it first"}
        </button>
      </div>
    </aside>
  );
}

// -- skills ---------------------------------------------------------------------------

function SkillsTab({
  client,
  project,
  skills,
  skipped,
  found,
  onDone,
  onError,
}: {
  client: DaemonClient;
  project: string;
  skills: LocalSkill[];
  skipped: SkippedSkill[];
  found: FoundSkills[];
  onDone: (said: string) => void;
  onError: (why: string) => void;
}): JSX.Element {
  const [busy, setBusy] = useState<string | null>(null);
  const available = found.filter((f) => f.state === "available");

  const bring = async (f: FoundSkills, link: boolean): Promise<void> => {
    setBusy(f.from);
    try {
      const r = await client.importSkills({ from: f.from, link, scope: f.scope, ...(f.scope === "workspace" && project ? { workspace: project } : {}) });
      onDone(link ? `Using ${r.added.length} skills from ${f.dir}.` : `Copied ${r.added.length} skills into your Troupe settings.`);
    } catch (e) {
      onError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const remove = async (skill: LocalSkill | SkippedSkill): Promise<void> => {
    const layer = skill.layer === "user" || skill.layer === "workspace" ? skill.layer : null;
    if (!layer || !skill.name) {
      onError(
        skill.layer === "agents"
          ? `${skill.name} is the repository's, in ${skill.dir}: Troupe reads .agents/skills where it is and never writes there, so remove it from the repository.`
          : `${skill.name ?? skill.dir} is in ${skill.dir}, which other tools read too: Troupe reads it where it is and never writes there, so remove it there.`,
      );
      return;
    }
    try {
      const r = await client.removeSkill({ scope: layer, ...(layer === "workspace" && project ? { workspace: project } : {}), name: skill.name });
      onDone(`Removed ${r.removed.join(", ")} from ${r.path}.`);
    } catch (e) {
      onError(e instanceof Error ? e.message : String(e));
    }
  };

  return (
    <div className="cx-skills">
      {available.map((f) => (
        <div key={f.from} className="cx-found">
          <div className="cx-grow">
            <div className="cx-found-title">{f.app} skills</div>
            <div className="cx-code cx-muted">
              {f.dir} · {f.skills.length} {f.skills.length === 1 ? "skill" : "skills"}: {f.skills.map((s) => s.name).join(", ")}
            </div>
          </div>
          <button type="button" className="cx-btn cx-btn-solid cx-ready" disabled={busy !== null} onClick={() => void bring(f, true)}>
            Use this folder
          </button>
          <button type="button" className="cx-btn" disabled={busy !== null} onClick={() => void bring(f, false)}>
            Copy them in
          </button>
        </div>
      ))}
      {available.length > 0 && (
        <p className="cx-muted cx-small">“Use this folder” keeps reading it, so edits you make in the other app show up here. “Copy them in” takes a snapshot you can change without touching the originals.</p>
      )}
      {skills.length === 0 && available.length === 0 && (
        <div className="cx-empty">
          <p className="cx-empty-title">No skills yet</p>
          <p className="cx-muted">A skill is a folder of instructions an agent reads when a task matches it. Put one in a skills folder of yours, or bring in another app&apos;s.</p>
        </div>
      )}
      <ul className="cx-skill-list">
        {skills.map((k) => (
          <li key={`${k.layer}:${k.name}`} className="cx-skill">
            <span className="cx-skill-name">{k.name}</span>
            <span className="cx-grow cx-muted">{k.description}</span>
            <span className={`cx-mono${k.linked ? " cx-follows" : ""}`}>{k.linked ? `↻ FOLLOWS ${k.source}` : k.layer === "workspace" ? "THIS PROJECT" : k.layer === "user" ? "YOURS" : `READ FROM ${k.source}`}</span>
            <button type="button" className="cx-btn cx-btn-quiet cx-danger" aria-label={`Remove ${k.name}`} onClick={() => void remove(k)}>
              Remove
            </button>
          </li>
        ))}
      </ul>
      {skipped.length > 0 && (
        <>
          <h3 className="cx-subhead">Not offered</h3>
          <ul className="cx-skill-list">
            {skipped.map((k) => (
              <li key={`${k.layer}:${k.dir}`} className="cx-skill cx-skill-skipped">
                <span className="cx-skill-name">{k.name ?? "(the whole folder)"}</span>
                <span className="cx-grow cx-muted">{k.reason}</span>
              </li>
            ))}
          </ul>
        </>
      )}
    </div>
  );
}
