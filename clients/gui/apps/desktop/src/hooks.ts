// React bindings for the client's stores. Each one is a thin adapter: the state lives
// in `@troupe/client`, and these only re-render when it changes. Nothing in here knows
// the protocol — that is the point of the split.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  addPending,
  AdminApi,
  dropPending,
  emptyTranscript,
  fold,
  DaemonClient,
  DaemonSource,
  FleetStore,
  PlaneSource,
  SessionAttachment,
} from "@troupe/client";
import { daemonHint, shell } from "./shell";
import type {
  AttachStatus,
  AuthSession,
  DaemonEndpoint,
  DaemonIdentity,
  FleetSnapshot,
  Principal,
  ProfileOffering,
  SessionKind,
  SessionView,
  TranscriptState,
} from "@troupe/client";

/**
 * The fleet, polled, from however many sources there are.
 *
 * The plane pushes nothing to a harness client by design, so a poll is what liveness is
 * for the team half. The daemon *could* push — it has a `fleet` topic — but the list is
 * a union and a list that was live on one half and four seconds stale on the other would
 * be worse than one that is honestly the same age throughout.
 *
 * A source that fails keeps its last rows. Signing out of the plane does not take the
 * sessions on this computer off the screen, because they were never the plane's.
 */
export function useFleet(
  auth: AuthSession | null,
  daemon: DaemonClient | null,
  intervalMs = 4_000,
): { snapshot: FleetSnapshot; store: FleetStore | null; refresh: () => void } {
  const store = useMemo(() => (auth || daemon ? new FleetStore() : null), [Boolean(auth), Boolean(daemon)]);
  const [snapshot, setSnapshot] = useState<FleetSnapshot>({ rows: [], sources: {}, loading: Boolean(auth || daemon) });

  useEffect(() => {
    if (!store) return;
    if (auth) store.addSource(new PlaneSource(auth.plane, () => auth.token()));
    else store.removeSource("plane");
    if (daemon) store.addSource(new DaemonSource(daemon));
    else store.removeSource("daemon");
    void store.refresh();
  }, [store, auth, daemon]);

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

/** Who sessions on this computer are recorded as, and what to call them. */
export interface MachineUser {
  subject: string;
  name: string;
}

/**
 * The linked account when there is one, and otherwise the operating system's user the
 * daemon admitted at `initialize` — the principal a linked daemon reports carries
 * `linked`, and is not believed once the link is gone.
 */
function machineUser(identity: DaemonIdentity | null, principal: Principal | null): MachineUser | null {
  if (identity?.linked && identity.subject) return { subject: identity.subject, name: identity.display_name ?? identity.subject };
  if (principal && !principal["linked"]) return { subject: principal.subject, name: principal.display_name ?? principal.subject };
  return null;
}

/**
 * The daemon on this computer, if there is one and this host can find it.
 *
 * Three hosts, three answers. A desktop shell reads `daemon.json` and can start the
 * daemon; a browser cannot do either and is given a dialog to type a port and token
 * into; and a browser that has been told nothing has no local sessions, which is a
 * fact about the host rather than a failure and is rendered as one.
 *
 * The token stays in memory. It is a credential, and the rule that the GUI persists
 * exactly one secret — the identity provider's refresh token, in the OS store — has no
 * exception for a local one.
 */
export function useDaemon(): {
  client: DaemonClient | null;
  endpoint: DaemonEndpoint | null;
  status: "unsupported" | "searching" | "absent" | "connected" | "error";
  identity: DaemonIdentity | null;
  user: MachineUser | null;
  error: string | null;
  canFind: boolean;
  connectTo: (endpoint: DaemonEndpoint) => void;
  forget: () => void;
  find: () => void;
  link: (who: { subject: string; display_name?: string; plane_url?: string }) => Promise<void>;
  unlink: () => Promise<void>;
} {
  const canFind = Boolean(shell()?.findDaemon);
  const [endpoint, setEndpoint] = useState<DaemonEndpoint | null>(null);
  const [client, setClient] = useState<DaemonClient | null>(null);
  const [identity, setIdentity] = useState<DaemonIdentity | null>(null);
  const [principal, setPrincipal] = useState<Principal | null>(null);
  const [status, setStatus] = useState<"unsupported" | "searching" | "absent" | "connected" | "error">(
    canFind ? "searching" : "unsupported",
  );
  const [error, setError] = useState<string | null>(null);
  const [round, setRound] = useState(0);

  // A shell can find it; a browser has to be told. Asked once per launch, and again
  // whenever somebody presses the control that bumps `round`.
  useEffect(() => {
    const find = shell()?.findDaemon;
    if (!find) return;
    let live = true;
    setStatus("searching");
    find()
      .then((found) => {
        if (!live) return;
        if (found) setEndpoint(found);
        else setStatus("absent");
      })
      .catch((e: unknown) => {
        if (!live) return;
        setStatus("error");
        setError(e instanceof Error ? e.message : String(e));
      });
    return () => {
      live = false;
    };
  }, [round]);

  // A browser build in development can be told by the environment instead of by hand.
  // Once, at start: `forget` must stay forgotten.
  useEffect(() => {
    if (shell()?.findDaemon) return;
    const hint = daemonHint();
    if (hint) setEndpoint(hint);
  }, []);

  useEffect(() => {
    if (!endpoint) return;
    const next = new DaemonClient(endpoint, {
      onClose: () => setStatus("error"),
    });
    let live = true;
    next
      .identity()
      .then((who) => {
        if (!live) return;
        setIdentity(who);
        setPrincipal(next.principal);
        setClient(next);
        setStatus("connected");
        setError(null);
      })
      .catch((e: unknown) => {
        if (!live) return;
        setStatus("error");
        setError(e instanceof Error ? e.message : String(e));
      });

    return () => {
      live = false;
      next.disconnect();
      setClient(null);
    };
  }, [endpoint]);

  return {
    client,
    endpoint,
    status,
    identity,
    user: machineUser(identity, principal),
    error,
    canFind,
    connectTo: useCallback((e: DaemonEndpoint) => {
      setError(null);
      setEndpoint(e);
    }, []),
    forget: useCallback(() => {
      setEndpoint(null);
      setIdentity(null);
      setPrincipal(null);
      setStatus(shell()?.findDaemon ? "absent" : "unsupported");
    }, []),
    find: useCallback(() => setRound((n) => n + 1), []),
    link: useCallback(
      async (who) => {
        if (!client) return;
        setIdentity(await client.linkIdentity(who));
      },
      [client],
    ),
    unlink: useCallback(async () => {
      if (!client) return;
      setIdentity(await client.unlinkIdentity());
    }, [client]),
  };
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
  /**
   * The view, wherever this session runs.
   *
   * A team session's view is swapped onto a new socket by a `SessionAttachment` when a
   * pod token expires; a local session's is bound to the daemon's one connection for as
   * long as it is open. Every screen above this uses the view and neither of those two.
   */
  view: SessionView | null;
  send(text: string): Promise<void>;
  respond(callId: string, decision: "allow" | "deny" | "allow_session"): Promise<void>;
  /** Answer a question — the agent's, or the harness's about the budget. */
  answer(callId: string, text: string): Promise<void>;
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
export function useSessionView(
  auth: AuthSession | null,
  sessionId: string | null,
  opts: { daemon?: DaemonClient | null; kind?: SessionKind; mode?: "read" | "activate" } = {},
): SessionHandle {
  const { daemon = null, kind = "team", mode = "activate" } = opts;
  const [state, setState] = useState<TranscriptState>(emptyTranscript);
  const [status, setStatus] = useState<AttachStatus>("connecting");
  const [detail, setDetail] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const ref = useRef<SessionView | null>(null);
  // Held separately because closing is different: an attachment owns a socket and must
  // be told to let it go; a daemon's view is one of several on a socket that stays.
  const attachment = useRef<SessionAttachment | null>(null);
  const [view, setView] = useState<SessionView | null>(null);
  const local = kind !== "team";

  useEffect(() => {
    if (!sessionId) return;
    if (local ? !daemon : !auth) return;
    let live = true;
    // Whether this mount's `open` resolved while it was still mounted, so the cleanup
    // knows whether it owes the daemon a `close` — the one it would otherwise pay twice
    // when the open resolves after the unmount and that path closes too.
    let held = false;
    let stopListening: (() => void) | null = null;
    setState(emptyTranscript);
    setError(null);
    setStatus("connecting");

    // Two ways in, one view out. A session on this computer is reached over the socket
    // the daemon already has — there is no token to expire and nothing to reconnect
    // around — and a session on a worker is reached through an attachment that swaps
    // the socket underneath the view when the plane mints a new token.
    //
    // The local view is *listened to* rather than given this mount's hook: a view may
    // already be open for somebody else — another pane, or this same component mounted
    // twice by React in development — and a hook installed by the first opener would
    // keep folding into a state nobody renders.
    const opened = local
      ? daemon!
          .open(sessionId)
          .then((v) => {
            if (!live) return void daemon!.close(sessionId);
            held = true;
            stopListening = v.listen((e) => live && setState((s) => fold(s, e)));
            ref.current = v;
            setView(v);
            setStatus("live");
            void v.setPresence("viewing").catch(() => undefined);
            return undefined;
          })
      : SessionAttachment.open({
          sessionId,
          mode,
          open: (m) => auth!.rpc("session.open", { session_id: sessionId, mode: m }),
          mint: () => auth!.rpc("token.mint", { session_id: sessionId }),
          hooks: { onEvent: (e) => live && setState((s) => fold(s, e)) },
          onStatus: (s, d) => {
            if (!live) return;
            setStatus(s);
            setDetail(d ?? null);
          },
        }).then((a) => {
          if (!live) return void a.close();
          attachment.current = a;
          ref.current = a.view;
          setView(a.view);
          void a.view.setPresence("viewing").catch(() => undefined);
          return undefined;
        });

    void opened.catch((e: unknown) => live && setError(e instanceof Error ? e.message : String(e)));

    return () => {
      live = false;
      stopListening?.();
      const a = attachment.current;
      attachment.current = null;
      ref.current = null;
      setView(null);
      if (a) void a.close();
      else if (local && daemon && held) void daemon.close(sessionId);
    };
  }, [auth, daemon, sessionId, mode, local]);

  // A team session's command that its pod refuses because the session has moved goes
  // after it through the plane and runs once more (PROTOCOL.md §6, "A session that
  // moves"). A session on this computer has nowhere else to be.
  const following = useCallback(<T,>(command: () => Promise<T>): Promise<T> => {
    const a = attachment.current;
    return a ? a.retrying(command) : command();
  }, []);

  const send = useCallback(async (text: string) => {
    const v = ref.current;
    if (!v) throw new Error("not attached");
    const commandId = v.conn.nextCommandId();
    setState((s) => addPending(s, commandId, text));
    try {
      await following(() => v.send(text, commandId));
    } catch (e) {
      setState((s) => dropPending(s, commandId));
      throw e;
    }
  }, [following]);

  const respond = useCallback(async (callId: string, decision: "allow" | "deny" | "allow_session") => {
    const v = ref.current;
    if (v) await following(() => v.respondApproval(callId, decision));
  }, [following]);

  const answer = useCallback(async (callId: string, text: string) => {
    const v = ref.current;
    if (v) await following(() => v.answerQuestion(callId, text));
  }, [following]);

  const cancel = useCallback(async () => {
    const v = ref.current;
    if (v) await following(() => v.cancel());
  }, [following]);

  const switchProfile = useCallback(async (profile: string) => {
    const v = ref.current;
    if (v) await following(() => v.switchProfile(profile));
  }, [following]);

  const readBlob = useCallback(async (blob: string) => {
    const v = ref.current;
    if (!v) throw new Error("not attached");
    return v.blobText(blob);
  }, []);

  return { state, status, detail, view, send, respond, answer, cancel, switchProfile, readBlob, error };
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
/**
 * The plane's administrative client, for the one screen that still needs it.
 *
 * Administration is the console's, at `/admin`. This app used to carry a panel of its
 * own over the same methods, and it is gone: two renderings of one surface is two
 * things to keep in step, and the console is the one with the coverage test behind it.
 *
 * What remains is Review, which reads `admin.runs.list` to find the runs nobody has
 * looked at. There is no probe any more either — the panel needed to know whether to
 * offer itself, and Review is offered to everybody and reports a refusal like any
 * other read.
 */
export function useAdmin(auth: AuthSession | null): AdminApi | null {
  return useMemo(() => (auth ? new AdminApi((m, p) => auth.rpc(m, p)) : null), [auth]);
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
