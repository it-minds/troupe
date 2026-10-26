// Artifacts: what a person or their agents published to the plane's artifacts host, as any
// signed-in person's client asks for them (`artifact.*`), and never an administrative call.
//
// A client reads the list, one artifact with its versions, and asks for a link to open one
// at the moment a person opens it: the link is one-time and short-lived, and the artifact
// is shown by the artifacts host in a tab of its own. A client never draws an artifact's
// content inside itself: an editor reads one text file of it (`artifact.read`) to change it,
// and its preview is an address on the artifacts host (`artifact.preview`) that the client
// frames, sandboxed, as it frames nothing else.

type Rpc = <T = unknown>(method: string, params?: unknown) => Promise<T>;

export type ArtifactKind = "html" | "markdown" | "file";

/** What a person is to an artifact: its owner, or what a link or who it is for gives them. */
export type ArtifactRole = "owner" | "edit" | "view";

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
 * The gallery tab an artifact is under for this caller, as the plane says it: `mine`,
 * `private` (theirs, which only they open), `organisation`, `team:<name>`,
 * `profile:<name>`, or `shared` (a link gave it them). A client tabs by it and works out
 * nobody's membership itself.
 */
export type ArtifactScope = string;

/** An artifact as `artifact.list` answers it, for this caller. */
export interface Artifact {
  id: string;
  title: string;
  kind: ArtifactKind;
  /** `private`, `organisation`, `team:<name>` or `profile:<name>`. */
  visibility: string;
  /** Which tab it is under for this caller; absent from a plane before teams. */
  scope?: ArtifactScope;
  owner: ArtifactPerson;
  /** Whether it is the caller's own. */
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
  created_at: string;
  published_at: string;
  /** Whether this caller may delete it: its owner, or a platform admin taking it down. */
  may_delete: boolean;
  /** Whether this caller may publish a new version of it: its owner, or an edit link's holder. */
  may_edit?: boolean;
  /** The owner's switch for its public links. */
  public_links?: boolean;
  /** Whether a public link opens it now. */
  public?: boolean;
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
  url: string;
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
  role: "view" | "edit";
  public: boolean;
  state: "live" | "expired" | "revoked" | "switched off";
  expires_at: string | null;
  revoked_at: string | null;
  created_by: string;
  created_at: string;
  used_by: ArtifactLinkUse[];
}

/** What `artifact.get` answers: the artifact, its versions newest first, and its links for its owner. */
export interface ArtifactDetail extends Artifact {
  versions: ArtifactVersion[];
  shares?: ArtifactShare[];
  /** For its owner: whether an administrator allows public links, so one may be made. */
  public_links_allowed?: boolean;
}

/** What `artifact.list` answers. */
export interface ArtifactList {
  /** `false` where an administrator switched artifacts off; the list is then empty. */
  enabled: boolean;
  /** The profiles the caller is covered by. */
  profiles: string[];
  /** The teams the caller is in, which they may publish to as `team:<name>`. */
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
  /** `private`, `organisation`, `team:<name>` or `profile:<name>`. */
  visibility?: string;
  /** Only the caller's own. */
  mine?: boolean;
  /** Only those a link gave the caller. */
  shared?: boolean;
  /** Only the teams' own: those of the teams the caller is in or administers. */
  teams?: boolean;
}

/** Who may open an artifact, in words: what every client of a person's says of a visibility. */
export function visibilityWords(visibility: string): string {
  if (visibility === "private") return "only you";
  if (visibility === "organisation") return "the whole organisation";
  if (visibility.startsWith("team:")) return `the ${visibility.slice("team:".length)} team`;
  if (visibility.startsWith("profile:")) return `the ${visibility.slice("profile:".length)} profile's people`;
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

  /** A link: `view` or `edit`, an expiry, and `public` where an administrator allows them. */
  share(id: string, link: { role: "view" | "edit"; expires?: string; public?: boolean }): Promise<ArtifactNewLink> {
    return this.rpc<ArtifactNewLink>("artifact.share", { id, ...link });
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
}
