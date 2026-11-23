// React bindings for the client's stores. Each one is a thin adapter: the state lives
// in `@troupe/client`, and these only re-render when it changes. Nothing in here knows
// the protocol — that is the point of the split.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  addPending,
  AdminApi,
  daemonUrl,
  dropPending,
  emptyTranscript,
  errorText,
  fold,
  DaemonClient,
  DaemonSource,
  FleetStore,
  isDurable,
  onThisComputer,
  PlaneSource,
  planeOpener,
  raiseKept,
  RemoteSource,
  ServerOffer,
  SessionAttachment,
  StartQuestions,
  TroupeRpcError,
} from "@troupe/client";
import { storedLocalOnly } from "./mode";
import { noticeEvent } from "./notify";
import { adoptFragment, daemonHint, forgetDaemon, rememberDaemon, shell } from "./shell";
import type {
  ApprovalDecision,
  AttachStatus,
  AuthSession,
  DaemonEndpoint,
  DaemonIdentity,
  FleetRow,
  FleetSnapshot,
  GateAnswer,
  OfferAnswer,
  OfferState,
  OnboardingSuggested,
  Principal,
  ProfileOffering,
  ProfileSwitch,
  SessionKind,
  SessionView,
  StartAnswer,
  StartState,
  TranscriptState,
  TroupeEvent,
} from "@troupe/client";

/**
 * The fleet, from however many sources there are.
 *
 * The team half is polled: the plane's `/rpc` is request and answer, and the pods' news
 * reaches an open session over its own socket. The laptops' sessions offered for steering
 * are not: the plane tells a person's watch (`/v1/relay/watch`) of an offer made or
 * withdrawn and of a laptop come or gone, so they reach the list as they happen, and are
 * asked on the poll only while the watch is down and as a five-minute safety net. The
 * daemon *could* push too — it has a `fleet` topic — and is polled with the team half.
 *
 * A source that fails keeps its last rows. Signing out of the plane does not take the
 * sessions on this computer off the screen, because they were never the plane's.
 */
export function useFleet(
  auth: AuthSession | null,
  daemon: DaemonClient | null,
  intervalMs = 4_000,
): { snapshot: FleetSnapshot; store: FleetStore; refresh: () => void } {
  // One store for as long as the app runs. A source that comes later — this computer's
  // daemon a moment after the plane, the plane after a sign-in — is added to it and asked
  // alone, not given a new store that asks every source again: a second ask of the plane's
  // relay list, out while its watch is pushing, is answered with a list older than the push.
  const store = useMemo(() => new FleetStore(), []);
  const [snapshot, setSnapshot] = useState<FleetSnapshot>({ rows: [], sources: {}, loading: Boolean(auth || daemon) });
  // The sources, one set per sign-in and one per daemon, so that a render changes nothing.
  const planeSources = useMemo(
    () =>
      auth
        ? [
            new PlaneSource(auth.plane, () => auth.token()),
            // Laptop sessions offered for steering from another device: the person's own
            // from their other computers, and those shared with them.
            new RemoteSource(auth.plane, () => auth.token(), { name: "troupe-gui", version: __TROUPE_VERSION__ }),
          ]
        : null,
    [auth],
  );
  const daemonSource = useMemo(() => (daemon ? new DaemonSource(daemon) : null), [daemon]);

  useEffect(() => {
    if (planeSources) for (const s of planeSources) store.addSource(s);
    else for (const id of ["plane", "remote"]) store.removeSource(id);
    if (daemonSource) store.addSource(daemonSource);
    else store.removeSource("daemon");
    void store.refreshUnheard();
  }, [store, planeSources, daemonSource]);

  useEffect(() => {
    const off = store.subscribe(setSnapshot);
    const stop = store.poll(intervalMs);
    return () => {
      stop();
      off();
    };
  }, [store, intervalMs]);

  return { snapshot, store, refresh: useCallback(() => void store.refresh(), [store]) };
}

/** The archived sessions, as `useArchived` holds them. */
export interface Archived {
  rows: FleetRow[];
  loading: boolean;
  /** What went wrong asking a source, where one did; the others' rows are still here. */
  error: string | null;
  /** Ask every source for its archived sessions again. */
  load: () => Promise<void>;
  /**
   * Archive a session (`on`) or unarchive it, where it runs: a session on this computer
   * through its daemon, a team one through the plane. An archived one leaves the list at
   * once; either way the list and the archived ones are asked again after.
   */
  set: (row: FleetRow, on: boolean) => Promise<void>;
}

