// The desktop app keeping itself current (#66, Decision 874).
//
// Two questions, asked on start and once a day after. Signed in, the plane is asked what it
// makes of this version — its `initialize`, with this app's name and version — and which
// version each kind of client should run (`askPlane`). Then the shell is asked for a
// release to move to: the version the plane recommends, or with no plane the latest, held
// to the plane's minimum and blocked list where there is one. The shell checks it against
// the release keys it was built with; this file decides nothing about what may be
// installed, only when to ask and what to say.
//
// Nothing is downloaded until the person asks, and nothing restarts until they say so
// again. Then the app waits for a turn on this computer to end, asks the daemon to stop
// between turns when its release is replaced too (`daemon.stop`), and only then has the
// shell install, which restarts the app. A team session runs on its pod whatever this
// window does, so it is not waited for.

import { useCallback, useEffect, useRef, useState } from "react";
import { askPlane, suggestion, TroupeRpcError } from "@troupe/client";
import type { AuthSession, DaemonClient, FleetRow, PlaneVersionWord } from "@troupe/client";
import { shell } from "./shell";
import type { UpdateOffer, UpdatePlane } from "./shell";

/** How often the questions are asked again, and how often a wait looks again. */
export const updateTiming = { everyMs: 24 * 60 * 60 * 1000, waitMs: 1_000 };

export type UpdatePhase =
  | { kind: "idle" }
  | { kind: "offer"; offer: UpdateOffer }
  | { kind: "downloading"; offer: UpdateOffer; received: number; total: number | null }
  | { kind: "ready"; offer: UpdateOffer }
  | { kind: "waiting"; offer: UpdateOffer; why: string }
  | { kind: "installing"; offer: UpdateOffer }
  | { kind: "refused"; sentence: string };

export interface Updates {
  /** The plane's refusal of this version, as a sentence: the app keeps to this computer. */
  required: string | null;
  /** A newer version the plane recommends, as a quiet offer. */
  suggest: string | null;
  phase: UpdatePhase;
  /** Whether this host can update the app at all: a browser build cannot. */
  canUpdate: boolean;
  /** Download what was found, finding it first where nothing was. */
  update: () => void;
  /** The person said restart: wait for the turns here, stop the daemon, install. */
  restart: () => void;
  /** Put the question away until the next check. */
  later: () => void;
  dismissed: boolean;
}

