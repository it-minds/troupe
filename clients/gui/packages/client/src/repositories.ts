// The GitHub repositories a pod session holds (troupe #1207), in the words both web apps
// say them: the one it was created on at the workspace's root, every other one in a
// directory of its own, each with its own branch and draft pull request. A new session on
// a profile with `spec.github` is offered the team's listed repositories; its owner
// attaches more while it runs and takes them off (`session.repository.add`, `.remove`).

import { TroupeRpcError } from "./connection.js";
import type { RepositoryName, SessionRepository } from "./plane.js";
import { ErrorCodes } from "./types.js";
import { errorText } from "./words.js";

/** A repository's `owner/name`. */
export function repositoryName(r: { owner: string; name: string }): string {
  return `${r.owner}/${r.name}`;
}

/**
 * Every repository a row says it holds: `repositories`, or a plane from before the list's
 * one `repository` with the row's `github` record, at the workspace's root.
 */
export function repositoriesOf(row: unknown): SessionRepository[] {
  const r = (row ?? {}) as { repositories?: unknown; repository?: unknown; github?: unknown };
  if (Array.isArray(r.repositories)) return r.repositories.filter(isRepository);
  if (isRepository(r.repository)) {
    return [{ ...r.repository, path: ".", github: (r.github as SessionRepository["github"]) ?? null }];
  }
  return [];
}

function isRepository(x: unknown): x is SessionRepository {
  const r = x as { owner?: unknown; name?: unknown } | null;
  return typeof r?.owner === "string" && typeof r?.name === "string";
}

/** A row's repositories in a few words: the first, and how many more. Empty for none. */
export function repositoriesSummary(names: readonly string[]): string {
  if (names.length === 0) return "";
  return names.length === 1 ? names[0]! : `${names[0]} +${names.length - 1} more`;
}

/** Where a repository's clone is in the workspace, in words. */
export function repositoryWhere(r: Pick<SessionRepository, "path">): string {
  return !r.path || r.path === "." ? "at the workspace's root" : `in ${r.path}/`;
}

/** What the session did on one repository, in a line: its pull request, or its branch, or nothing yet. */
export function repositoryWork(r: Pick<SessionRepository, "github">): string {
  const g = r.github;
  if (!g?.branch) return "nothing pushed yet";
  const pr = g.pull_request ? `draft #${g.pull_request.number} from ${g.branch}` : `${g.branch} at ${(g.commit ?? "").slice(0, 7)}`;
  return g.stopped ? `${pr}, stopped: ${g.stopped.reason}` : pr;
}

/**
 * What a person typed for a repository, read: `owner/name`, with `@ref` for a branch or tag
 * other than the default. Null where it is not one.
 */
export function readRepository(text: string): { owner: string; name: string; ref: string | null } | null {
  const m = /^\s*([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))\/([A-Za-z0-9._-]{1,100})(?:@(\S+))?\s*$/.exec(text);
  if (!m || m[2] === "." || m[2] === "..") return null;
  return { owner: m[1]!, name: m[2]!, ref: m[3] ?? null };
}

/** A chosen repository as the plane takes it: `owner/name`, or `{owner, name, ref}` with a ref. */
export function repositoryParam(r: { owner: string; name: string; ref?: string | null }): RepositoryName {
  return r.ref ? { owner: r.owner, name: r.name, ref: r.ref } : repositoryName(r);
}

/**
 * What a team lists, split: the repositories it names, which a chooser offers, and the
 * owners it lists every repository of (`owner/*`), for which a person types the name.
 */
export function listedRepositories(listed: readonly string[] | null | undefined): { named: string[]; owners: string[] } {
  const named: string[] = [];
  const owners: string[] = [];
  for (const entry of listed ?? []) {
    const [owner, name] = entry.split("/");
    if (!owner || !name) continue;
    if (name === "*") owners.push(owner);
    else named.push(`${owner}/${name}`);
  }
  return { named, owners };
}

/** How many a new session may still take, as the chooser says it. */
export function repositoriesLeft(chosen: number, max: number): string {
  const left = Math.max(max - chosen, 0);
  return left === 0 ? `That is as many as a session here holds (${max}).` : `A session here holds up to ${max}; ${left} more may be added.`;
}

/** The line a session's transcript shows for `session_repository_changed`. */
export function repositoryChangedText(data: Record<string, unknown>): string {
  const name = typeof data["repository"] === "string" ? data["repository"] : "a repository";
  const who = typeof data["by_name"] === "string" && data["by_name"] ? ` by ${data["by_name"]}` : "";
  const where = typeof data["path"] === "string" ? ` ${repositoryWhere({ path: data["path"] })}` : "";
  switch (data["action"]) {
    case "attached":
      return `${name} attached${who}, cloned${where}`;
    case "detached":
      return `${name} taken off${who}; its directory is gone`;
    case "failed":
      return `${name} could not be cloned: ${typeof data["reason"] === "string" ? data["reason"] : "the pod did not say why"}`;
    default:
      return `${name} changed`;
  }
}

/** Why the plane would not attach a repository or take one off, for the panel's line. */
export function repositoryRefusal(e: unknown, attach: boolean): string {
  const lead = attach ? "It was not attached" : "It was not taken off";
  if (e instanceof TroupeRpcError && e.code === ErrorCodes.method_not_found) return `${lead}: this plane does not attach repositories to a running session yet.`;
  if (e instanceof TroupeRpcError && e.code === ErrorCodes.forbidden && typeof e.data?.["reason"] !== "string") {
    return `${lead}: only the session's owner attaches a repository or takes one off.`;
  }
  if (e instanceof TroupeRpcError && e.data?.["reason"] === "busy") {
    const detail = typeof e.data["detail"] === "string" ? e.data["detail"] : "a push on it is going";
    return `${lead}: ${detail}.`;
  }
  return `${lead}: ${errorText(e)}.`;
}
