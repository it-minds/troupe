// Which agent a window runs, in the session's head, and the one agent picker over it
// (troupe #503 and #594, Decision 841).
//
// `profile.switch` changes the agent of a session, or of a branch, which is a session:
// the conversation stays, and from its next turn the new definition's tools, permissions,
// prompt and model apply, read from its file at the switch. The transcript says so with
// the session's `profile_switched`, so this control holds nothing of its own: it offers
// the primary agents and asks.
//
// What is offered is what the session could run, as the session's own `agents.list`
// answers (`SessionView.agents`): on this computer its workspace's, on the platform its
// profile bundle's and the built-ins, each with where it comes from. A plane profile is
// not an agent, so the plane's profiles are not offered here. A daemon or a pod from
// before that listing is asked what it answered before: the workspace's `agents.list`, or
// the agents section of the session's `commands.list`.
//
// From the picker a session is started on the agent too, beside this one (in the same
// workspace on this computer, on the same profile on the platform), and a person's or a
// repository's agent is opened in their editor.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { onThisComputer } from "@troupe/client";
import type { AgentRow, AuthSession, DaemonClient, SessionKind } from "@troupe/client";
import type { SessionHandle } from "../hooks";
import { AgentPicker } from "./AgentPicker";
import type { PickerAction } from "./AgentPicker";

/** The agents a session could run, by its own listing, or as an older server answered. */
function useRows(view: SessionHandle, daemon: DaemonClient | null, kind: SessionKind, workspace: string | null): { rows: AgentRow[] | null; error: string | null } {
  const [rows, setRows] = useState<AgentRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [round, setRound] = useState(0);
  const local = onThisComputer(kind) && daemon !== null;

  useEffect(() => (local ? daemon!.onAgentsChanged(() => setRound((n) => n + 1)) : undefined), [local, daemon]);

  useEffect(() => {
    let live = true;
    const v = view.view;
    if (!v) return;
    const older = (): Promise<AgentRow[]> =>
      local && workspace
        ? daemon!.listAgents(workspace).then((r) => r.agents)
        : v.commands().then((r) =>
            r.commands
              .filter((c) => c.section === "agents" && c.source === "agent")
              .map((c) => ({ name: c.name, description: c.summary, source: "bundle", layer: "bundle" as const })),
          );
    void v
      .agents()
      .then((r) => r.agents)
      .catch(() => older())
      .then((r) => {
        if (!live) return;
        setRows(r);
        setError(null);
      })
      .catch((e: unknown) => live && setError(e instanceof Error ? e.message : String(e)));
    return () => {
      live = false;
    };
  }, [view.view, daemon, local, workspace, round]);

  return { rows, error };
}

export function AgentSwitch({
  view,
  auth,
  daemon,
  kind,
  workspace,
  planeProfile,
  current,
  canChange,
  onAbout,
  onStarted,
}: {
  view: SessionHandle;
  /** The plane, for a session on it: a start there is the plane's. */
  auth?: AuthSession | null;
  daemon: DaemonClient | null;
  kind: SessionKind;
  /** The session's workspace, where it is this computer's and the list knows it. */
  workspace: string | null;
  /** The plane's profile a session on the platform runs on, which a start beside it names. */
  planeProfile?: string | null;
  current: string | null;
  canChange: boolean;
  /** Open the agent in the agents manager, where the session is this computer's. */
  onAbout?: ((name: string) => void) | undefined;
  /** A session started from the picker, to open. */
  onStarted?: ((id: string, kind: SessionKind, workspace?: string) => void) | undefined;
}): JSX.Element | null {
  const { rows, error } = useRows(view, daemon, kind, workspace);
  const [open, setOpen] = useState(false);

  if (!view.view) return null;

  const switchTo: PickerAction = canChange
    ? async (name) => {
        if (name === current) throw new Error(`This session runs ${name} already.`);
        await view.switchProfile(name);
        setOpen(false);
      }
    : "You can read this session, not change the agent it runs.";

  const start: PickerAction =
    kind === "remote"
      ? "A session on somebody's laptop is started on that laptop."
      : kind === "team"
      ? auth && planeProfile
        ? async (name) => {
            const created = await auth.rpc<{ session_id: string }>("session.create", { profile: planeProfile, agent: name });
            setOpen(false);
            onStarted?.(created.session_id, "team");
          }
        : "A session on the platform is started from New session, on a profile."
      : daemon && workspace
        ? async (name) => {
            const created = await daemon.createSession({ workspace, profile: name });
            setOpen(false);
            onStarted?.(created.session_id, kind === "private" ? "private" : "local", created.workspace);
          }
        : "This session's workspace is not known here: start one from New session.";

  return (
    <div className="agent-switch">
      <button
        type="button"
        className="agent-current"
        aria-expanded={open}
        aria-label="Agent"
        title="The agent this session runs: switch it, start another session on one, or edit one."
        onClick={() => setOpen((o) => !o)}
      >
        Agent <span className="mono">{current ?? "—"}</span>
      </button>
      {onAbout && current && (
        <button type="button" className="link" onClick={() => onAbout(current)}>
          About
        </button>
      )}
      {open && <AgentPicker label="Agents" rows={rows} error={error} current={current} start={start} switchTo={switchTo} />}
    </div>
  );
}
