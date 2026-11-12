// What is a person's own on the plane, their memory and their artifacts, as their app reads
// and changes it: through this computer's daemon, which sends each call on as them, or
// straight to the plane they are signed in to. The two answer alike, so a screen is handed
// one of them and does not ask which.
//
// The daemon adds to the plane's answers what it knows (`plane_url`) and reshapes one of
// them: `me.memory` is the plane's signed answer, the person's own as `user` and the levels
// above it as `documents`, and the daemon hands a client the person's own with the levels
// beside it (`Troupe.Gateway.Memory.own/1`). `PlaneOwn` does the same here, so a screen
// reads one shape whichever answered. What only this computer holds (where its copy of the
// memory stands, a `config.changed`, a publication of local files) stays the daemon's.

import { TroupeRpcError } from "./connection.js";
import { planeReadsOnlyText } from "./daemon.js";
import type { EntriesOrText } from "./daemon.js";
import type { ArtifactDetail, ArtifactFilter, ArtifactList, ArtifactNewLink, ArtifactTicket, ArtifactTransferTo } from "./artifacts.js";
import type { MemoryDocument, MemoryPreview, MemorySaved } from "./admin.js";
import { renderEntries } from "./entries.js";
import type { MemoryEntry, MemoryInEffect } from "./entries.js";
import type { OwnMemory, OwnMemoryHistory, OwnMemorySaved } from "./instructions.js";

type Rpc = <T = unknown>(method: string, params?: unknown) => Promise<T>;
type Scope = "organisation" | "team" | "profile";
type Drafts = Array<Pick<MemoryEntry, "topic" | "body" | "heading">>;

/** The person's own memory and artifacts, read and changed as them. `DaemonClient` is one; `PlaneOwn` is the other. */
export interface OwnPlane {
  ownMemory(opts?: { blame?: boolean }): Promise<OwnMemory>;
  ownMemoryHistory(params?: { version?: number; against?: number }): Promise<OwnMemoryHistory>;
  rollbackOwnMemory(to: number, version: number): Promise<OwnMemorySaved>;
  putOwnMemoryEntries(entries: Drafts, version: number): Promise<OwnMemorySaved>;
  memoryInEffect(params?: { team?: string; profile?: string }): Promise<MemoryInEffect>;
  levelMemory(scope: Scope, name: string | null): Promise<MemoryDocument>;
  previewLevelMemory(scope: Scope, name: string | null, doc: EntriesOrText): Promise<MemoryPreview>;
  putLevelMemory(scope: Scope, name: string | null, doc: EntriesOrText, version: number): Promise<MemorySaved>;
  artifacts(filter?: ArtifactFilter): Promise<ArtifactList & { plane_url?: string }>;
  artifact(id: string): Promise<ArtifactDetail>;
  openArtifact(id: string, version?: number): Promise<ArtifactTicket>;
  shareArtifact(id: string, role?: "view" | "edit"): Promise<ArtifactNewLink>;
  unshareArtifact(id: string, which: { share: string } | { person: string }): Promise<{ revoked: boolean }>;
  rollbackArtifact(id: string, version: number): Promise<ArtifactDetail>;
  moveArtifact(id: string, base: number, visibility: string): Promise<ArtifactDetail>;
  pinArtifact(id: string, version: number | null): Promise<ArtifactDetail>;
  transferArtifact(id: string, to: ArtifactTransferTo): Promise<ArtifactDetail>;
}

/** The order the levels come in, lowest first, as the plane and the daemon sort them. */
const SCOPES = ["organisation", "team", "profile", "user"];

/** A level as the plane answers it in `me.memory`'s `documents`. */
interface PlaneDocument {
  scope: string;
  name?: string | null;
  version: number;
  hash?: string;
  updated_at?: string | null;
  text: string;
  entries?: MemoryEntry[];
}

/** The plane's `me.memory`, asked with `entries`: the person's own, the levels above it, their teams, the organisation and their roles. */
interface PlaneMemory {
  user?: Omit<OwnMemory, "documents" | "organisation" | "roles">;
  documents?: PlaneDocument[];
  teams?: string[];
  organisation?: { name: string } | null;
  roles?: { platform_admin?: unknown; team_admin?: unknown } | null;
}

/**
 * The person's own memory and artifacts asked of the plane they are signed in to, as the
 * console asks them: by the sign-in's own `rpc`, so a desktop app's every request still goes
 * through the one gate its sign-in is built with.
 */
export class PlaneOwn implements OwnPlane {
  constructor(
    private readonly rpc: Rpc,
    readonly planeUrl: string,
  ) {}

  /** The answer with `plane_url`, as the daemon adds it. */
  private async ask<T extends object>(method: string, params: unknown = {}): Promise<T> {
    const answer = await this.rpc<T>(method, params);
    return { ...answer, plane_url: this.planeUrl };
  }

  async ownMemory(opts: { blame?: boolean } = {}): Promise<OwnMemory> {
    const answer = await this.rpc<PlaneMemory>("me.memory", { entries: true, ...(opts.blame ? { blame: true } : {}) });
    return ownOf(answer, this.planeUrl);
  }

  ownMemoryHistory(params: { version?: number; against?: number } = {}): Promise<OwnMemoryHistory> {
    return this.ask<OwnMemoryHistory>("me.memory.history", { ...params });
  }

  rollbackOwnMemory(to: number, version: number): Promise<OwnMemorySaved> {
    return this.ask<OwnMemorySaved>("me.memory.rollback", { to, version });
  }

