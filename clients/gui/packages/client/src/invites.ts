// Inviting a person into a session by name (troupe #765).
//
// A pod session is invited at the plane (`session.invite`), and its invitation is the
// session's grant made visible: `observe` follows it as a viewer, `control` steers it as a
// collaborator. A private session is invited from the daemon that seals it, which puts the
// session's key in the invitee's own slot at the key manager and tells the plane where; the
// plane cannot read it. The invitee hears of either over their watch (`invites.changed`),
// and reads a private one through their own daemon, from the plane's sealed copy
// (`session.read_sealed`), since only their own machine can open it.

import { TroupeRpcError } from "./connection.js";

/** What an invitation lets a person do: follow the session, or steer it as well. */
export type InviteRole = "observe" | "control";

/** An invitation to this person, as `invites.list` and the watch say it. */
export interface Invitation {
  session_id: string;
  /** `team` for a pod session, `private` for one sealed on its owner's machine. */
  kind: string;
  title?: string | null;
  profile?: string | null;
  state?: string | null;
  owner: string;
  owner_name?: string | null;
  role: InviteRole;
  invited_by: string;
  invited_by_name?: string | null;
  invited_at: string;
  /**
   * A private session's: whether its owner offers it for steering now, which is when an
   * invitation with control steers it. Null for a pod session, and from a plane before it.
   */
  offered?: boolean | null;
}

/** A person invited into a session, as `session.invites` lists them to anybody in it. */
export interface Invitee {
  subject: string;
  display_name?: string | null;
  email?: string | null;
  role: InviteRole;
  invited_by: string;
  invited_at: string;
}

/** A person a picker offers, from `people.search`. */
export interface Person {
  subject: string;
  display_name?: string | null;
  email?: string | null;
}

/** One event of a private session read from its sealed copy, as the log has it. */
export type SealedEvent = Record<string, unknown> & { seq?: number; type?: string };

/** What `session.read_sealed` answers: the sealed log after a point, and how far it goes. */
export interface SealedRead {
  session_id: string;
  events: SealedEvent[];
  last_seq?: number | null;
  key_version?: number | null;
}

/** The invitations in a value a plane sent, the well-formed ones. */
export function invitationsFrom(value: unknown): Invitation[] {
  if (!Array.isArray(value)) return [];
  return value.filter(
    (v): v is Invitation =>
      typeof v === "object" && v !== null && typeof (v as Invitation).session_id === "string" && typeof (v as Invitation).role === "string",
  );
}

/** A person's name as a list shows it. */
export function personName(p: { subject: string; display_name?: string | null; email?: string | null }): string {
  return p.display_name || p.email || p.subject;
}

/** What a role lets somebody do, in words: "follows" or "steers". */
export function roleWords(role: string): string {
  return role === "control" ? "steers" : "follows";
}

/** Who invited this person, and to do what: "Ada invited you to follow it". */
export function invitationWords(i: Invitation): string {
  const by = i.invited_by_name || i.invited_by;
  return `${by} invited you to ${i.role === "control" ? "steer" : "follow"} it`;
}

/**
 * What a private session's invitation to steer lets this person do now, in the words every
 * client says it in: steer it while its owner offers it, and read it otherwise. Null for an
 * invitation to follow, and for a pod session's, whose invitation is its grant whatever the
 * owner does.
 */
export function steerWords(i: Invitation): string | null {
  if (i.kind !== "private" || i.role !== "control") return null;
  return i.offered ? "offered · you can steer" : "not offered · read-only";
}

/** What an open view says when the invitation it was opened under is taken back. */
export function removedSentence(owner?: string | null): string {
  return `${owner || "Its owner"} took back your invitation: this session is no longer shared with you.`;
}

/** Why an invitation was refused, in words a person can act on. */
export function inviteRefusal(e: unknown): string {
  if (e instanceof TroupeRpcError) {
    const reason = e.data?.["reason"];
    if (typeof reason === "string" && reason === "not on this profile's teams") {
      const profile = e.data?.["profile"];
      return `Not on this profile's teams${typeof profile === "string" ? ` (${profile})` : ""}: they would act under its rules.`;
    }
    if (typeof reason === "string") return reason.charAt(0).toUpperCase() + reason.slice(1);
    if (e.message === "not_found") return "Nobody of that name has signed in to this plane yet.";
  }
  return e instanceof Error ? e.message : String(e);
}
