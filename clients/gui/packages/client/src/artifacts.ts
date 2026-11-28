// Artifacts: what a person or their agents published to the plane's artifacts host, as any
// signed-in person's client asks for them (`artifact.*`), and never an administrative call.
//
// A client reads the list, one artifact with its versions, and asks for a link to open one
// at the moment a person opens it: the link is one-time and short-lived, and the artifact
// is shown by the artifacts host in a tab of its own. A client never draws an artifact's
// content inside itself: an editor reads one text file of it (`artifact.read`) to change it,
// and its preview is an address on the artifacts host (`artifact.preview`) that the client
// frames, sandboxed, as it frames nothing else.

import { andList } from "./newSession.js";
import type { Person } from "./invites.js";
import type { GateAnswer, PublicationGate } from "./transcript.js";

type Rpc = <T = unknown>(method: string, params?: unknown) => Promise<T>;

export type ArtifactKind = "html" | "markdown" | "file";

/**
 * What a person is to an artifact: its owner, or what a link, the owner's naming them or who
 * it is for gives them. `comment` reads it and writes in its thread; `edit` also publishes
 * new versions of it.
 */
export type ArtifactRole = "owner" | "edit" | "comment" | "view";

/** The role a link or a person's share gives. */
export type ArtifactShareRole = "view" | "comment" | "edit";

/** Who owns an artifact, or published one of its versions. */
export interface ArtifactPerson {
  subject: string;
  display_name?: string | null;
}

/** Where an artifact came from: the session, profile and agent that published it, and on what. */
export interface ArtifactOrigin {
  session_id?: string | null;
  profile?: string | null;
  agent?: string | null;
  where?: "pod" | "laptop" | "person" | null;
}

/**
 * The gallery tab an artifact is under for this caller, as the plane says it: `mine` (theirs,
 * which others read too), `private` (theirs, which only they open), `organisation`,
 * `team:<name>` (a team of theirs reads it), or `shared` (a link or a grant by name gave it
 * them). A client tabs by it and works out nobody's membership itself.
 */
export type ArtifactScope = string;

/**
 * Whose a new artifact is: the publisher's own (the default), `team`, the one team in its
 * `teams`, or a named team of theirs. The teams that read one do not own it.
 */
export type ArtifactOwner = "me" | "team" | `team:${string}`;

/** Where a transfer sends an artifact: to a team of the owner's, or back to the caller. */
export type ArtifactTransferTo = "me" | `team:${string}`;

/** An artifact as `artifact.list` answers it, for this caller. */
export interface Artifact {
  id: string;
  title: string;
  kind: ArtifactKind;
  /** `organisation` while every signed-in person reads it, else `private`: its readers alone. */
  visibility: string;
  /** The teams that read it, by name, beside its owner and the people and links it is shared through. Absent from a plane from before the set. */
  teams?: string[];
  /** Whether every signed-in person reads it. Absent from a plane from before the set. */
  organisation?: boolean;
  /** Which part of a gallery it is in for this caller: `mine`, `private`, `organisation`, `team:<name>` or `shared`. */
  scope?: ArtifactScope;
  /** The person who first published it, which a team's keeps. */
  owner: ArtifactPerson;
  /**
   * The team that owns it, or null for one a person owns. Every member of the team is its
   * owner: `role` is `owner` and `mine` true for each of them, and a member leaving the
   * team changes nothing of the artifact. Absent from a plane from before team ownership.
   */
  owner_team?: string | null;
  /**
   * Whether this caller may give it to a team (the owning person, or a platform admin) or
   * take it back from one (an admin of the owning team, or a platform admin).
   */
  may_transfer?: boolean;
  /** Whether it is the caller's own: theirs, or their team's. */
  mine: boolean;
  /** What the caller is to it now. */
  role?: ArtifactRole | null;
  origin: ArtifactOrigin;
  team: string | null;
  /** The newest version. */
  version: number;
  /** The version its address serves: the pinned one, else the newest. */
  current?: number;
  /** The version its owner pinned, or null for the newest. */
  pinned?: number | null;
  bytes: number;
  url: string;
  /**
   * The picture its publisher sent of the version its address serves, on the artifacts host,
   * for this caller alone and for an hour or two: a card draws it, never the page. Null or
   * absent where none was sent, or from a plane from before thumbnails.
   */
  thumbnail_url?: string | null;
  /**
   * How many references the artifacts host blocks in the version its address serves (a
   * stylesheet from another site, an inline script), read from its files at publish. Zero
   * for one published before that check; absent from an older plane.
   */
  blocked_count?: number;
  created_at: string;
  published_at: string;
  /** Whether this caller may delete it: its owner, or a platform admin taking it down. */
  may_delete: boolean;
  /** Whether this caller may publish a new version of it: its owner, or an edit link's holder. */
  may_edit?: boolean;
  /** Whether this caller may write in its thread: its owner, or somebody given comment or edit. */
  may_comment?: boolean;
  /** How many comments its thread has, and when the newest was written. Absent from a plane from before comments. */
  comments?: number;
  commented_at?: string | null;
  /** The owner's switch for its public links. */
  public_links?: boolean;
  /** Whether a public link opens it now. */
  public?: boolean;
  /**
   * When it is removed because nobody opened it (`artifacts_keep_unopened_days`); opening it
   * moves the date out. Null, or absent from an older plane, while no such period is set.
   */
  goes_at?: string | null;
  /**
   * Whether the caller keeps it at the top of their own gallery: the person's view, kept on
   * the plane so every device and app of theirs shows it so, and nobody else's. Absent from
   * a plane from before it.
   */
  kept?: boolean;
}

