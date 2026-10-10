// Which agent a window runs, and the switch (troupe #503, Decision 841).
//
// `profile.switch` changes the agent of a session, or of a branch, which is a session:
// the conversation stays, and from its next turn the new definition's tools, permissions,
// prompt and model apply, read from its file at the switch. The transcript says so with
// the session's `profile_switched`, so this control holds nothing of its own: it offers
// the primary agents and asks.
//
// What is offered is what the session could run. On this computer that is `agents.list`
// for its workspace, with where each agent comes from; on the platform it is the agents
// section of the session's own `commands.list`, its profile bundle's, as the team's
// grant narrows them. A plane profile is not an agent, so the plane's profiles are not
// offered here.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { layerOf, layerWords } from "@troupe/client";
import type { DaemonClient, SessionKind } from "@troupe/client";
import type { SessionHandle } from "../hooks";

interface Target {
  name: string;
  description: string;
  /** Where it comes from, when the daemon says. */
  where: string | null;
  readOnly: boolean;
  /** Why a session could not run it here, or null. */
  unavailable: string | null;
}

/** The agents a session could switch to, from the daemon where the session is this computer's. */
function useTargets(view: SessionHandle, daemon: DaemonClient | null, kind: SessionKind, workspace: string | null): Target[] {
  const [targets, setTargets] = useState<Target[]>([]);
  const [round, setRound] = useState(0);
  const local = kind !== "team" && daemon !== null && workspace !== null;

  useEffect(() => (local ? daemon!.onAgentsChanged(() => setRound((n) => n + 1)) : undefined), [local, daemon]);

  useEffect(() => {
    let live = true;
    const v = view.view;
    const read: Promise<Target[]> | null = local
      ? daemon!.listAgents(workspace!).then((r) =>
          r.agents.map((a) => ({
            name: a.name,
            description: a.description,
            where: layerWords(layerOf(a)),
            readOnly: Boolean(a.read_only),
            unavailable: a.available === false ? (a.reason ?? "it cannot run here") : null,
          })),
        )
      : v
        ? v.commands().then((r) =>
            r.commands
              .filter((c) => c.section === "agents" && c.source === "agent")
              .map((c) => ({ name: c.name, description: c.summary, where: null, readOnly: false, unavailable: null })),
          )
        : null;
    void read?.then((t) => live && setTargets(t)).catch(() => undefined);
    return () => {
      live = false;
    };
  }, [view.view, daemon, local, workspace, round]);

  return targets;
}

export function AgentSwitch({
  view,
  daemon,
  kind,
  workspace,
  current,
  canChange,
  onAbout,
}: {
  view: SessionHandle;
  daemon: DaemonClient | null;
  kind: SessionKind;
  /** The session's workspace, where it is this computer's and the list knows it. */
  workspace: string | null;
  current: string | null;
  canChange: boolean;
  /** Open the agent in the agents manager, where the session is this computer's. */
  onAbout?: ((name: string) => void) | undefined;
}): JSX.Element | null {
  const targets = useTargets(view, daemon, kind, workspace);
  const [busy, setBusy] = useState(false);
  // Only a refusal is said here: a switch that took is the transcript's to record.
  const [refused, setRefused] = useState<string | null>(null);

  if (!canChange || targets.length === 0) return null;
  const shown = current && !targets.some((t) => t.name === current) ? [{ name: current, description: "", where: null, readOnly: false, unavailable: null }, ...targets] : targets;
  const now = targets.find((t) => t.name === current);

  const switchTo = async (name: string): Promise<void> => {
    if (!name || name === current) return;
    setBusy(true);
    setRefused(null);
    try {
      await view.switchProfile(name);
    } catch (e) {
      setRefused(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="agent-switch">
      <label
        className="inline"
        title={`${now ? `${now.description}${now.where ? ` (${now.where})` : ""}. ` : ""}Another applies from the next turn; the conversation stays.`}
      >
        Agent
        <select value={current ?? ""} onChange={(e) => void switchTo(e.target.value)} disabled={busy} aria-label="Agent">
          {shown.map((t) => (
            <option key={t.name} value={t.name} disabled={t.unavailable !== null && t.name !== current} title={t.unavailable ?? t.description}>
              {t.name}
              {t.where ? ` · ${t.where}` : ""}
              {t.readOnly ? " · read only" : ""}
              {t.unavailable ? " · cannot run here" : ""}
            </option>
          ))}
        </select>
      </label>
      {onAbout && current && (
        <button type="button" className="link" onClick={() => onAbout(current)}>
          About
        </button>
      )}
      {refused && (
        <span className="micro error" role="alert">
          {refused}
        </span>
      )}
    </div>
  );
}
