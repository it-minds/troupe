// What a plane says about this client's version (#66, Decisions 868 and 874).
//
// A plane holds each kind of client — the terminal, the daemon, the desktop app — to a
// policy: a recommended version, a minimum and a blocked list. Its `initialize` over
// `POST /rpc` is where it says what that means for one client: served, with the policy as
// `client_update` and `action: "suggest"` where a newer version is recommended; or refused
// with `update_required` (-32016) on a blocked version or below the minimum, whose `data`
// says which and what to install. A plane from before the policy has no `initialize`
// there and says nothing.
//
// `me.client_versions` is every component's policy, asked on its own because the client
// that most needs it is the one `initialize` refuses: it is what an update chooses the
// version by.

import { TroupeRpcError } from "./connection.js";
import { ErrorCodes } from "./types.js";
import type { AuthSession } from "./auth.js";

/** The name the desktop app gives at `initialize`, which a plane reads as `desktop` (PROTOCOL.md §3). */
export const DESKTOP_CLIENT = "troupe-gui";

/** One component's policy, as `me.client_versions` answers it. */
export interface VersionPolicy {
  recommended?: string | null;
  minimum?: string | null;
  blocked?: string[];
}

/** What a plane's `initialize` says to a client it serves. */
export interface ClientUpdate {
  component: string;
  recommended: string | null;
  minimum: string | null;
  blocked: string[];
  /** `suggest` below the recommended version, `none` at it or past it. */
  action: "suggest" | "none" | string;
}

/** The `data` of an `update_required` refusal. */
export interface UpdateRequired {
  component?: string;
  version?: string;
  minimum?: string | null;
  recommended?: string | null;
  blocked?: boolean;
  run?: string | null;
  reason?: string;
}

/** What the plane said, and every component's policy where it could be asked. */
export type PlaneVersionWord =
  | { state: "served"; clientUpdate: ClientUpdate | null; versions: Record<string, VersionPolicy> | null }
  | { state: "required"; refusal: UpdateRequired; sentence: string; versions: Record<string, VersionPolicy> | null }
  /** A plane from before the policy: no word either way. */
  | { state: "unknown" };

function program(component: string | undefined): string {
  return { tui: "troupe", daemon: "troupe-daemon", desktop: "the desktop app" }[component ?? ""] ?? "this client";
}

/**
 * The sentence the desktop app shows for `update_required`, from the refusal's fields, as
 * the terminal words its own (`Troupe.Protocol.ClientUpdate.sentence/1`): the desktop app
 * updates itself, so the remedy is to do that now.
 */
export function updateRequiredSentence(data: UpdateRequired | undefined): string {
  const remedy = data?.recommended ? `update it now, which installs ${data.recommended}` : "update it now";
  if (data?.version && data.blocked === true) {
    return `This plane does not serve ${program(data.component)} ${data.version}, which its administrators have blocked: ${remedy}.`;
  }
  if (data?.version && data.minimum) {
    return `This plane needs ${program(data.component)} ${data.minimum} or later, and this is ${data.version}: ${remedy}.`;
  }
  if (data?.reason) return data.reason;
  return `This plane needs a newer version of ${program(data?.component)}: ${remedy}.`;
}

/**
 * The quiet offer for `suggest`: what the plane recommends, and what this is, as the
 * terminal says its own (`ClientUpdate.suggestion/2`). What to do is the offer's button.
 */
export function suggestion(update: ClientUpdate | null, current: string): string | null {
  if (update?.action !== "suggest" || !update.recommended) return null;
  return `This plane recommends ${program(update.component)} ${update.recommended}, and this is ${current}.`;
}

function isMethodNotFound(e: unknown): boolean {
  return e instanceof TroupeRpcError && e.code === ErrorCodes.method_not_found;
}

/**
 * Every component's policy, or null from a plane that has no `me.client_versions` or did
 * not answer: an update then follows the latest release, as it would signed in nowhere.
 */
async function clientVersions(auth: AuthSession): Promise<Record<string, VersionPolicy> | null> {
  try {
    const answer = await auth.rpc<Record<string, VersionPolicy>>("me.client_versions");
    return answer && typeof answer === "object" ? answer : null;
  } catch {
    return null;
  }
}

/**
 * Ask the plane what it says to this desktop app: its `initialize`, with the component's
 * name and the version as releases are numbered, then the policy an update chooses by.
 * Throws where the plane could not be asked at all; a plane from before the policy is
 * `unknown`, which is no reason to do anything.
 */
export async function askPlane(auth: AuthSession, version: string): Promise<PlaneVersionWord> {
  let clientUpdate: ClientUpdate | null;
  try {
    const hello = await auth.rpc<{ client_update?: ClientUpdate | null }>("initialize", {
      protocol_version: "1",
      client_info: { name: DESKTOP_CLIENT, version },
    });
    clientUpdate = hello?.client_update ?? null;
  } catch (e) {
    if (isMethodNotFound(e)) return { state: "unknown" };
    if (e instanceof TroupeRpcError && e.code === ErrorCodes.update_required) {
      const refusal = (e.data ?? {}) as UpdateRequired;
      return { state: "required", refusal, sentence: updateRequiredSentence(refusal), versions: await clientVersions(auth) };
    }
    throw e;
  }
  return { state: "served", clientUpdate, versions: await clientVersions(auth) };
}