/** An administrator's retention periods, in days; null for one that is off. */
export interface ArtifactRetention {
  versions_days: number | null;
  unopened_days: number | null;
}

export interface ArtifactFile {
  path: string;
  sha256: string;
  content_type: string;
  bytes: number;
}

export interface ArtifactVersion {
  n: number;
  hash: string;
  bytes: number;
  files: ArtifactFile[];
  published_by: ArtifactPerson;
  published_at: string;
  /** What its publisher said of it; a rollback's says which version it brought back. */
  note?: string | null;
  rolled_back_to?: number | null;
  /** When it is removed for its age (`artifacts_keep_versions_days`); null for the newest, the pinned one, and every one while that is off. */
  goes_at?: string | null;
  url: string;
  /** What the artifacts host blocks in it, read from its files at publish. Absent from an older plane. */
  blocked?: ArtifactBlocked[];
}

/** The kinds of reference the artifacts host blocks. */
export type ArtifactBlockedKind =
  | "stylesheet"
  | "script"
  | "image"
  | "font"
  | "media"
  | "frame"
  | "object"
  | "connect"
  | "read"
  | "inline_script"
  | "event_handler";

/** One reference in a version's file that the artifacts host will block. */
export interface ArtifactBlocked {
  file: string;
  kind: ArtifactBlockedKind | string;
  reference: string;
  line?: number;
}

/** What a kind of blocked reference is, in words: "a stylesheet from another site". */
export function blockedKindWords(kind: string): string {
  switch (kind) {
    case "stylesheet":
      return "a stylesheet from another site";
    case "script":
      return "a script from another site";
    case "image":
      return "an image from another site";
    case "font":
      return "a font from another site";
    case "media":
      return "a sound or film from another site";
    case "frame":
      return "a page from another site in a frame";
    case "object":
      return "an embedded object";
    case "connect":
      return "a connection to another site";
    case "read":
      return "a read by fetch, XMLHttpRequest, EventSource, import(), a module or a web font, which fails even for the page's own file";
    case "inline_script":
      return "an inline script";
    case "event_handler":
      return "an inline event handler";
    default:
      return kind;
  }
}

/** The line an artifact's page says of its blocked references, or null for none. */
export function blockedWords(count: number | null | undefined): string | null {
  if (!count) return null;
  return `This version references ${count} ${count === 1 ? "thing" : "things"} the artifacts host blocks, so it may look or work broken. An artifact may load only its own files.`;
}