/**
 * The sessions their owners archived: asked when somebody looks, and again after one is
 * archived or unarchived here, never on the poll, since nothing in them waits on anybody.
 */
export function useArchived(store: FleetStore, auth: AuthSession | null, daemon: DaemonClient | null): Archived {
  const [rows, setRows] = useState<FleetRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(async () => {
    setLoading(true);
    try {
      const got = await store.archived();
      setRows(got.rows);
      setError(Object.values(got.sources).find((s) => s.error)?.error ?? null);
    } finally {
      setLoading(false);
    }
  }, [store]);
  const set = useCallback(
    async (row: FleetRow, on: boolean) => {
      if (onThisComputer(row.kind)) {
        if (!daemon) throw new Error("This computer's daemon is not running");
        await (on ? daemon.archiveSession(row.id) : daemon.unarchiveSession(row.id));
      } else if (row.kind === "team" && auth) {
        const token = await auth.token();
        await (on ? auth.plane.archiveSession(token, row.id) : auth.plane.unarchiveSession(token, row.id));
      } else {
        throw new Error("Only a session on the platform or on this computer can be archived");
      }
      if (on) {
        // Among the archived ones before it leaves the list, so that a screen open on it
        // still finds its row.
        setRows((rs) => [{ ...row, archived: true }, ...rs.filter((r) => r.id !== row.id)]);
        store.drop(row.id);
      }
      // The list first, so that a session unarchived here is in it before it leaves the
      // archived ones: an open session is found in one or the other throughout.
      await store.refreshAfterChange();
      await load();
    },
    [store, auth, daemon, load],
  );
  return { rows, loading, error, load, set };
}

/** A session's name and its place at the top of the list, as `useMarks` changes them. */
export interface Marks {
  /** Name it, where it runs; an empty name takes the name off. Rejects with the server's refusal. */
  rename: (row: FleetRow, title: string) => Promise<void>;
  /** Keep it at the top of the list (`on`) or let it go, where it runs (`session.pin`). */
  keep: (row: FleetRow, on: boolean) => Promise<void>;
  /** Give a pod session to its team (`team`) or take it back (`private`), at the plane (troupe #1169). Rejects with the refusal. */
  share: (row: FleetRow, visibility: "team" | "private") => Promise<void>;
  /**
   * Raise a pod session to its channel's current bundle version, at the plane (troupe
   * #1177). Rejects with the refusal: `conflict` with `raise_to` while its agent works, the
   * raise kept for when it is done, which the row says from then on.
   */
  raise: (row: FleetRow) => Promise<void>;
}

/**
 * Renaming a session and keeping it at the top: a session on this computer through its
 * daemon, a team one through the plane. Neither pushes the change, so the answer is put on
 * the row at once, and the head and the list show it before the list is asked again.
 */
