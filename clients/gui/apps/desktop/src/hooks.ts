// React bindings for the client's stores. Each one is a thin adapter: the state lives
// in `@troupe/client`, and these only re-render when it changes. Nothing in here knows
// the protocol — that is the point of the split.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  addPending,
  AdminApi,
  ErrorCodes,
  dropPending,
  emptyTranscript,
  fold,
  FleetStore,
  PlaneSource,
  SessionAttachment,
  TroupeRpcError,
} from "@troupe/client";
import type {
  AttachStatus,
  AuthSession,
  FleetOverview,
  FleetSnapshot,
  ProfileOffering,
  TranscriptState,
} from "@troupe/client";

/** The fleet, polled. The plane pushes nothing, so a poll is what liveness is here. */
export function useFleet(auth: AuthSession | null, intervalMs = 4_000): { snapshot: FleetSnapshot; store: FleetStore | null; refresh: () => void } {
  const store = useMemo(() => (auth ? new FleetStore([new PlaneSource(auth.plane, () => auth.token())]) : null), [auth]);
  const [snapshot, setSnapshot] = useState<FleetSnapshot>({ rows: [], sources: {}, loading: Boolean(auth) });

  useEffect(() => {
    if (!store) return;
    const off = store.subscribe(setSnapshot);
    const stop = store.poll(intervalMs);
    return () => {
      stop();
      off();
    };
  }, [store, intervalMs]);

  return { snapshot, store, refresh: useCallback(() => void store?.refresh(), [store]) };
}

export function useProfiles(auth: AuthSession | null): { profiles: ProfileOffering[]; error: string | null } {
  const [profiles, setProfiles] = useState<ProfileOffering[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!auth) return;
    let live = true;
    auth
      .rpc<{ profiles: ProfileOffering[] }>("profiles.list", {})
      .then((r) => live && setProfiles(r.profiles))
      .catch((e: unknown) => live && setError(e instanceof Error ? e.message : String(e)));
    return () => {
      live = false;
    };
  }, [auth]);

  return { profiles, error };
}

export interface SessionHandle {
  state: TranscriptState;
  status: AttachStatus;
  detail: string | null;
  attachment: SessionAttachment | null;
  send(text: string): Promise<void>;
  respond(callId: string, decision: "allow" | "deny" | "allow_session"): Promise<void>;
  cancel(): Promise<void>;
  switchProfile(profile: string): Promise<void>;
  /** Fetch a blob's text. Called on expand and never on load. */
  readBlob(blob: string): Promise<string>;
  error: string | null;
}

/**
 * One open session.
 *
 * The transcript is rebuilt by folding events as they arrive, so a reconnection that
 * replays from the cursor simply continues the same fold. An input is rendered
 * optimistically the instant it is typed and reconciled when the server's
 * `input_accepted` names the command id it was sent with.
 */
export function useSessionView(auth: AuthSession | null, sessionId: string | null, mode: "read" | "activate" = "activate"): SessionHandle {
  const [state, setState] = useState<TranscriptState>(emptyTranscript);
  const [status, setStatus] = useState<AttachStatus>("connecting");
  const [detail, setDetail] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const ref = useRef<SessionAttachment | null>(null);
  const [attachment, setAttachment] = useState<SessionAttachment | null>(null);

  useEffect(() => {
    if (!auth || !sessionId) return;
    let live = true;
    setState(emptyTranscript);
    setError(null);
    setStatus("connecting");

    SessionAttachment.open({
      sessionId,
      mode,
      open: (m) => auth.rpc("session.open", { session_id: sessionId, mode: m }),
      mint: () => auth.rpc("token.mint", { session_id: sessionId }),
      hooks: { onEvent: (e) => live && setState((s) => fold(s, e)) },
      onStatus: (s, d) => {
        if (!live) return;
        setStatus(s);
        setDetail(d ?? null);
      },
    })
      .then((a) => {
        if (!live) return void a.close();
        ref.current = a;
        setAttachment(a);
        void a.view.setPresence("viewing").catch(() => undefined);
      })
      .catch((e: unknown) => live && setError(e instanceof Error ? e.message : String(e)));

    return () => {
      live = false;
      const a = ref.current;
      ref.current = null;
      setAttachment(null);
      void a?.close();
    };
  }, [auth, sessionId, mode]);

  const send = useCallback(async (text: string) => {
    const a = ref.current;
    if (!a) throw new Error("not attached");
    const commandId = a.view.conn.nextCommandId();
    setState((s) => addPending(s, commandId, text));
    try {
      await a.view.send(text, commandId);
    } catch (e) {
      setState((s) => dropPending(s, commandId));
      throw e;
    }
  }, []);

  const respond = useCallback(async (callId: string, decision: "allow" | "deny" | "allow_session") => {
    await ref.current?.view.respondApproval(callId, decision);
  }, []);

  const cancel = useCallback(async () => {
    await ref.current?.view.cancel();
  }, []);

  const switchProfile = useCallback(async (profile: string) => {
    await ref.current?.view.switchProfile(profile);
  }, []);

  const readBlob = useCallback(async (blob: string) => {
    const a = ref.current;
    if (!a) throw new Error("not attached");
    return a.view.blobText(blob);
  }, []);

  return { state, status, detail, attachment, send, respond, cancel, switchProfile, readBlob, error };
}