/** Somebody the plane signed in through a link, and when. */
export interface ArtifactLinkUse {
  person: ArtifactPerson;
  first_used_at: string;
  last_used_at: string;
  revoked_at: string | null;
}

/** A link to an artifact, as its owner reads it: never its token, which is shown once. */
export interface ArtifactShare {
  id: string;
  role: ArtifactShareRole;
  public: boolean;
  state: "live" | "expired" | "revoked" | "switched off";
  expires_at: string | null;
  revoked_at: string | null;
  created_by: string;
  created_at: string;
  used_by: ArtifactLinkUse[];
}

/** Somebody an owner shared an artifact with by name, and at what role. */
export interface ArtifactPersonShare {
  subject: string;
  display_name?: string | null;
  email?: string | null;
  role: ArtifactShareRole;
  granted_by: string;
  granted_at: string;
}

/** One comment in an artifact's thread. */
export interface ArtifactComment {
  id: string;
  author: ArtifactPerson;
  body: string;
  created_at: string;
  /** When its author last edited it; null or absent for one never edited. */
  edited_at?: string | null;
  /** Whether the caller may edit it: its author, while they may write in the thread. Absent from a plane from before it. */
  may_edit?: boolean;
  /** Whether the caller may delete it: its author, an owner, or whoever may take the artifact down. Absent from a plane from before it. */
  may_delete?: boolean;
}

/** What `artifact.comments` answers: the thread, oldest first, and whether the caller may write in it. */
export interface ArtifactThread {
  id: string;
  may_comment: boolean;
  max_length: number;
  comments: ArtifactComment[];
}

/** A team that reads an artifact, as `artifact.access.get` answers it: who added it, and when. */
export interface ArtifactAccessTeam {
  name: string;
  granted_by?: string | null;
  at?: string | null;
}

/** Somebody an artifact is shared with by name, as `artifact.access.get` answers it. */
export interface ArtifactAccessPerson {
  subject: string;
  display_name?: string | null;
  role: ArtifactShareRole;
}

/**
 * Who reads an artifact, as its owner reads it (`artifact.access.get`): its owner, the teams
 * that read it, the people it is shared with by name at their roles, whether the whole
 * organisation does, its links, the plane's sentence for it all, and the teams the owner may
 * add (theirs, and those granted the profile its session ran on). Kept across its versions.
 */
export interface ArtifactAccess {
  id: string;
  owner?: ArtifactPerson | null;
  owner_team?: string | null;
  teams: ArtifactAccessTeam[];
  people: ArtifactAccessPerson[];
  organisation: boolean;
  links: ArtifactShare[];
  words: string;
  may_add: string[];
}

/** What `artifact.access.set` changes: each part named is the whole of that part; a part left out is left as it is. */
export interface ArtifactAccessChange {
  teams?: string[];
  people?: Array<{ subject: string; role: ArtifactShareRole }>;
  organisation?: boolean;
}

/**
 * What `artifact.access.set` answers where the artifact came from a sensitive session whose
 * profile asks a team administrator first: nothing is changed yet, the whole change waits for
 * their yes, and `reason` says so.
 */
export interface ArtifactAccessWaiting {
  waiting: true;
  reason: string;
  share_request?: Record<string, unknown>;
}

/** Whether a change of who reads it waits on a team administrator rather than being made. */
export function accessWaiting(answer: ArtifactAccess | ArtifactAccessWaiting): answer is ArtifactAccessWaiting {
  return (answer as ArtifactAccessWaiting).waiting === true;
}

/** What `artifactAccessWords` reads: the set, its teams by name or by row, and its links. */
export interface ArtifactReaders {
  teams?: ReadonlyArray<string | { name: string }>;
  people?: number | ReadonlyArray<unknown>;
  organisation?: boolean;
  links?: ReadonlyArray<Pick<ArtifactShare, "role" | "state">>;
}

/**
 * Who reads an artifact beside its owner, in one phrase, as the gate and the Access tab say
 * it: "read by the Clinics and Billing teams, 3 people and a view link", "read by the whole
 * organisation", or "read by nobody but its owner". Only live links count.
 */