function message(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

/** A session on this computer with a turn at work, which a restart waits for. */
function atWork(rows: FleetRow[]): FleetRow | undefined {
  return rows.find((r) => r.kind !== "team" && r.status !== null && ["thinking", "acting", "compacting"].includes(r.status));
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * `rows` reads the list as it is now, which a restart waits on: a function, because the
 * list is built after this, from what the plane said here. Null while this computer's
 * sessions are not known yet.
 */
export function useUpdates(auth: AuthSession | null, daemon: DaemonClient | null, rows: () => FleetRow[] | null): Updates {
  const updater = shell()?.updater ?? null;
  const [word, setWord] = useState<PlaneVersionWord | null>(null);
  // Whether the plane signed in to has answered, or could not be asked: the release check
  // waits for it, so that it asks for the version the plane recommends and never offers
  // one the plane would not serve. A sign-in is a new plane to hear from.
  const [heardFor, setHeardFor] = useState<AuthSession | null>(null);
  const heard = !auth || heardFor === auth;
  const [phase, setPhase] = useState<UpdatePhase>({ kind: "idle" });
  const [round, setRound] = useState(0);
  const [dismissed, setDismissed] = useState(false);
  const phaseRef = useRef(phase);
  phaseRef.current = phase;
  const rowsRef = useRef(rows);
  rowsRef.current = rows;
  const daemonRef = useRef(daemon);
  daemonRef.current = daemon;

  // Once a day, both questions again.
  useEffect(() => {
    const timer = setInterval(() => setRound((n) => n + 1), updateTiming.everyMs);
    return () => clearInterval(timer);
  }, []);

  // The plane's word on this version, for as long as somebody is signed in.
  useEffect(() => {
    if (!auth) {
      setWord(null);
      return;
    }
    let live = true;
    askPlane(auth, __TROUPE_VERSION__)
      .then((w) => live && setWord(w))
      .catch(() => live && setWord(null))
      .finally(() => live && setHeardFor(auth));
    return () => {
      live = false;
    };
  }, [auth, round]);

  const params = useCallback((): { version: string | null; plane: UpdatePlane | null } => {
    const versions = word && word.state !== "unknown" ? word.versions : null;
    if (!auth || !versions) return { version: null, plane: null };
    return { version: versions["desktop"]?.recommended ?? null, plane: { url: auth.planeUrl, versions } };
  }, [auth, word]);

  /** Ask the shell for a release; the offer, or null where there is nothing to move to. */
  const check = useCallback(async (): Promise<UpdateOffer | null> => {
    if (!updater) return null;
    try {
      const found = await updater.check(params());
      if (found.state === "offer") {
        const { state: _state, ...offer } = found;
        return offer;
      }
      return null;
    } catch (e) {
      setPhase({ kind: "refused", sentence: message(e) });
      throw e;
    }
  }, [updater, params]);

  // On start, once a day, and when the plane's word changes. Not while an update is under
  // way: a download, the question before a restart, or the wait for a turn.
  useEffect(() => {
    if (!updater || !heard) return;
    if (!["idle", "offer", "refused"].includes(phaseRef.current.kind)) return;
    let live = true;
    check()
      .then((offer) => {
        if (!live) return;
        setPhase(offer ? { kind: "offer", offer } : { kind: "idle" });
        setDismissed(false);
      })
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [updater, heard, check, round]);

  const update = useCallback(() => {
    void (async () => {
      const now = phaseRef.current;
      if (!updater || !["idle", "offer", "refused"].includes(now.kind)) return;
      setDismissed(false);
      const offer = now.kind === "offer" ? now.offer : await check().catch(() => null);
      if (!offer) {
        if (phaseRef.current.kind !== "refused") setPhase({ kind: "idle" });
        return;
      }
      setPhase({ kind: "downloading", offer, received: 0, total: null });
      try {
        await updater.download((received, total) => setPhase({ kind: "downloading", offer, received, total }));
        setPhase({ kind: "ready", offer });
      } catch (e) {
        setPhase({ kind: "refused", sentence: message(e) });
      }
    })();
  }, [updater, check]);

  const restart = useCallback(() => {
    void (async () => {
      const now = phaseRef.current;
      if (!updater || now.kind !== "ready") return;
      const offer = now.offer;
      // Never under a turn on this computer, nor before its sessions are known: on a busy
      // machine the offer is on screen before the daemon has answered.
      for (;;) {
        const rows = rowsRef.current();
        const busy = rows && atWork(rows);
        if (rows && !busy) break;
        const why = busy ? `Restarts when the turn in ${busy.title ?? busy.id} ends.` : "Restarts once this computer's sessions are known.";
        setPhase({ kind: "waiting", offer, why });
        await sleep(updateTiming.waitMs);
      }
      // The daemon's release is replaced only once it has stopped, and it stops only
      // between turns: asked again while it names one (Decision 865).
      let daemonStopped = false;
      const client = daemonRef.current;
      if (offer.daemon && client) {
        for (;;) {
          const answer = await client.stopBetweenTurns().catch((e: unknown) => e);
          if (answer instanceof TroupeRpcError || answer instanceof Error) break; // gone already, or too old to ask
          const said = answer as { stopping: boolean; reason?: string; at_work?: Array<{ id: string; workspace: string | null }> };
          if (said.stopping) {
            daemonStopped = true;
            break;
          }
          if (said.reason !== "at_work") break; // a terminal's own daemon: left running
          const where = said.at_work?.[0];
          setPhase({ kind: "waiting", offer, why: `Restarts when the turn in ${where?.workspace ?? where?.id ?? "a session"} ends.` });
          await sleep(updateTiming.waitMs * 2);
        }
      }
      setPhase({ kind: "installing", offer });
      try {
        await updater.install(daemonStopped);
      } catch (e) {
        setPhase({ kind: "refused", sentence: message(e) });
      }
    })();
  }, [updater]);

  const required = word?.state === "required" ? word.sentence : null;
  const suggest = word?.state === "served" ? suggestion(word.clientUpdate, __TROUPE_VERSION__) : null;

  return {
    required,
    suggest,
    phase,
    canUpdate: Boolean(updater),
    update,
    restart,
    later: useCallback(() => setDismissed(true), []),
    dismissed,
  };
}
