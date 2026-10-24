// Who is signed in, to which plane, and what they may administer there, if anything:
// everything a screen needs besides its own calls, worked out once after the sign-in.

import { createContext, useCallback, useContext, useEffect, useRef, useState } from "react";
import { AdminApi, TroupeRpcError, requiredRole } from "@troupe/client";
import type { AuthSession, Discovery, Me } from "@troupe/client";
import type { Role } from "./nav";

export interface Signed {
  auth: AuthSession;
  admin: AdminApi;
  /** The person, as the plane's `me` says: the one call here that is not `admin.*`. */
  me: Me;
  role: Role;
  /** The teams a team admin administers; every team, for a platform admin, is not listed here. */
  teams: string[];
  plane: { url: string; name: string; version: string | null };
  signOut: () => void;
  /** A short line at the corner of the screen once something has been done. */
  notify: (text: string) => void;
}

export const ConsoleContext = createContext<Signed | null>(null);

export function useConsole(): Signed {
  const c = useContext(ConsoleContext);
  if (!c) throw new Error("useConsole outside a signed-in console");
  return c;
}

/** What working out the role found: an administrator's role and teams, or a member's, who administers nothing. */
export interface Standing {
  role: Role;
  teams: string[];
  me: Me;
}

/**
 * Whether this person administers anything here, and which role.
 *
 * `me` says whether they are a platform admin. A team admin is anybody the plane answers
 * `admin.teams.list` for, with the teams it names; somebody it refuses for want of a role
 * is a member, whose console is what is theirs and none of the administrative areas.
 */
export async function standing(auth: AuthSession, admin: AdminApi): Promise<Standing> {
  const me = await auth.rpc<Me>("me");
  if (me.platform_admin) return { role: "platform_admin", teams: [], me };
  try {
    const teams = await admin.teams();
    return { role: "team_admin", teams: teams.map((t) => t.name), me };
  } catch (e) {
    if (requiredRole(e)) return { role: "member", teams: [], me };
    throw e;
  }
}

/**
 * The audit's own record of a change this person just made, read back with
 * `admin.audit.list`, for a write whose answer does not carry its diff. The newest row of
 * that action on that subject by them; `null` where the audit could not be read, which the
 * note then says, since the change itself is made either way.
 */
export async function recorded(admin: AdminApi, actor: string, action: string, subject: string): Promise<Record<string, unknown> | null> {
  try {
    const rows = await admin.audit({ actor, kind: action.split(".")[0] ?? action, subject_id: subject, limit: 10 });
    const row = rows.find((r) => r.action === action);
    return row ? (row.detail ?? {}) : null;
  } catch {
    return null;
  }
}

export function planeOf(auth: AuthSession, discovery: Discovery | null): Signed["plane"] {
  const plane = (discovery?.plane ?? {}) as { name?: unknown; build?: { version?: unknown } };
  return {
    url: auth.planeUrl,
    name: typeof plane.name === "string" ? plane.name : new URL(auth.planeUrl).host,
    version: typeof plane.build?.version === "string" ? plane.build.version : null,
  };
}

export type Load<T> = { state: "loading" } | { state: "error"; error: unknown } | { state: "ready"; data: T };

/**
 * One screen's read: loading, then the answer or the error, and `reload` to ask again
 * (after a change, or from the error state's retry). A reload keeps what is on the screen
 * until the new answer replaces it, so a change applied does not blank the page it was
 * made on; a read of something else starts from loading. An answer that arrives after the
 * screen has moved on, or after a newer read, is dropped.
 */
export function useLoad<T>(read: () => Promise<T>, deps: unknown[]): [Load<T>, () => void] {
  const [load, setLoad] = useState<Load<T>>({ state: "loading" });
  const [tick, setTick] = useState(0);
  const latest = useRef(0);
  const before = useRef<unknown[] | null>(null);
  useEffect(() => {
    const same = before.current !== null && before.current.length === deps.length && before.current.every((d, i) => Object.is(d, deps[i]));
    before.current = deps;
    const mine = ++latest.current;
    setLoad((now) => (same && now.state === "ready" ? now : { state: "loading" }));
    read().then(
      (data) => {
        if (latest.current === mine) setLoad({ state: "ready", data });
      },
      (error: unknown) => {
        if (latest.current === mine) setLoad({ state: "error", error });
      },
    );
    return () => {
      latest.current += 1;
    };
    // `read` is a closure over `deps`: the caller lists what it reads.
  }, [...deps, tick]);
  const reload = useCallback(() => setTick((t) => t + 1), []);
  return [load, reload];
}

/** The plane's refusal in words a person can act on, and the plane's own where it gave some. */
export function describeError(e: unknown): string {
  if (e instanceof TroupeRpcError) {
    const data = (e.data ?? {}) as Record<string, unknown>;
    const role = requiredRole(e);
    if (role) {
      const why = typeof data["reason"] === "string" ? ` ${String(data["reason"])}.` : "";
      return `The plane refused this: it needs a ${role === "platform_admin" ? "platform admin" : "team admin"}.${why}`;
    }
    if (data["ceiling"] !== undefined && typeof data["field"] === "string") {
      return `${data["field"]}: ${show(data["asked"])} is wider than ${show(data["ceiling"])}, which the ${String(data["decided_by"])} decided. A lower rung may only narrow.`;
    }
    if (typeof data["reason"] === "string") {
      return typeof data["field"] === "string" ? `${data["field"]}: ${data["reason"]}` : String(data["reason"]);
    }
    if (e.code === NOT_FOUND) return "The plane has no such thing, or it is not one you administer.";
    if (e.code === METHOD_NOT_FOUND) return "This plane does not have that method: it is older than this console.";
    if (e.code === UNAUTHENTICATED) return "Your sign-in has ended. Sign in again.";
    return e.message;
  }
  return e instanceof Error ? e.message : String(e);
}

const UNAUTHENTICATED = -32003;
const NOT_FOUND = -32005;
const METHOD_NOT_FOUND = -32601;

/** A value as the console shows it: unset as a dash, a list joined, an object as its JSON. */
export function show(value: unknown): string {
  if (value === null || value === undefined || value === "") return "—";
  if (Array.isArray(value)) return value.length ? value.map(show).join(", ") : "none";
  if (typeof value === "boolean") return value ? "yes" : "no";
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}
