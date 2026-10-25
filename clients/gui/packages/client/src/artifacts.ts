// Artifacts: what a person or their agents published to the plane's artifacts host, as any
// signed-in person's client asks for them (`artifact.*`), and never an administrative call.
//
// A client reads the list, one artifact with its versions, and asks for a link to open one
// at the moment a person opens it: the link is one-time and short-lived, and the artifact
// is shown by the artifacts host in a tab of its own. Nothing here reads an artifact's
// files, so no client draws an artifact's content inside itself.

type Rpc = <T = unknown>(method: string, params?: unknown) => Promise<T>;

export type ArtifactKind = "html" | "markdown" | "file";

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

/** An artifact as `artifact.list` answers it, for this caller. */
export interface Artifact {
  id: string;
  title: string;
  kind: ArtifactKind;
  /** `organisation`, or `profile:<name>`. */
  visibility: string;
  owner: ArtifactPerson;
  /** Whether it is the caller's own. */
  mine: boolean;
  origin: ArtifactOrigin;
  team: string | null;
  version: number;
  bytes: number;
  url: string;
  created_at: string;
  published_at: string;
  /** Whether this caller may delete it: its owner, or a platform admin taking it down. */
  may_delete: boolean;
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
  url: string;
}

/** What `artifact.get` answers: the artifact, and its versions newest first. */
export interface ArtifactDetail extends Artifact {
  versions: ArtifactVersion[];
}

/** What `artifact.list` answers. */
export interface ArtifactList {
  /** `false` where an administrator switched artifacts off; the list is then empty. */
  enabled: boolean;
  /** The profiles the caller is covered by. */
  profiles: string[];
  /** Who may publish to the whole organisation. */
  publish_organisation: "everyone" | "platform_admins";
  /** Newest published first. */
  artifacts: Artifact[];
}

/** Which artifacts a list asks for: none given is everything the caller may see. */
export interface ArtifactFilter {
  /** `organisation`, or `profile:<name>`. */
  visibility?: string;
  /** Only the caller's own. */
  mine?: boolean;
}

/** A one-time link to open an artifact on its host, good for `expires_in` seconds. */
export interface ArtifactTicket {
  url: string;
  expires_in: number;
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
}
