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
// version by. The plane signs it with a key of its own (#657), and it is taken only as
// signed by the key this machine pinned for the plane; a plane that signs nothing is taken
// at its word, and that said. A refusal of this version is signed too, for this client and
// version, and is not acted on where the pinned key did not sign it.

import { TroupeRpcError } from "./connection.js";
import { ErrorCodes } from "./types.js";
import type { AuthSession } from "./auth.js";
import { refusalSentence, verifySigned } from "./planeSignature.js";
import type { PlaneKey, SignedAnswer } from "./planeSignature.js";

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

/**
 * Whether the policy was the plane's signed word: checked against the key pinned for it,
 * from a plane that signs nothing, taken with no key pinned here to check it by, or refused.
 */
export type SignatureWord =
  | { state: "signed" }
  | { state: "unsigned"; line: string }
  | { state: "unchecked" }
  | { state: "refused"; sentence: string };

/** What the plane said, and every component's policy where it could be asked and was its signed word. */
export type PlaneVersionWord =
  | {
      state: "served";
      clientUpdate: ClientUpdate | null;
      versions: Record<string, VersionPolicy> | null;
      /** Where the plane says releases are, each under `v<version>/`; null for GitHub's. */
      releaseUrl?: string | null;
      /** The policy's `signed` as it came, where the pinned key held for it: the shell checks it again itself. */
      signed?: SignedAnswer | null;
      signature?: SignatureWord;
    }
  | {
      state: "required";
      refusal: UpdateRequired;
      sentence: string;
      versions: Record<string, VersionPolicy> | null;
      releaseUrl?: string | null;
      signed?: SignedAnswer | null;
      signature?: SignatureWord;
    }
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

interface VersionsAnswer {
  versions: Record<string, VersionPolicy> | null;
  releaseUrl: string | null;
  signed?: SignedAnswer | null;
  signature?: SignatureWord;
}

type RawVersions = Record<string, unknown> & { signed?: SignedAnswer | null; release?: { url?: string | null } | null };

function releaseOf(answer: { release?: { url?: string | null } | null } | null | undefined): string | null {
  const url = answer?.release?.url;
  return typeof url === "string" && url !== "" ? url : null;
}

function policiesOf(answer: RawVersions): Record<string, VersionPolicy> {
  const { signed: _signed, release: _release, ...policies } = answer;
  return policies as Record<string, VersionPolicy>;
}

/**
 * Every component's policy, or null from a plane that has no `me.client_versions`, did not
 * answer, or answered with something its pinned key did not sign: an update then follows
 * the latest release, as it would signed in nowhere.
 */
async function clientVersions(auth: AuthSession, pinned: PlaneKey | null | undefined): Promise<VersionsAnswer> {
  let answer: RawVersions | null;
  try {
    const got = await auth.rpc<RawVersions>("me.client_versions");
    answer = got && typeof got === "object" ? got : null;
  } catch {
    answer = null;
  }
  if (!answer) return { versions: null, releaseUrl: null };
  const plane = auth.planeUrl.replace(/\/+$/, "");

  if (pinned) {
    const checked = await verifySigned<{ versions?: Record<string, VersionPolicy>; release?: { url?: string | null } }>(answer.signed, pinned, "client_versions");
    if (!checked.ok) {
      return { versions: null, releaseUrl: null, signature: { state: "refused", sentence: `${refusalSentence(checked, plane, "the version policy", pinned.fingerprint)}.` } };
    }
    return { versions: checked.body.versions ?? {}, releaseUrl: releaseOf(checked.body), signed: answer.signed ?? null, signature: { state: "signed" } };
  }
  if (!answer.signed) {
    return {
      versions: policiesOf(answer),
      releaseUrl: releaseOf(answer),
      signature: { state: "unsigned", line: `${plane} signs nothing it tells clients (a plane from before 0.22): the version policy is taken as it is.` },
    };
  }
  // Signed, and no key pinned here to check it by: a daemon from before #657 keeps none.
  return { versions: policiesOf(answer), releaseUrl: releaseOf(answer), signature: { state: "unchecked" } };
}

/**
 * Ask the plane what it says to this desktop app: its `initialize`, with the component's
 * name and the version as releases are numbered, then the policy an update chooses by,
 * checked against `pinned`, the key this machine holds for the plane, where there is one.
 * Throws where the plane could not be asked at all; a plane from before the policy is
 * `unknown`, which is no reason to do anything.
 */
export async function askPlane(auth: AuthSession, version: string, pinned?: PlaneKey | null): Promise<PlaneVersionWord> {
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
      const held = await heldRefusal(auth, (e.data ?? {}) as UpdateRequired & { signed?: SignedAnswer }, version, pinned);
      const versions = await clientVersions(auth, pinned);
      if ("notTaken" in held) {
        return { state: "served", clientUpdate: null, ...versions, signature: { state: "refused", sentence: held.notTaken } };
      }
      return { state: "required", refusal: held.refusal, sentence: updateRequiredSentence(held.refusal), ...versions };
    }
    throw e;
  }
  return { state: "served", clientUpdate, ...(await clientVersions(auth, pinned)) };
}

/**
 * A refusal of this version as the plane signed it, `update_required` for the desktop app
 * and this version, checked against the pinned key; from a plane nothing is pinned for, as
 * it came. Otherwise why it is not taken: the app then goes on as with a plane that could
 * not be asked, told to update by nothing it cannot check.
 */
async function heldRefusal(
  auth: AuthSession,
  data: UpdateRequired & { signed?: SignedAnswer },
  version: string,
  pinned: PlaneKey | null | undefined,
): Promise<{ refusal: UpdateRequired } | { notTaken: string }> {
  const { signed, ...refusal } = data;
  if (!pinned) return { refusal };
  const plane = auth.planeUrl.replace(/\/+$/, "");
  const checked = await verifySigned<UpdateRequired>(signed, pinned, "update_required");
  if (!checked.ok) return { notTaken: `${refusalSentence(checked, plane, "the plane's refusal of this version", pinned.fingerprint)}.` };
  if (checked.body.component !== "desktop" || checked.body.version !== version) {
    return { notTaken: `${plane} signed a refusal of another client or version than this one: it is not taken.` };
  }
  return { refusal: checked.body };
}