export function artifactAccessWords(access: ArtifactReaders): string {
  const teams = (access.teams ?? []).map((t) => (typeof t === "string" ? t : t.name));
  const people = typeof access.people === "number" ? access.people : (access.people?.length ?? 0);
  const links = new Map<string, number>();
  for (const l of access.links ?? []) if (l.state === "live") links.set(l.role, (links.get(l.role) ?? 0) + 1);
  const parts = [
    access.organisation ? "the whole organisation" : null,
    teams.length === 1 ? `the ${teams[0]} team` : teams.length > 1 ? `the ${andList(teams)} teams` : null,
    people > 0 ? (people === 1 ? "1 person" : `${people} people`) : null,
    ...[...links.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([role, n]) => (n === 1 ? `a ${role} link` : `${n} ${role} links`)),
  ].filter((p): p is string => p !== null);
  return parts.length === 0 ? "read by nobody but its owner" : `read by ${andList(parts)}`;
}

/**
 * What a change does to who reads it, as the Access tab's Save says it: "added the Billing team
 * and Grace; took off 1 link's holder". `names` gives a person's name for one being added.
 * Empty where it changes nothing.
 */
export function accessChanges(before: Pick<ArtifactAccess, "teams" | "people" | "organisation">, change: ArtifactAccessChange, names: ReadonlyMap<string, string> = new Map()): string {
  const name = (subject: string): string => before.people.find((p) => p.subject === subject)?.display_name || names.get(subject) || subject;
  const had = before.teams.map((t) => t.name);
  const has = change.teams ?? had;
  const roles = new Map(before.people.map((p) => [p.subject, p.role] as const));
  const now = new Map((change.people ?? before.people).map((p) => [p.subject, p.role] as const));
  const added = [...has.filter((t) => !had.includes(t)).map((t) => `the ${t} team`), ...[...now.keys()].filter((s) => !roles.has(s)).map(name)];
  const taken = [...had.filter((t) => !has.includes(t)).map((t) => `the ${t} team`), ...[...roles.keys()].filter((s) => !now.has(s)).map(name)];
  const moved = [...now.entries()].filter(([s, r]) => roles.has(s) && roles.get(s) !== r).map(([s, r]) => `${name(s)} may ${r}`);
  const organisation = change.organisation === undefined || change.organisation === before.organisation ? null : change.organisation ? "the whole organisation reads it" : "the organisation no longer reads it";
  return [added.length > 0 ? `added ${andList(added)}` : null, taken.length > 0 ? `took off ${andList(taken)}` : null, moved.length > 0 ? andList(moved) : null, organisation].filter((p): p is string => p !== null).join("; ");
}

/**
 * The teams a new artifact's sharing menu at the gate offers, in order: those the publication
 * names (the agent's, or where it named none the teams granted the session's profile, which
 * the plane ticks by default), then every other team of the person's, unticked.
 */
export function offeredTeams(publication: Pick<PublicationGate, "teams">, mine: readonly string[]): string[] {
  const named = publication.teams ?? [];
  return [...named, ...mine.filter((t) => !named.includes(t))];
}

/**
 * What a new artifact's sharing menu at the gate answers: who reads it (the organisation
 * switch as `visibility`, and the ticked `teams`, the whole set) and whose it is: the team's
 * only where exactly one team is ticked, since `team` names the one team in `teams`.
 */
export function publishAnswer(choice: { organisation: boolean; teams: string[]; owner: "me" | "team" }): GateAnswer {
  return { visibility: choice.organisation ? "organisation" : "private", teams: choice.teams, owner: choice.owner === "team" && choice.teams.length === 1 ? "team" : "me" };
}

/** What `artifact.get` answers: the artifact, its versions newest first, and its links and people for its owner. */
export interface ArtifactDetail extends Artifact {
  versions: ArtifactVersion[];
  /** For its owner: who reads it, as `artifact.access.get` answers it. Absent from a plane from before the set. */
  access?: Omit<ArtifactAccess, "id" | "may_add">;
  shares?: ArtifactShare[];
  /** For its owner: who it is shared with by name. */
  people?: ArtifactPersonShare[];
  /** For its owner: whether an administrator allows public links, so one may be made. */
  public_links_allowed?: boolean;
  /** How long it and its old versions are kept; absent from a plane from before retention. */
  retention?: ArtifactRetention;
}

