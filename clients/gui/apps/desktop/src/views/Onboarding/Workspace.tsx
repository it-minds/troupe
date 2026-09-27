// Step 5: the first project directory, and what the agent may do there without
// asking — two sentences per choice, the safe one pressed already.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { APPROVAL_CHOICES } from "@troupe/client";
import type { DaemonClient } from "@troupe/client";
import { shell } from "../../shell";
import { Actions, StepFrame } from "./Step";
import type { StepProps } from "./Step";

export function Workspace({ client, flow, busy, error, onAnswer, onBack }: StepProps & { client: DaemonClient }): JSX.Element {
  const earlier = flow.answers.workspace;
  const [workspace, setWorkspace] = useState<string>((earlier?.["workspace"] as string | null) ?? "");
  const [approvals, setApprovals] = useState<"ask" | "auto">(earlier?.["approvals"] === "auto" ? "auto" : "ask");
  const [recent, setRecent] = useState<string[]>([]);
  const picker = shell()?.pickDirectory;

  useEffect(() => {
    let live = true;
    void client
      .recentWorkspaces()
      .then((r) => live && setRecent(r.workspaces.slice(0, 6).map((w) => w.path)))
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [client]);

  return (
    <StepFrame
      flow={flow}
      title="Where is the first project?"
      lede="A session works in one directory: it reads there, edits there, runs commands there, and nothing Troupe keeps for itself lands in it."
      error={error}
    >
      <label>
        Directory
        <div className="inline-form" style={{ marginBottom: 0 }}>
          <input
            value={workspace}
            onChange={(e) => setWorkspace(e.target.value)}
            placeholder={picker ? "Choose one, or type a path" : "/home/you/project"}
            spellCheck={false}
            aria-label="Directory"
            style={{ flex: 1 }}
          />
          {picker && (
            <button type="button" onClick={() => void picker().then((p) => p && setWorkspace(p))}>
              Choose…
            </button>
          )}
        </div>
      </label>

      {recent.length > 0 && (
        <div className="stack" style={{ gap: "var(--space-2)" }}>
          <h3>Recently</h3>
          <div className="chips">
            {recent.map((path) => (
              <button key={path} type="button" className="chip as-button" onClick={() => setWorkspace(path)}>
                {path}
              </button>
            ))}
          </div>
        </div>
      )}

      <div className="stack" style={{ gap: "var(--space-2)" }}>
        <h3>What the agent may do without asking</h3>
        <div className="options">
          {APPROVAL_CHOICES.map((c) => (
            <button key={c.id} type="button" className="option" aria-pressed={approvals === c.id} onClick={() => setApprovals(c.id)}>
              <span className="label">
                {c.label}
                {c.id === "ask" && <span className="micro"> · default</span>}
              </span>
              <span className="consequence">{c.consequence}</span>
            </button>
          ))}
        </div>
      </div>

      <Actions
        busy={busy}
        next="Continue"
        disabled={workspace.trim() === ""}
        onBack={onBack}
        onNext={() => onAnswer({ workspace: workspace.trim(), approvals })}
      />
    </StepFrame>
  );
}