export function useMarks(store: FleetStore, auth: AuthSession | null, daemon: DaemonClient | null): Marks {
  const where = useCallback(
    async <T,>(row: FleetRow, local: (d: DaemonClient) => Promise<T>, plane: (a: AuthSession, token: string) => Promise<T>): Promise<T> => {
      if (onThisComputer(row.kind)) {
        if (!daemon) throw new Error("This computer's daemon is not running");
        return local(daemon);
      }
      if (row.kind === "team" && auth) return plane(auth, await auth.token());
      throw new Error("Only a session on the platform or on this computer has a name and a place in the list to change");
    },
    [auth, daemon],
  );
  const rename = useCallback(
    async (row: FleetRow, title: string) => {
      const named = await where(
        row,
        async (d) => (await d.setSessionTitle(row.id, title)).title,
        async (a, token) => (await a.plane.setSessionTitle(token, row.id, title)).title ?? null,
      );
      // A session on this computer with no name is listed by where it works.
      const workspace = (row.raw as { workspace?: string } | null)?.workspace ?? null;
      store.patch(row.id, { title: named ?? (onThisComputer(row.kind) ? workspace : null) });
      await store.refreshAfterChange();
    },
    [store, where],
  );
  const keep = useCallback(
    async (row: FleetRow, on: boolean) => {
      await where<unknown>(
        row,
        (d) => d.pinSession(row.id, on),
        (a, token) => a.plane.pinSession(token, row.id, on),
      );
      store.patch(row.id, { pinned: on });
      await store.refreshAfterChange();
    },
    [store, where],
  );
  // Whose a pod session is: the plane's alone, since a session on this computer is never a
  // team's. The answer's row goes on the list's row at once, as a name does.
  const share = useCallback(
    async (row: FleetRow, visibility: "team" | "private") => {
      if (row.kind !== "team" || !auth) throw new Error("Only a session on the platform is given to a team");
      const answered = await auth.plane.setSessionVisibility(await auth.token(), row.id, visibility);
      const raw = (row.raw && typeof row.raw === "object" ? row.raw : {}) as Record<string, unknown>;
      const now = answered.visibility ?? visibility;
      store.patch(row.id, { visibility: now, raw: { ...raw, visibility: now, team: answered.team ?? raw["team"] ?? null } });
      await store.refreshAfterChange();
    },
    [store, auth],
  );
  // Which configuration a pod session runs on: the plane's alone. The answer's versions go
  // on the list's row at once, as a name does; a raise kept for the agent's rest says so too.
  const raise = useCallback(
    async (row: FleetRow) => {
      if (row.kind !== "team" || !auth) throw new Error("Only a session on the platform has a configuration to update");
      const raw = (row.raw && typeof row.raw === "object" ? row.raw : {}) as Record<string, unknown>;
      try {
        const answered = await auth.plane.raiseSessionBundle(await auth.token(), row.id);
        store.patch(row.id, {
          raw: { ...raw, bundle_version: answered.bundle_version, bundle_current: answered.bundle_current, bundle_raise_to: answered.bundle_raise_to ?? null },
        });
      } catch (e) {
        const kept = raiseKept(e);
        if (kept !== null) store.patch(row.id, { raw: { ...raw, bundle_raise_to: kept } });
        throw e;
      }
      await store.refreshAfterChange();
    },
    [store, auth],
  );
  return useMemo(() => ({ rename, keep, share, raise }), [rename, keep, share, raise]);
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

/** The same plane, whatever trailing slashes either was written with. */
function samePlane(a: string | null | undefined, b: string): boolean {
  return Boolean(a) && a!.replace(/\/+$/, "") === b.replace(/\/+$/, "");
}

/**
 * Hand the daemon this app's plane token, linking it to the person signed in here at this
 * plane (issue #365). The daemon signs nobody in: it registers and seals a private session
 * with the token it was last handed, holds it in memory only, and cannot renew it. A
 * daemon nobody has linked is linked as this person, as `troupe login` links it: signing
 * in is the person asking, and a daemon left unlinked is one whose private sessions and
 * artifacts this app cannot reach. One linked to somebody else, or to this
 * person at another plane, is left as it is; This computer is where that is changed.
 */
async function handOver(client: DaemonClient, auth: AuthSession | null, who: DaemonIdentity | null): Promise<DaemonIdentity | null> {
  if (!auth?.me) return null;
  if (who?.linked && (who.subject !== auth.me.subject || !samePlane(who.plane_url, auth.planeUrl))) return null;
  const token = await auth.token();
  const name = who?.linked ? who.display_name : auth.me.display_name;
  return client.linkIdentity({
    subject: auth.me.subject,
    ...(name ? { display_name: name } : {}),
    plane_url: auth.planeUrl,
    plane_token: token,
  });
}

/**
 * How often the app tries again for a daemon it has not reached: every `firstMs` for the
 * first `firstForMs`, then every `thenMs`. Exported so a test can shorten it.
 */
export const redialTiming = { firstMs: 5_000, firstForMs: 60_000, thenMs: 30_000 };

/**
 * Why a browser build could not reach the daemon it was told about, in words a person can
 * act on. A browser shows a page no 403, so a daemon that is not running, one that started
 * again somewhere else, and one that refuses this page's origin all look the same: a socket
 * that did not open. So all three are said, with the origin the daemon has to admit, and
 * the one command that mends each (troupe #449, Decision 797).
 */
function unreachable(endpoint: DaemonEndpoint, e: unknown): string {
  if (e instanceof TroupeRpcError && e.method !== "initialize") return e.message;
  const at = (globalThis as { location?: Location }).location;
  const origin = at?.origin ?? "this page";
  const page = at ? `${at.origin}${at.pathname}` : "URL";
  return (
    `The daemon at ${daemonUrl(endpoint)} did not let this page in. Either it is not running, it started again since ` +
    `this page was told where it was, or it does not admit pages from ${origin}; a browser does not say which. ` +
    `Run troupe-daemon open on this computer: it starts the daemon if need be and opens this app connected to it, ` +
    `admitting the plane the daemon is linked to. For this address in particular: troupe-daemon open --url ${page}`
  );
}

/**
 * The daemon on this computer, if there is one and this host can find it.
 *
 * Three hosts, three answers. A desktop shell reads `daemon.json` and can start the
 * daemon; a browser cannot do either and is told, by `troupe-daemon open` or by hand;
 * and a browser that has been told nothing has no local sessions, which is a fact about
 * the host rather than a failure and is rendered as one.
 *
 * A browser keeps what it was told in `localStorage`, so a reload or a new tab connects
 * again: the one exception to the rule that the GUI persists exactly one secret (the
 * identity provider's refresh token, in the OS store), because the daemon's token changes
 * at every start and a stale one only fails (Decision 797). A shell keeps nothing; it reads
 * `daemon.json` again.
 *
 * Signed in to a plane (`auth`), it hands a daemon linked to the person their plane token
 * when it links, when it reaches the daemon, again when the token is renewed, and again
 * when the daemon has restarted and so holds none (issue #365).
 */
export function useDaemon(auth: AuthSession | null = null): {
  client: DaemonClient | null;
  endpoint: DaemonEndpoint | null;
  status: "unsupported" | "searching" | "absent" | "connected" | "error";
  /** How many times the socket has opened again since the daemon first answered. */
  opened: number;
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
  // Bumped to dial the same endpoint again, after a first dial that failed.
  const [dial, setDial] = useState(0);
  // A dial on its way, which a try again leaves to finish.
  const dialling = useRef(false);
  // The person forgot the daemon: nothing dials it again until they connect or find one.
  const [forgotten, setForgotten] = useState(false);
  // How many times the socket has opened again since the first answer: a screen holding
  // something the daemon keeps asks again at each.
  const [opened, setOpened] = useState(0);
  // Where the client reached it last, which is not `endpoint` once the daemon restarted
  // somewhere else and the client followed it there.
  const [reached, setReached] = useState<DaemonEndpoint | null>(null);
  // The sign-in as it is now, for a socket that opens again long after this rendered.
  const signedIn = useRef(auth);
  signedIn.current = auth;

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
        setError(errorText(e));
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

  // An address `troupe-daemon open` handed out, put into a tab already open: taken as at
  // a load.
  useEffect(() => {
    if (shell()?.findDaemon) return;
    const onHash = (): void => {
      const told = adoptFragment();
      if (told) setEndpoint(told);
    };
    globalThis.addEventListener?.("hashchange", onHash);
    return () => globalThis.removeEventListener?.("hashchange", onHash);
  }, []);

  // The socket drops when the daemon goes, and the client dials again at the next call —
  // the list's poll makes one every few seconds — reading where the daemon is first, where
  // a shell can: a daemon that restarted is at a new port with a new token. A dial that
  // works is connected again, whoever made it.
  useEffect(() => {
    if (!endpoint) return;
    let live = true;
    // Until the first answer, a socket opening is that answer's to report.
    let answered = false;
    const locate = shell()?.readDaemon;
    const next = new DaemonClient(endpoint, {
      onClose: () => live && setStatus("error"),
      onOpen: (at) => {
        if (!live || !answered) return;
        setReached(at);
        setPrincipal(next.principal);
        setStatus("connected");
        setError(null);
        setOpened((n) => n + 1);
        // A socket opened again may be to a daemon that restarted, which holds no token.
        void next
          .identity()
          .then((who) => {
            if (live) setIdentity(who);
            return handOver(next, signedIn.current, who);
          })
          .then((linked) => live && linked && setIdentity(linked))
          .catch(() => undefined);
      },
      ...(locate ? { locate } : {}),
      // Asked at every dial, so a socket opened after the switch says what it now is.
      localOnly: storedLocalOnly,
    });
    setReached(null);
    dialling.current = true;
    next
      .identity()
      .finally(() => {
        if (live) dialling.current = false;
      })
      .then((who) => {
        if (!live) return;
        answered = true;
        setIdentity(who);
        setPrincipal(next.principal);
        setReached(next.endpoint);
        setClient(next);
        setStatus("connected");
        setError(null);
      })
      .catch((e: unknown) => {
        if (!live) return;
        setStatus("error");
        setError(locate ? (errorText(e)) : unreachable(endpoint, e));
      });

    return () => {
      live = false;
      next.disconnect();
      setClient(null);
    };
  }, [endpoint, dial]);

  // A daemon not reached yet is tried again, by itself, rather than only when somebody
  // presses Find: a first dial that failed (one just starting, a restart under way) never
  // dials again on its own, and the app would carry on as though there were no daemon while
  // one runs. Where the shell reads `daemon.json`, it is read first, and a daemon now
  // somewhere else is dialled there; otherwise the endpoint it was told is dialled again.
  // Every `firstMs` for a minute, then every `thenMs`; never while a client is there, whose
  // own dial follows a daemon that restarts, and never with nothing to dial.
  const unreached = client === null && !forgotten && (status === "error" || status === "absent");
  const read = shell()?.readDaemon;
  const canRedial = unreached && (endpoint !== null || Boolean(read));
  useEffect(() => {
    if (!canRedial) return;
    let live = true;
    const since = Date.now();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const again = (): void => {
      const wait = Date.now() - since < redialTiming.firstForMs ? redialTiming.firstMs : redialTiming.thenMs;
      timer = setTimeout(() => {
        void (async () => {
          const found = read ? await read().catch(() => null) : null;
          if (!live) return;
          if (found && (found.port !== endpoint?.port || found.token !== endpoint?.token)) setEndpoint(found);
          else if (endpoint && !dialling.current) setDial((n) => n + 1);
          // Asked again while nothing has changed: the next try is scheduled by this one.
          if (live) again();
        })();
      }, wait);
    };
    again();
    return () => {
      live = false;
      if (timer) clearTimeout(timer);
    };
  }, [canRedial, endpoint, read]);

  // The daemon reached with somebody signed in, or somebody signing in with the daemon
  // reached, and every token the sign-in renews after that.
  useEffect(() => {
    if (!client || !auth) return;
    let live = true;
    const give = (): void => {
      void client
        .identity()
        .then((who) => handOver(client, auth, who))
        .then((linked) => live && linked && setIdentity(linked))
        .catch(() => undefined);
    };
    give();
    const off = auth.onCredential(give);
    return () => {
      live = false;
      off();
    };
  }, [client, auth]);

  return {
    client,
    endpoint: reached ?? endpoint,
    status,
    opened,
    identity,
    user: machineUser(identity, principal),
    error,
    canFind,
    connectTo: useCallback((e: DaemonEndpoint) => {
      setError(null);
      setForgotten(false);
      if (!shell()?.findDaemon) rememberDaemon(e);
      setEndpoint(e);
    }, []),
    forget: useCallback(() => {
      forgetDaemon();
      setForgotten(true);
      setEndpoint(null);
      setReached(null);
      setIdentity(null);
      setPrincipal(null);
      setStatus(shell()?.findDaemon ? "absent" : "unsupported");
    }, []),
    find: useCallback(() => {
      setForgotten(false);
      setRound((n) => n + 1);
    }, []),
    // With the token, when the link names the plane this app is signed in to: linking is
    // what a private session needs, and the label alone seals nothing.
    link: useCallback(
      async (who) => {
        if (!client) return;
        const a = signedIn.current;
        const token = a && samePlane(who.plane_url, a.planeUrl) ? await a.token() : null;
        setIdentity(await client.linkIdentity({ ...who, ...(token ? { plane_token: token } : {}) }));
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
      .withToken((plane, token) => plane.listProfiles(token))
      .then((r) => live && setProfiles(r.profiles))
      .catch((e: unknown) => live && setError(errorText(e)));
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
  /** Answer an approval; a delegation's may carry an agent, the edited parts and a word back. */
  respond(callId: string, decision: ApprovalDecision, answer?: GateAnswer): Promise<void>;
  /** Answer a question — the agent's, or the harness's about the budget. */
  answer(callId: string, text: string): Promise<void>;
  cancel(): Promise<void>;
  /** The agent this session runs from its next turn (`profile.switch`, troupe Decision 841). */
  switchProfile(profile: string): Promise<ProfileSwitch>;
  /** The goal every later turn works towards (`session.goal.*`); the effect is its event. */
  setGoal(text: string): Promise<void>;
  clearGoal(): Promise<void>;
  /** A loop towards the goal, up to `max` iterations or the session's own cap. */
  startLoop(max?: number): Promise<void>;
  stopLoop(): Promise<void>;
  /** Fetch a blob's text. Called on expand and never on load. */
  readBlob(blob: string): Promise<string>;
  /**
   * Your own signed-in servers, offered to a team session (troupe Decision 748): `asking`
   * while the session's question waits for you, then `offered`, `declined` or `refused`.
   * `none` where there is nothing to offer, or no daemon to make the calls.
   */
  offer: OfferState;
  /** Answer the session's question about your servers: yes to those ticked, no, or the servers picked. */
  answerOffer(allow: OfferAnswer): void;
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
/** How long a send made before the session's view has attached waits for it. */
const ATTACH_WAIT_MS = 15_000;

/** How often an open team session looks for a server of yours signed in to since it asked. */
const OFFER_REFRESH_MS = 30_000;

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
  // Sends made before the view has attached: they wait for it rather than fail, as the
  // composer says ("held, and goes when the connection comes back"), for as long as
  // `ATTACH_WAIT_MS`; a view that fails to open, or a screen that goes first, refuses them.
  const waiting = useRef<{ resolve: (v: SessionView) => void; reject: (e: Error) => void }[]>([]);
  const settle = useCallback((v: SessionView | null, why = "not attached") => {
    const them = waiting.current;
    waiting.current = [];
    for (const w of them) {
      if (v) w.resolve(v);
      else w.reject(new Error(why));
    }
  }, []);
  // Held separately because closing is different: an attachment owns a socket and must
  // be told to let it go; a daemon's view is one of several on a socket that stays.
  const attachment = useRef<SessionAttachment | null>(null);
  const [view, setView] = useState<SessionView | null>(null);
  const [offer, setOffer] = useState<OfferState>({ state: "none" });
  // The answer the offer's question waits for, until the person gives it.
  const answering = useRef<((allow: OfferAnswer) => void) | null>(null);
  const local = onThisComputer(kind);
  // A laptop's session offered to the plane, steered from here through it.
  const relayed = kind === "remote";

  useEffect(() => {
    if (!sessionId) return;
    if (local ? !daemon : !auth) return;
    let live = true;
    // Whether this mount's `open` resolved while it was still mounted, so the cleanup
    // knows whether it owes the daemon a `close` — the one it would otherwise pay twice
    // when the open resolves after the unmount and that path closes too.
    let held = false;
    // The local view's stream, from its first event. The replay may arrive before `open`
    // has resolved, and until it has, nothing that arrives is news.
    // Each event folds with the time it arrived, which the curtain line and live reasoning count from.
    const listener = (e: TroupeEvent): void => {
      if (!live) return;
      const now = Date.now();
      setState((s) => fold(s, e, { now }));
      const v = ref.current;
      noticeEvent(sessionId, e, held && Boolean(v) && isDurable(e) && e.seq > v!.headSeq);
    };
    setState(emptyTranscript);
    setError(null);
    setStatus("connecting");
    setOffer({ state: "none" });

    // Your own signed-in servers, offered to a session on a pod (troupe Decision 748): the
    // daemon makes their calls with your sign-in, so only where there is one, and only from
    // the session's own screen, the one that activates it. The session asks you first.
    const offering =
      !local && !relayed && daemon && mode === "activate"
        ? new ServerOffer(daemon, {
            sessionId,
            confirmedBy: auth?.me?.subject,
            confirm: () => new Promise<OfferAnswer>((resolve) => (answering.current = resolve)),
            onState: (s) => live && setOffer(s),
          })
        : null;
    // A server signed in to while this is open is offered then, not at the next attachment:
    // looked for when the window comes back to the front, which is where a person returns
    // from the browser that signed them in, and every little while for one signed in elsewhere.
    const lookAgain = (): void => void offering?.refresh().catch(() => undefined);
    if (offering) globalThis.addEventListener("focus", lookAgain);
    const looking = offering ? setInterval(lookAgain, OFFER_REFRESH_MS) : null;

    // Two ways in, one view out. A session on this computer is reached over the socket
    // the daemon already has — there is no token to expire and nothing to reconnect
    // around — and a session on a worker is reached through an attachment that swaps
    // the socket underneath the view when the plane mints a new token.
    //
    // The local view is *listened to* rather than given this mount's hook: a view may
    // already be open for somebody else — another pane, or this same component mounted
    // twice by React in development — and a hook installed by the first opener would
    // keep folding into a state nobody renders. The listener goes in with the `open`, so
    // it is there before the replay is.
    const opened = local
      ? daemon!
          .open(sessionId, {}, listener)
          .then((v) => {
            if (!live) return void daemon!.close(sessionId, listener);
            held = true;
            ref.current = v;
            setView(v);
            settle(v);
            setStatus("live");
            void v.setPresence("viewing").catch(() => undefined);
            // Who comes and goes, steering it from another device among them, as it happens.
            void v.followPresence().catch(() => undefined);
            return undefined;
          })
      : SessionAttachment.open({
          sessionId,
          mode,
          // A relayed session is opened, and its token renewed, with `remote.open`; the
          // socket and everything on it are a pod's.
          ...planeOpener(auth!, sessionId, relayed),
          // A session waiting for a place is not asked after again once this screen has gone.
          alive: () => live,
          hooks: {
            onEvent: (e) => {
              if (!live) return;
              const now = Date.now();
              setState((s) => fold(s, e, { now }));
              // Until the attachment is here, what arrives is the replay.
              const v = ref.current;
              noticeEvent(sessionId, e, Boolean(v) && isDurable(e) && e.seq > v!.headSeq);
            },
          },
          onStatus: (s, d) => {
            if (!live) return;
            setStatus(s);
            setDetail(d ?? null);
          },
          ...(offering ? { onToolInvoke: offering.invoke, onLive: (conn) => void offering.offer(conn) } : {}),
        }).then((a) => {
          if (!live) return void a.close();
          attachment.current = a;
          ref.current = a.view;
          setView(a.view);
          settle(a.view);
          void a.view.setPresence("viewing").catch(() => undefined);
          return undefined;
        });

    void opened.catch((e: unknown) => {
      const why = errorText(e);
      settle(null, why);
      if (live) setError(why);
    });

    return () => {
      live = false;
      settle(null);
      if (offering) globalThis.removeEventListener("focus", lookAgain);
      if (looking) clearInterval(looking);
      answering.current?.(false);
      answering.current = null;
      const a = attachment.current;
      attachment.current = null;
      ref.current = null;
      setView(null);
      if (a) void a.close();
      else if (local && daemon && held) void daemon.close(sessionId, listener);
    };
  }, [auth, daemon, sessionId, mode, local, relayed, settle]);

  const attached = useCallback((): Promise<SessionView> => {
    const v = ref.current;
    if (v) return Promise.resolve(v);
    return new Promise<SessionView>((resolve, reject) => {
      const w = {
        resolve: (view: SessionView) => {
          clearTimeout(timer);
          resolve(view);
        },
        reject: (e: Error) => {
          clearTimeout(timer);
          reject(e);
        },
      };
      const timer = setTimeout(() => {
        waiting.current = waiting.current.filter((x) => x !== w);
        reject(new Error("not attached"));
      }, ATTACH_WAIT_MS);
      waiting.current.push(w);
    });
  }, []);

  // A team session's command that its pod refuses because the session has moved goes
  // after it through the plane and runs once more (PROTOCOL.md §6, "A session that
  // moves"). A session on this computer has nowhere else to be.
  const following = useCallback(<T,>(command: () => Promise<T>): Promise<T> => {
    const a = attachment.current;
    return a ? a.retrying(command) : command();
  }, []);

  const send = useCallback(async (text: string) => {
    const v = await attached();
    const commandId = v.conn.nextCommandId();
    setState((s) => addPending(s, commandId, text));
    try {
      await following(() => v.send(text, commandId));
    } catch (e) {
      setState((s) => dropPending(s, commandId));
      throw e;
    }
  }, [following]);

  // A delegation's answer carries more than its word (troupe Decision 850).
  const respond = useCallback(async (callId: string, decision: ApprovalDecision, answer: GateAnswer = {}) => {
    const v = ref.current;
    if (v) await following(() => v.respondApproval(callId, decision, answer));
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
    if (!v) throw new Error("not attached");
    return following(() => v.switchProfile(profile));
  }, [following]);

  const setGoal = useCallback(async (text: string) => {
    const v = ref.current;
    if (!v) throw new Error("not attached");
    await following(() => v.setGoal(text));
  }, [following]);

  const clearGoal = useCallback(async () => {
    const v = ref.current;
    if (v) await following(() => v.clearGoal());
  }, [following]);

  const startLoop = useCallback(async (max?: number) => {
    const v = ref.current;
    if (!v) throw new Error("not attached");
    await following(() => v.startLoop(max));
  }, [following]);

  const stopLoop = useCallback(async () => {
    const v = ref.current;
    if (v) await following(() => v.stopLoop());
  }, [following]);

  const readBlob = useCallback(async (blob: string) => {
    const v = ref.current;
    if (!v) throw new Error("not attached");
    return v.blobText(blob);
  }, []);

  const answerOffer = useCallback((allow: OfferAnswer) => {
    const resolve = answering.current;
    answering.current = null;
    resolve?.(allow);
  }, []);

  return { state, status, detail, view, send, respond, answer, cancel, switchProfile, setGoal, clearGoal, startLoop, stopLoop, readBlob, offer, answerOffer, error };
}

// The start this app began for each session it started, by daemon connection: a screen
// that goes and comes back, or one React mounts twice in development, finds the start it
// began, so the librarian starts once per session start (the terminal client's Decision
// 127) and an unanswered question is still there.
const begun = new WeakMap<DaemonClient, Map<string, StartQuestions>>();

/**
 * The questions a session's start asks on this computer (troupe Decision 835): onboarding
 * other tools' files into Troupe's own, then the brief. A session this app has just
 * started (`startedIn`, the workspace `session.create` answered with) begins at once, and
 * goes on to start the librarian on a missing or stale brief, as the terminal client does;
 * one opened again begins on its `onboarding_suggested`, once per event, and starts none.
 * Both are asked of the daemon that holds the session; the daemon's plan decides what is
 * due, so a session opened again after it was answered asks nothing. A team session's pod
 * is not this computer's to onboard, and a reader answers nothing, so neither is asked.
 */
export function useStartQuestions(
  daemon: DaemonClient | null,
  sessionId: string,
  onboarding: OnboardingSuggested | undefined,
  opts: { local: boolean; canAnswer: boolean; startedIn?: string | undefined },
): { state: StartState | null; answer: (answer: StartAnswer) => void } {
  const [state, setState] = useState<StartState | null>(null);
  const flow = useRef<StartQuestions | null>(null);
  const seq = onboarding?.seq;
  const workspace = onboarding?.workspace;
  const { local, canAnswer, startedIn } = opts;

  useEffect(() => {
    setState(null);
    if (!daemon || !local || !canAnswer) return;

    const started = begun.get(daemon) ?? new Map<string, StartQuestions>();
    begun.set(daemon, started);
    let mine = started.get(sessionId);
    if (!mine && startedIn) {
      mine = new StartQuestions(daemon, { workspace: startedIn, sessionId, started: true });
      started.set(sessionId, mine);
      void mine.start();
    }
    if (mine) {
      const questions = mine;
      flow.current = questions;
      setState(questions.current);
      const off = questions.subscribe(setState);
      return () => {
        off();
        if (flow.current === questions) flow.current = null;
      };
    }

    if (seq === undefined || !workspace) return;
    let live = true;
    const questions = new StartQuestions(daemon, { workspace, sessionId, onState: (s) => live && setState(s) });
    flow.current = questions;
    void questions.start();
    return () => {
      live = false;
      if (flow.current === questions) flow.current = null;
    };
  }, [daemon, sessionId, seq, workspace, local, canAnswer, startedIn]);

  const answer = useCallback((a: StartAnswer) => void flow.current?.answer(a), []);
  return { state, answer };
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
      .catch((e: unknown) => live && setError(errorText(e)))
      .finally(() => live && setLoading(false));
    return () => {
      live = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, round]);

  return { data, loading, error, reload: useCallback(() => setRound((n) => n + 1), []) };
}