/**
 * Whether this person administers anything, and the API if they do.
 *
 * Asked rather than inferred. `platform_admin` on `me` is one of the two roles; the
 * other, `team_admin`, is assigned per team and appears in no claim a client can read.
 * So the probe is `admin.overview` itself: it is the cheapest administrative read, it
 * is scoped to whatever the caller administers, and a person who administers nothing is
 * refused — which is exactly the question the navigation is asking.
 */
export function useAdmin(auth: AuthSession | null): {
  api: AdminApi | null;
  available: boolean;
  platform: boolean;
  overview: FleetOverview | null;
  checking: boolean;
  error: string | null;
  refresh: () => void;
} {
  const api = useMemo(() => (auth ? new AdminApi((m, p) => auth.rpc(m, p)) : null), [auth]);
  const [available, setAvailable] = useState(false);
  const [platform, setPlatform] = useState(false);
  const [overview, setOverview] = useState<FleetOverview | null>(null);
  const [checking, setChecking] = useState(Boolean(auth));
  const [error, setError] = useState<string | null>(null);
  const [round, setRound] = useState(0);

  useEffect(() => {
    if (!api || !auth) return;
    let live = true;
    setChecking(true);
    void (async () => {
      try {
        const [me, over] = await Promise.all([
          auth.rpc<{ platform_admin?: boolean }>("me", {}).catch(() => ({}) as { platform_admin?: boolean }),
          api.overview(),
        ]);
        if (!live) return;
        setPlatform(Boolean(me.platform_admin));
        setOverview(over);
        setAvailable(true);
        setError(null);
      } catch (e) {
        if (!live) return;
        // Refused is an answer, not a failure: it means this person administers
        // nothing, and the navigation should not offer what every call would refuse.
        setAvailable(false);
        setError(e instanceof TroupeRpcError && e.code === ErrorCodes.forbidden ? null : e instanceof Error ? e.message : String(e));
      } finally {
        if (live) setChecking(false);
      }
    })();
    return () => {
      live = false;
    };
  }, [api, auth, round]);

  return { api, available, platform, overview, checking, error, refresh: useCallback(() => setRound((n) => n + 1), []) };
}

/**
 * One administrative read, kept simple on purpose.
 *
 * Every admin screen is the same shape — call one method, render rows, offer actions
 * that call one more — so the loading, the error and the reload live here once. `deps`
 * is what the call depends on; passing `null` means "not yet, do not call".
 */
export function useAdminQuery<T>(run: (() => Promise<T>) | null, deps: unknown[]): {
  data: T | null;
  loading: boolean;
  error: string | null;
  reload: () => void;
} {
  const [data, setData] = useState<T | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [round, setRound] = useState(0);

  useEffect(() => {
    if (!run) return;
    let live = true;
    setLoading(true);
    run()
      .then((d) => {
        if (!live) return;
        setData(d);
        setError(null);
      })
      .catch((e: unknown) => live && setError(e instanceof Error ? e.message : String(e)))
      .finally(() => live && setLoading(false));
    return () => {
      live = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, round]);

  return { data, loading, error, reload: useCallback(() => setRound((n) => n + 1), []) };
}