  putOwnMemoryEntries(entries: Drafts, version: number): Promise<OwnMemorySaved> {
    return entriesOrText(entries, (doc) => this.ask<OwnMemorySaved>("me.memory.put", { ...doc, version }));
  }

  memoryInEffect(params: { team?: string; profile?: string } = {}): Promise<MemoryInEffect> {
    return this.ask<MemoryInEffect>("memory.in_effect", { ...params });
  }

  levelMemory(scope: Scope, name: string | null): Promise<MemoryDocument> {
    return this.ask<MemoryDocument>("admin.memory.get", name === null ? { scope } : { scope, name });
  }

  previewLevelMemory(scope: Scope, name: string | null, doc: EntriesOrText): Promise<MemoryPreview> {
    const preview = (sent: EntriesOrText): Promise<MemoryPreview> => this.ask<MemoryPreview>("admin.memory.preview", { scope, ...(name === null ? {} : { name }), ...sent });
    return "entries" in doc ? entriesOrText(doc.entries, preview) : preview(doc);
  }

  putLevelMemory(scope: Scope, name: string | null, doc: EntriesOrText, version: number): Promise<MemorySaved> {
    const put = (sent: EntriesOrText): Promise<MemorySaved> => this.ask<MemorySaved>("admin.memory.put", { scope, ...(name === null ? {} : { name }), ...sent, version });
    return "entries" in doc ? entriesOrText(doc.entries, put) : put(doc);
  }

  artifacts(filter: ArtifactFilter = { mine: true }): Promise<ArtifactList & { plane_url?: string }> {
    return this.ask<ArtifactList>("artifact.list", { ...filter });
  }

  artifact(id: string): Promise<ArtifactDetail> {
    return this.ask<ArtifactDetail>("artifact.get", { id });
  }

  openArtifact(id: string, version?: number): Promise<ArtifactTicket> {
    return this.ask<ArtifactTicket>("artifact.open", version === undefined ? { id } : { id, version });
  }

  shareArtifact(id: string, role: "view" | "edit" = "view"): Promise<ArtifactNewLink> {
    return this.ask<ArtifactNewLink>("artifact.share", { id, role });
  }

  unshareArtifact(id: string, which: { share: string } | { person: string }): Promise<{ revoked: boolean }> {
    return this.ask<{ revoked: boolean }>("artifact.unshare", { id, ...which });
  }

  rollbackArtifact(id: string, version: number): Promise<ArtifactDetail> {
    return this.ask<ArtifactDetail>("artifact.rollback", { id, version });
  }

  moveArtifact(id: string, base: number, visibility: string): Promise<ArtifactDetail> {
    return this.ask<ArtifactDetail>("artifact.put", { id, base, visibility });
  }

  pinArtifact(id: string, version: number | null): Promise<ArtifactDetail> {
    return this.ask<ArtifactDetail>("artifact.pin", { id, version });
  }

  transferArtifact(id: string, to: ArtifactTransferTo): Promise<ArtifactDetail> {
    return this.ask<ArtifactDetail>("artifact.transfer", { id, to });
  }
}

/**
 * The person's own with the levels above it beside it, as the daemon hands it a client: every
 * level but theirs, each team of theirs with no document among them, empty, lowest first; the
 * organisation's name; and the roles, nobody's where the plane says none. A plane that
 * answers no `user` is one from before a person's own memory.
 */
function ownOf(answer: PlaneMemory, planeUrl: string): OwnMemory {
  if (!answer.user) throw new TroupeRpcError("me.memory", { code: -32601, message: "method_not_found", data: { reason: "the plane keeps no memory of a person's own; it is from before it" } });
  const above = (answer.documents ?? [])
    .filter((d) => d.scope !== "user")
    .map((d) => ({ scope: d.scope, name: d.name ?? null, version: d.version, ...(d.hash ? { hash: d.hash } : {}), updated_at: d.updated_at ?? null, text: d.text, entries: d.entries ?? [] }));
  const named = new Set(above.filter((d) => d.scope === "team").map((d) => d.name));
  const empty = (answer.teams ?? []).filter((n) => !named.has(n)).map((name) => ({ scope: "team", name, version: 0, updated_at: null, text: "", entries: [] as MemoryEntry[] }));
  const documents = [...above, ...empty].sort((a, b) => SCOPES.indexOf(a.scope) - SCOPES.indexOf(b.scope) || (a.name ?? "").localeCompare(b.name ?? ""));
  const roles = answer.roles ?? {};
  return {
    ...answer.user,
    entries: answer.user.entries ?? [],
    plane_url: planeUrl,
    documents,
    organisation: answer.organisation ?? null,
    roles: { platform_admin: roles.platform_admin === true, team_admin: Array.isArray(roles.team_admin) ? roles.team_admin.filter((t): t is string => typeof t === "string") : [] },
  };
}

/** A save or preview as entries, sent again as text to a plane from before entries, as `DaemonClient` does. */
async function entriesOrText<T>(entries: Drafts, send: (doc: EntriesOrText) => Promise<T>): Promise<T> {
  const sent = entries.map((e) => ({ topic: e.topic, body: e.body, ...(e.heading === false ? { heading: false } : {}) }));
  try {
    return await send({ entries: sent });
  } catch (e) {
    if (!planeReadsOnlyText(e)) throw e;
    return send({ text: renderEntries(sent) });
  }
}
