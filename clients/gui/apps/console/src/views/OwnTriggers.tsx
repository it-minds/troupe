// A person's own triggers on the console (troupe #1235), for everybody who signs in: the
// reruns a yes of theirs turned on, which run as them and spend their budget. Your triggers
// stands under Your sessions on Sessions' Mine, each with whether it is on and when it runs
// next, how its last run went and what a run may spend, and Switch off or Switch on and
// Remove, asked once more in place. Each is what the desktop asks (`trigger.own.*`), as the
// person; a plane whose `initialize` does not say `own_triggers` is asked nothing, and the
// section says so.

import { useState } from "react";
import type { JSX } from "react";
import { OWN_TRIGGER_ACTIONS, lastRunWords, ownBudgetWords, ownTriggerRefusal, ownTriggerState, planeKnowsOwnTriggers, removeConfirm } from "@troupe/client";
import type { OwnTrigger, OwnTriggerAction } from "@troupe/client";
import { useConsole, useLoad } from "../console";
import type { Load } from "../console";
import { Empty, Loaded, Region } from "./bits";

/** The person's own triggers as the plane lists them, or `null` where it has none to list; with a reload. */
function useOwnTriggers(): [Load<OwnTrigger[] | null>, () => void] {
  const { auth } = useConsole();
  return useLoad(async () => {
    if (!(await planeKnowsOwnTriggers(auth))) return null;
    return (await auth.withToken((plane, token) => plane.listOwnTriggers(token))).triggers;
  }, [auth]);
}

/** Switch off or on, and Remove asked once more; what a refusal said beside them. */
function OwnTriggerControls({ trigger, onChanged }: { trigger: OwnTrigger; onChanged: () => void }): JSX.Element {
  const { auth, notify } = useConsole();
  const [busy, setBusy] = useState(false);
  const [asking, setAsking] = useState(false);
  const [refused, setRefused] = useState<string | null>(null);
  const act = async (action: OwnTriggerAction): Promise<void> => {
    setBusy(true);
    setRefused(null);
    try {
      await auth.withToken<unknown>((plane, token) => (action === "remove" ? plane.removeOwnTrigger(token, trigger.id) : plane.switchOwnTrigger(token, trigger.id, action === "on")));
      notify(action === "remove" ? `${trigger.name} is removed.` : action === "off" ? `${trigger.name} is switched off.` : `${trigger.name} is switched on.`);
      setAsking(false);
      onChanged();
    } catch (e) {
      setRefused(ownTriggerRefusal(e, action));
    } finally {
      setBusy(false);
    }
  };
  const flip: OwnTriggerAction = trigger.enabled ? "off" : "on";
  return asking ? (
    <span role="group" aria-label={`Remove ${trigger.name}?`}>
      {removeConfirm(trigger)}{" "}
      <button type="button" className="link" disabled={busy} onClick={() => void act("remove")}>
        {OWN_TRIGGER_ACTIONS.remove.label}
      </button>
      {" · "}
      <button type="button" className="link" disabled={busy} onClick={() => setAsking(false)}>
        Keep it
      </button>
    </span>
  ) : (
    <>
      <button type="button" className="link" disabled={busy} onClick={() => void act(flip)}>
        {busy ? OWN_TRIGGER_ACTIONS[flip].busy : OWN_TRIGGER_ACTIONS[flip].label}
      </button>
      {" · "}
      <button type="button" className="link" disabled={busy} onClick={() => setAsking(true)}>
        {OWN_TRIGGER_ACTIONS.remove.label}
      </button>
      {refused && (
        <span className="hint" role="alert">
          {" "}
          {refused}
        </span>
      )}
    </>
  );
}

/** Sessions' Mine, after Your sessions: the person's own triggers across their teams. */
export function YourTriggers(): JSX.Element {
  const [load, reload] = useOwnTriggers();
  return (
    <section aria-label="Your triggers">
      <Region>Your triggers</Region>
      <Loaded load={load} what="your triggers" retry={reload}>
        {(triggers) =>
          triggers === null ? (
            <Empty title="This plane does not let you change your own triggers yet">A rerun you turned on from a session runs until a team admin switches it off, on Triggers.</Empty>
          ) : triggers.length === 0 ? (
            <Empty title="No triggers of yours">When Troupe asks whether to rerun a report a session of yours published, and you turn it on, it is listed here, to switch off or remove.</Empty>
          ) : (
            <div className="scroll">
              <table>
                <thead>
                  <tr>
                    <th>Trigger</th>
                    <th>Team</th>
                    <th>State</th>
                    <th>Last run</th>
                    <th>A run</th>
                    <th>Change</th>
                  </tr>
                </thead>
                <tbody>
                  {triggers.map((t) => (
                    <tr key={t.id}>
                      <td className="mono">{t.name}</td>
                      <td>{t.team}</td>
                      <td>{ownTriggerState(t)}</td>
                      <td>{lastRunWords(t)}</td>
                      <td>{ownBudgetWords(t)}, as you</td>
                      <td>
                        <OwnTriggerControls trigger={t} onChanged={reload} />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )
        }
      </Loaded>
    </section>
  );
}
