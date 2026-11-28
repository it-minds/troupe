// A person's own triggers (troupe #1235): the ones a yes of theirs to a proposal made, which
// run as them and spend their budget. Listed on Your triggers, under On the platform in
// the rail, where the plane's other things of theirs are; each with whether it is on and
// when it runs next, how its last run went and what a run may spend, and Switch off or
// Switch on and Remove, asked once more inline since a removal cannot be undone. The same
// controls stand on the proposal's record line in the session whose yes made it.

import { useCallback, useEffect, useState } from "react";
import type { JSX } from "react";
import { OWN_TRIGGER_ACTIONS, countWords, errorText, lastRunWords, ownBudgetWords, ownTriggerRefusal, ownTriggerState, removeConfirm } from "@troupe/client";
import type { AuthSession, OwnTrigger, OwnTriggerAction } from "@troupe/client";
import { Loading } from "./bits";

/** Asking the plane, as the person, about their own triggers. */
export interface OwnTriggerSource {
  list: () => Promise<OwnTrigger[]>;
  change: (t: OwnTrigger, action: OwnTriggerAction) => Promise<void>;
}

/** The person's own triggers through their sign-in. */
export function ownTriggerSource(auth: AuthSession): OwnTriggerSource {
  return {
    list: async () => (await auth.plane.listOwnTriggers(await auth.token())).triggers,
    change: async (t, action) => {
      const token = await auth.token();
      if (action === "remove") await auth.plane.removeOwnTrigger(token, t.id);
      else await auth.plane.switchOwnTrigger(token, t.id, action === "on");
    },
  };
}

/** The person's own triggers as last listed, `null` before the first answer, and a refresh. */
export function useOwnTriggers(source: OwnTriggerSource | undefined): { triggers: OwnTrigger[] | null; error: string | null; reload: () => Promise<void> } {
  const [triggers, setTriggers] = useState<OwnTrigger[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const reload = useCallback(async () => {
    if (!source) return;
    try {
      setTriggers(await source.list());
      setError(null);
    } catch (e) {
      setError(errorText(e));
    }
  }, [source]);
  useEffect(() => {
    void reload();
  }, [reload]);
  return { triggers, error, reload };
}

/** Switch off or on, and Remove asked once more; a refusal under them until the next try. */
export function OwnTriggerControls({ trigger, source, onChanged }: { trigger: OwnTrigger; source: OwnTriggerSource; onChanged: () => Promise<void> }): JSX.Element {
  const [busy, setBusy] = useState<OwnTriggerAction | null>(null);
  const [confirming, setConfirming] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const act = async (action: OwnTriggerAction): Promise<void> => {
    if (busy) return;
    setBusy(action);
    setError(null);
    try {
      await source.change(trigger, action);
      setConfirming(false);
      await onChanged();
    } catch (e) {
      setError(ownTriggerRefusal(e, action));
    } finally {
      setBusy(null);
    }
  };
  const flip: OwnTriggerAction = trigger.enabled ? "off" : "on";
  return (
    <>
      {confirming ? (
        <p className="micro" role="group" aria-label={`Remove ${trigger.name}?`}>
          {removeConfirm(trigger)}{" "}
          <button type="button" className="danger" disabled={busy !== null} onClick={() => void act("remove")}>
            {busy === "remove" ? OWN_TRIGGER_ACTIONS.remove.busy : OWN_TRIGGER_ACTIONS.remove.label}
          </button>{" "}
          <button type="button" className="link" disabled={busy !== null} onClick={() => setConfirming(false)}>
            Keep it
          </button>
        </p>
      ) : (
        <p className="micro own-trigger-actions">
          <button type="button" disabled={busy !== null} onClick={() => void act(flip)}>
            {busy === flip ? OWN_TRIGGER_ACTIONS[flip].busy : OWN_TRIGGER_ACTIONS[flip].label}
          </button>{" "}
          <button type="button" className="link" disabled={busy !== null} onClick={() => setConfirming(true)}>
            {OWN_TRIGGER_ACTIONS.remove.label}
          </button>
        </p>
      )}
      {error && (
        <p className="also error" role="alert">
          {error}
        </p>
      )}
    </>
  );
}

/** Your triggers: every one of the person's own, across their teams. */
export function OwnTriggers({ source, known, onOpen }: { source: OwnTriggerSource; known: boolean; onOpen: (sessionId: string) => void }): JSX.Element {
  const { triggers, error, reload } = useOwnTriggers(known ? source : undefined);
  return (
    <>
      <header className="screen-head">
        <span className="count">{known && triggers ? countWords(triggers.length, "trigger") : "Yours"}</span>
        <h1>Your triggers</h1>
      </header>
      <div className="listing own-triggers">
        {!known ? (
          <div className="empty">
            <h2>This plane does not let you change your own triggers yet</h2>
            <p>A rerun you turned on from a session runs until a team admin switches it off, on the console's Triggers page.</p>
          </div>
        ) : error && !triggers ? (
          <div className="banner error" role="alert">
            <p>Your triggers could not be listed: {error}.</p>
            <button type="button" onClick={() => void reload()}>
              Try again
            </button>
          </div>
        ) : !triggers ? (
          <Loading what="your triggers" />
        ) : triggers.length === 0 ? (
          <div className="empty">
            <h2>No triggers of yours</h2>
            <p>When Troupe asks whether to rerun a report a session of yours published, and you turn it on, it is listed here, to switch off or remove.</p>
          </div>
        ) : (
          <ul className="own-trigger-list">
            {triggers.map((t) => (
              <li key={t.id} className="own-trigger">
                <h2>
                  {t.name} <span className="muted micro">in {t.team}</span>
                </h2>
                <p className="note">{ownTriggerState(t)}.</p>
                <p className="note">
                  {lastRunWords(t)}. It runs as you, {ownBudgetWords(t)}.
                  {t.last_run?.session_id && (
                    <>
                      {" "}
                      <button type="button" className="link" onClick={() => onOpen(t.last_run!.session_id!)}>
                        Open the last run
                      </button>
                    </>
                  )}
                </p>
                <OwnTriggerControls trigger={t} source={source} onChanged={reload} />
              </li>
            ))}
          </ul>
        )}
      </div>
    </>
  );
}
