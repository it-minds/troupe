// The first run's questions, one screen per step, over the flow the daemon holds
// (troupe Decision 705). This decides nothing about the answers — the daemon does —
// and only shows the step it is at and sends what the person chose. Going back is a
// move on the daemon too, so the answers a person sees are the ones it has.
//
// `SetupSteps` is the flow; `SetupScreen` is it as the rail's Setup entry, re-runnable
// at any time, which is also where a session with a refused key sends people.

import type { JSX } from "react";
import { previousStep } from "@troupe/client";
import type { DaemonClient, SetupFlow, SetupStepName } from "@troupe/client";
import { Failed, Loading } from "../bits";
import { Daemon } from "./Daemon";
import { Finish } from "./Finish";
import { Key } from "./Key";
import { PickModels } from "./PickModels";
import { Provider } from "./Provider";
import { useSetupFlow } from "./hooks";
import { Where } from "./Where";
import { Workspace } from "./Workspace";

/** How a run ended: the session it started, and where, or the plane to sign in to. */
export interface SetupOutcome {
  sessionId: string | null;
  /** The workspace that session started in: its start goes on as a new session's does. */
  workspace?: string | null;
  plane: string | null;
}

export function SetupSteps({ client, onDone }: { client: DaemonClient | null; onDone: (outcome: SetupOutcome) => void }): JSX.Element {
  const setup = useSetupFlow(client);

  if (!client) {
    return <p className="note">The daemon on this computer is not connected. Connect it on This computer, then come back.</p>;
  }
  if (setup.unsupported) return <p className="note">{setup.error}</p>;
  if (!setup.flow) return setup.error ? <Failed error={setup.error} /> : <Loading what="Asking the daemon where the setup stands…" />;

  const flow = setup.flow;
  if (flow.step === "done") return <Loading what="Finishing…" />;

  const step = flow.step;
  const before = previousStep(flow, step);
  const common = {
    flow,
    busy: setup.busy,
    error: setup.error,
    onBack: before ? () => void setup.answer(before, { back: true }) : null,
  };
  const answer = (a: Record<string, unknown>): void => void setup.answer(step, a);

  switch (step) {
    case "where":
      return <Where {...common} onAnswer={answer} />;
    case "provider":
      return <Provider {...common} onAnswer={answer} />;
    case "key":
      return <Key {...common} onAnswer={answer} />;
    case "models":
      return <PickModels {...common} onAnswer={answer} />;
    case "workspace":
      return <Workspace {...common} client={client} onAnswer={answer} />;
    case "daemon":
      return <Daemon {...common} onAnswer={answer} />;
    case "finish":
      return (
        <Finish
          {...common}
          onAnswer={(a) =>
            void setup.answer("finish", a).then((next) => {
              if (next) onDone(outcomeOf(next));
            })
          }
        />
      );
  }
}

function outcomeOf(flow: SetupFlow): SetupOutcome {
  const plane = flow.answers.where?.["choice"] === "plane";
  return {
    sessionId: flow.session?.session_id ?? null,
    workspace: flow.session?.session_id ? flow.session.workspace : null,
    plane: plane ? ((flow.answers.where?.["plane_url"] as string | null) ?? "") : null,
  };
}

/** The rail's Setup entry: the same questions, any time. */
export function SetupScreen({ client, onDone }: { client: DaemonClient | null; onDone: (outcome: SetupOutcome) => void }): JSX.Element {
  return (
    <div className="listing">
      <div className="stack" style={{ maxWidth: 900, gap: "var(--space-6)", padding: "var(--space-4) var(--space-6)" }}>
        <header className="stack" style={{ gap: "var(--space-2)" }}>
          <h1>Setup</h1>
          <p style={{ margin: 0, maxWidth: "var(--measure-reading)", color: "var(--text-secondary)" }}>
            The first run&apos;s questions, again: the provider, the key, the models, a project, and whether the daemon starts when you log
            in. Everything is written to this computer&apos;s own settings, and the terminal client reads the same file.
          </p>
        </header>
        <SetupSteps client={client} onDone={onDone} />
      </div>
    </div>
  );
}

export type { SetupStepName };