/** What `artifact.list` answers. */
export interface ArtifactList {
  /** `false` where an administrator switched artifacts off; the list is then empty. */
  enabled: boolean;
  /** The teams the caller is in, which may read what they publish. */
  teams?: string[];
  /** Who may publish to the whole organisation. */
  publish_organisation: "everyone" | "platform_admins";
  /** Whether an administrator allows public links. */
  public_links?: boolean;
  /** The console's gallery, on the plane. */
  gallery_url?: string | null;
  /** Newest published first. */
  artifacts: Artifact[];
}

/** Which artifacts a list asks for: none given is everything the caller may see. */
export interface ArtifactFilter {
  /** `private` or `organisation`. */
  visibility?: string;
  /** Only those this team reads, by its name. */
  team?: string;
  /** Only the caller's own. */
  mine?: boolean;
  /** Only those a link gave the caller. */
  shared?: boolean;
  /** Only the teams' own: those of the teams the caller is in or administers. */
  teams?: boolean;
}

/** Whether a team owns it, which its members read whatever it is for. */
export function teamOwned(artifact: Pick<Artifact, "owner_team">): boolean {
  return typeof artifact.owner_team === "string" && artifact.owner_team !== "";
}

/**
 * Whose it is, in words: the team that owns it, with "you are a member" where the caller
 * is one; "you" for the caller's own; otherwise the person who published it.
 */
export function ownerWords(artifact: Pick<Artifact, "owner" | "owner_team" | "mine">): string {
  if (teamOwned(artifact)) return `the ${artifact.owner_team} team${artifact.mine ? " (you are a member)" : ""}`;
  if (artifact.mine) return "you";
  return artifact.owner?.display_name || artifact.owner?.subject || "somebody";
}

/**
 * The organisation switch in words: "the whole organisation" for `organisation`, "only you"
 * for `private`. A `team:<name>` from a record written before the set is that one team.
 */
export function visibilityWords(visibility: string): string {
  if (visibility === "private") return "only you";
  if (visibility === "organisation") return "the whole organisation";
  if (visibility.startsWith("team:")) return `the ${visibility.slice("team:".length)} team`;
  return visibility;
}

/** A one-time link to open an artifact on its host, good for `expires_in` seconds. */
export interface ArtifactTicket {
  url: string;
  expires_in: number;
}

/** A file to publish, its bytes in base64. */
export interface ArtifactUpload {
  path: string;
  bytes: string;
  content_type?: string;
}

/** A new version: its files, the version an edit was made on (whose other files it keeps), and a note. */
export interface ArtifactPut {
  files: ArtifactUpload[];
  base?: number;
  note?: string;
  title?: string;
}

/** A publish: a new artifact, or with `id` the next version of one; whose it is by `owner`. */
export interface ArtifactPublish {
  title: string;
  kind: ArtifactKind;
  /** `private` (the default) or `organisation`; a new version keeps its own, so none is sent with `id`. */
  visibility?: string;
  /** A new one's: the teams that read it. A new version keeps who reads it. */
  teams?: string[];
  files: ArtifactUpload[];
  /** Whose the new artifact is; left out, the publisher's. */
  owner?: ArtifactOwner;
  id?: string;
  note?: string;
  session_id?: string;
  /** A picture of this version for its gallery card: PNG, JPEG or WebP, at most 256 KiB. */
  thumbnail?: ArtifactThumbnail;
}

/** A card's picture as a publish sends it, its bytes in base64. */
export interface ArtifactThumbnail {
  content_type: "image/png" | "image/jpeg" | "image/webp";
  bytes: string;
}

/** One text file of a version, for an editor. */
export interface ArtifactText {
  id: string;
  version: number;
  path: string;
  content_type: string;
  text: string;
}

/** A new link: its token and address, shown this once. */
export interface ArtifactNewLink {
  token: string;
  url: string;
  share: ArtifactShare;
}

