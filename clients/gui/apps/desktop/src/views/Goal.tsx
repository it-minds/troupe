// The session's goal and the loop that works towards it (issue #59), in the session's
// head: the goal under the title, clipped to one line with the whole of it on hover and
// a click away, and the loop beside the status while it runs — "iteration 2/5", the
// terminal client's status line in this app's words. Both are set here as well as by
// /goal and /loop, and both are drawn from the session's events, so a change made from
// another client shows here as it happens. The loop runs on its own and never takes the
// input box: what a person sends meanwhile goes between two of its iterations.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { ErrorCodes, loopEnding, TroupeRpcError } from "@troupe/client";
import type { LoopState } from "@troupe/client";
import { Pill } from "./bits";

/** A refused loop, said the way a person would: what is missing, not the method and its code. */
export function loopError(e: unknown): string {
  if (e instanceof TroupeRpcError && e.code === ErrorCodes.conflict) {
    if (e.data?.["needs"] === "goal") return "A loop works towards the session's goal, and this session has none. Set a goal first.";
    if (typeof e.data?.["loop_id"] === "string") return "A loop is already running here. Stop it before starting another.";
  }
  if (e instanceof TroupeRpcError && e.code === ErrorCodes.invalid_params && e.data?.["field"] === "max_iterations") {
    return "The number of iterations is a whole number, one or more.";
  }
  return e instanceof Error ? e.message : String(e);
}

function message(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/**
 * The goal line, under the session's title. With no goal it is one link to set one;
 * with a goal, the goal and what can be done about it: loop towards it, change it,
 * clear it. A person who can only read the session reads the goal and nothing else.
 */
export function GoalLine({
  goal,
  loop,
  canChange,
  onSet,
  onClear,
  onStartLoop,
}: {
  goal: string | undefined;
  loop: LoopState | undefined;
  canChange: boolean;
  onSet: (text: string) => Promise<void>;
  onClear: () => Promise<void>;
  onStartLoop: (max?: number) => Promise<void>;
}): JSX.Element | null {
  const [mode, setMode] = useState<"show" | "edit" | "loop">("show");
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState("");
  const [cap, setCap] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const running = loop?.state === "running";

  // Another client's change closes whatever was half-done here about the old goal.
  useEffect(() => {
    setOpen(false);
    setMode((m) => (m === "loop" && !goal ? "show" : m));
  }, [goal]);

  const act = async (what: () => Promise<void>, refusal: (e: unknown) => string = message): Promise<boolean> => {
    setBusy(true);
    setError(null);
    try {
      await what();
      return true;
    } catch (e) {
      setError(refusal(e));
      return false;
    } finally {
      setBusy(false);
    }
  };

  const edit = (): void => {
    setDraft(goal ?? "");
    setError(null);
    setMode("edit");
  };

  const errorLine = error && (
    <p className="note error" role="alert">
      {error}
    </p>
  );

  if (mode === "edit") {
    return (
      <div className="goal-block">
        <form
          className="goal editing"
          onSubmit={(e) => {
            e.preventDefault();
            const text = draft.trim();
            if (text) void act(() => onSet(text)).then((ok) => ok && setMode("show"));
          }}
        >
          <span className="label">Goal</span>
          <input
            aria-label="Goal"
            value={draft}
            autoFocus
            placeholder="What every turn works towards, until it is met"
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => e.key === "Escape" && setMode("show")}
          />
          <button type="submit" className="link" disabled={busy || !draft.trim()}>
            {goal ? "Change" : "Set"}
          </button>
          <button type="button" className="link" onClick={() => setMode("show")}>
            Cancel
          </button>
        </form>
        {errorLine}
      </div>
    );
  }

  if (!goal) {
    if (!canChange) return null;
    return (
      <div className="goal-block">
        <div className="goal none">
          <button type="button" className="link" onClick={edit} title="A goal is read into every turn until it is met or cleared, and a loop works towards it on its own">
            Set a goal
          </button>
        </div>
        {errorLine}
      </div>
    );
  }

  return (
    <div className="goal-block">
      <div className={`goal shown${open ? " open" : ""}`}>
        <span className="label">Goal</span>
        <button type="button" className="text" title={goal} aria-expanded={open} aria-label={`Goal: ${goal}`} onClick={() => setOpen((o) => !o)}>
          {goal}
        </button>
        {canChange && (
          <span className="actions">
            {!running && (
              <button type="button" className="link" onClick={() => setMode(mode === "loop" ? "show" : "loop")} aria-expanded={mode === "loop"}>
                Loop
              </button>
            )}
            <button type="button" className="link" onClick={edit}>
              Change
            </button>
            <button type="button" className="link" disabled={busy} onClick={() => void act(onClear)}>
              Clear
            </button>
          </span>
        )}
      </div>

      {mode === "loop" && !running && (
        <form
          className="goal looping"
          onSubmit={(e) => {
            e.preventDefault();
            const n = cap.trim() === "" ? undefined : Number(cap);
            if (n !== undefined && !(Number.isInteger(n) && n > 0)) {
              setError("The number of iterations is a whole number, one or more.");
              return;
            }
            void act(() => onStartLoop(n), loopError).then((ok) => {
              if (!ok) return;
              setMode("show");
              setCap("");
            });
          }}
        >
          <span className="label">Loop</span>
          <label className="inline">
            up to
            <input aria-label="Iterations at most" inputMode="numeric" value={cap} placeholder="its limit" onChange={(e) => setCap(e.target.value)} />
            iterations
          </label>
          <button type="submit" className="link" disabled={busy}>
            Start the loop
          </button>
          <button type="button" className="link" onClick={() => setMode("show")}>
            Cancel
          </button>
        </form>
      )}

      {loop?.state === "stopped" && <p className="goal-note">{loopEnding(loop)}</p>}
      {errorLine}
    </div>
  );
}

/**
 * The loop while it runs, beside the session's status: which iteration, of how many,
 * and the one control it needs. Stopping works mid-iteration, from here or any client:
 * the loop's own turn is cancelled, and a person's turn is left to finish.
 */
export function LoopStatus({ loop, canStop, onStop }: { loop: LoopState | undefined; canStop: boolean; onStop: () => Promise<void> }): JSX.Element | null {
  const [stopping, setStopping] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    setStopping(false);
    setError(null);
  }, [loop?.id, loop?.state]);

  if (!loop || loop.state !== "running") return null;
  const where = loop.iteration === 0 ? "starting" : `iteration ${loop.iteration}${loop.max ? `/${loop.max}` : ""}`;

  return (
    <>
      <Pill status="running" title="A loop towards the goal: one turn per iteration, until the agent says the goal is met or the limit is reached">
        {`Loop · ${where}${stopping ? " · stopping" : ""}`}
      </Pill>
      {canStop && (
        <button
          type="button"
          className="tab"
          disabled={stopping}
          onClick={() => {
            setStopping(true);
            setError(null);
            onStop().catch((e: unknown) => {
              setStopping(false);
              setError(message(e));
            });
          }}
        >
          Stop loop
        </button>
      )}
      {error && <span className="note error">{error}</span>}
    </>
  );
}