/** The base64 of a string's UTF-8, as a file's bytes travel. */
export function textBytes(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

/** Who an artifact is for, as a gallery groups them: everyone, a team's people, a link's or a name's, or its owner alone. */
export type ArtifactAudience = "everyone" | "team" | "shared" | "private";

/**
 * Which gallery group it is under, as the plane's `scope` says per row: `shared`, a team of the
 * caller's (`team:<name>`), `organisation`, `private`; the caller's own that others read
 * (`mine`) is under the widest that does: the organisation, else its teams, else only them.
 */
export function audienceOf(artifact: Artifact): ArtifactAudience {
  const scope = artifact.scope;
  if (scope === "shared") return "shared";
  if (scope === "organisation") return "everyone";
  if (scope?.startsWith("team:")) return "team";
  if (scope === "private") return "private";
  if (artifact.organisation === true || artifact.visibility === "organisation") return "everyone";
  return (artifact.teams?.length ?? 0) > 0 ? "team" : "private";
}

/** The teams an artifact is under in the gallery's team row: the caller's one its `scope` names, else every team that reads it. */
export function audienceTeams(artifact: Artifact): string[] {
  if (artifact.scope?.startsWith("team:")) return [artifact.scope.slice("team:".length)];
  return artifact.teams ?? [];
}

/** The person's own calls on artifacts, one per method. */
export class ArtifactApi {
  constructor(private readonly rpc: Rpc) {}

  list(filter: ArtifactFilter = {}): Promise<ArtifactList> {
    return this.rpc<ArtifactList>("artifact.list", filter);
  }

  get(id: string): Promise<ArtifactDetail> {
    return this.rpc<ArtifactDetail>("artifact.get", { id });
  }

  /** Ask for a link to open it, or one version of it, at the moment it is opened. */
  open(id: string, version?: number): Promise<ArtifactTicket> {
    return this.rpc<ArtifactTicket>("artifact.open", version === undefined ? { id } : { id, version });
  }

  delete(id: string): Promise<{ deleted: boolean; id: string }> {
    return this.rpc<{ deleted: boolean; id: string }>("artifact.delete", { id });
  }

  /** A new version at the same address: its owner's, or an edit link's holder's. */
  put(id: string, put: ArtifactPut): Promise<ArtifactDetail> {
    return this.rpc<ArtifactDetail>("artifact.put", { id, ...put });
  }

  /** Version `version`'s files again, as the next version. */
  rollback(id: string, version: number): Promise<ArtifactDetail> {
    return this.rpc<ArtifactDetail>("artifact.rollback", { id, version });
  }

  /** Pin `version` as the one its address serves, or null for the newest. The owner's. */
  pin(id: string, version: number | null): Promise<ArtifactDetail> {
    return this.rpc<ArtifactDetail>("artifact.pin", { id, version });
  }

  /** One text file of a version (the current one if none), for an editor. */
  read(id: string, path: string, version?: number): Promise<ArtifactText> {
    return this.rpc<ArtifactText>("artifact.read", version === undefined ? { id, path } : { id, path, version });
  }

  /** An address on the artifacts host that shows `text` as `path` over version `base`, for an hour. */
  preview(id: string, base: number, path: string, text: string): Promise<ArtifactTicket> {
    return this.rpc<ArtifactTicket>("artifact.preview", { id, base, path, text });
  }

  /** A link: `view`, `comment` or `edit`, an expiry, and `public` where an administrator allows them. */
  share(id: string, link: { role: ArtifactShareRole; expires?: string; public?: boolean }): Promise<ArtifactNewLink> {
    return this.rpc<ArtifactNewLink>("artifact.share", { id, ...link });
  }

  /** Who reads it: its owner's to read, and a platform admin's. */
  getAccess(id: string): Promise<ArtifactAccess> {
    return this.rpc<ArtifactAccess>("artifact.access.get", { id });
  }

  /**
   * Change who reads it, its owner's alone: each part named is the whole of that part, and the
   * plane applies the difference, auditing each team or person added or taken off; no version
   * is made. Answers who reads it now, or that the change waits on a team administrator.
   */
  setAccess(id: string, change: ArtifactAccessChange): Promise<ArtifactAccess | ArtifactAccessWaiting> {
    return this.rpc<ArtifactAccess | ArtifactAccessWaiting>("artifact.access.set", { id, ...change });
  }

  /** The names of every team granted a profile, for an artifact's sharing menu. */
  profileTeams(profile: string): Promise<{ profile: string; teams: string[] }> {
    return this.rpc<{ profile: string; teams: string[] }>("profile.teams", { profile });
  }

  /**
   * The share picker's search: people whose name, email or subject starts with `query`, among
   * those who share a team with the caller and, with `artifact` (one of theirs), those the
   * profile its session ran on covers.
   */
  searchPeople(query: string, opts: { artifact?: string; limit?: number } = {}): Promise<{ people: Person[] }> {
    return this.rpc<{ people: Person[] }>("people.search", { query, ...opts });
  }

  /** Share it with one person by name at `role`, no link made; naming them again changes the role. The owner's. */
  sharePerson(id: string, person: string, role: ArtifactShareRole): Promise<{ id: string; person: ArtifactPersonShare }> {
    return this.rpc<{ id: string; person: ArtifactPersonShare }>("artifact.share", { id, person, role });
  }

  /** Its thread, oldest first, for whoever may open it. */
  comments(id: string): Promise<ArtifactThread> {
    return this.rpc<ArtifactThread>("artifact.comments", { id });
  }

  /** A comment in its thread, by whoever holds comment, edit or owner on it. */
  comment(id: string, body: string): Promise<{ id: string; comment: ArtifactComment }> {
    return this.rpc<{ id: string; comment: ArtifactComment }>("artifact.comment", { id, body });
  }

  /** Delete a comment from its thread: its author, an owner, or whoever may take the artifact down. */
  deleteComment(id: string, comment: string): Promise<{ id: string; comment: string; deleted: boolean }> {
    return this.rpc<{ id: string; comment: string; deleted: boolean }>("artifact.comment.delete", { id, comment });
  }

  /** A comment's text replaced by its author, marked edited. */
  editComment(id: string, comment: string, body: string): Promise<{ id: string; comment: ArtifactComment }> {
    return this.rpc<{ id: string; comment: ArtifactComment }>("artifact.comment.edit", { id, comment, body });
  }

  /** Revoke a link by its id, or one person from every link by their subject. */
  unshare(id: string, which: { share: string } | { person: string }): Promise<{ revoked: boolean }> {
    return this.rpc<{ revoked: boolean }>("artifact.unshare", { id, ...which });
  }

  /** Spend a link's token as this person: its role from now, and a link that opens it. */
  redeem(token: string): Promise<{ id: string; role: "view" | "edit"; url: string }> {
    return this.rpc<{ id: string; role: "view" | "edit"; url: string }>("artifact.redeem", { token });
  }

  /** The owner's switch for this artifact's public links. */
  publicLinks(id: string, enabled: boolean): Promise<ArtifactDetail> {
    return this.rpc<ArtifactDetail>("artifact.public", { id, enabled });
  }

  /** A new artifact, or with `id` the next version of one; `owner` says whose a new one is. */
  publish(publish: ArtifactPublish): Promise<Artifact> {
    return this.rpc<Artifact>("artifact.publish", publish);
  }

  /**
   * Give it to a team the owner is in (`team:<name>`), or take it back from the team that
   * owns it (`me`, for an admin of that team or a platform admin: the caller becomes its
   * owner). Refused `forbidden` for anybody else.
   */
  transfer(id: string, to: ArtifactTransferTo): Promise<ArtifactDetail> {
    return this.rpc<ArtifactDetail>("artifact.transfer", { id, to });
  }

  /** Keep it at the top of the caller's own gallery (`true`), or let it go (`false`): anybody who may open it, for themselves. */
  keep(id: string, on: boolean): Promise<ArtifactDetail> {
    return this.rpc<ArtifactDetail>("artifact.keep", { id, on });
  }
}
