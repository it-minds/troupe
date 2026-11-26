// A pod session's GitHub repositories (troupe #1207): chosen on the new-session screen from
// the repositories the session's team lists, when its profile allows GitHub, and in the
// session's Backstage, where its owner attaches another while it runs and takes one off.
// What a session does on each, its branch and its draft pull request, is said per
// repository, since each has its own.

import { useRef, useState } from "react";
import type { JSX } from "react";
import { listedRepositories, readRepository, repositoriesLeft, repositoryName, repositoryWhere, repositoryWork } from "@troupe/client";
import type { SessionRepository } from "@troupe/client";

/** A repository chosen for a new session, or to attach: `owner/name` and the branch or tag, the default where none. */
export interface ChosenRepository {
  owner: string;
  name: string;
  ref: string | null;
}

/** The repositories a person's teams list, the named ones offered and `owner/*` typed. */
export function teamRepositories(teams: readonly unknown[] | null | undefined, team: string | null): string[] {
  const rows = (teams ?? []).filter((t): t is { name?: unknown; repositories?: unknown } => typeof t === "object" && t !== null);
  const of = team ? rows.filter((t) => t.name === team) : rows;
  return [...new Set(of.flatMap((t) => (Array.isArray(t.repositories) ? t.repositories.filter((r): r is string => typeof r === "string") : [])))];
}

/**
 * The chooser: every repository the team names, picked and unpicked in place, and a field
 * for one of an owner whose every repository it lists, or for a branch or tag other than
 * the default (`owner/name@ref`). As many as `max`.
 */
export function RepositoryChooser({
  listed,
  chosen,
  max,
  onChange,
  held = [],
}: {
  listed: readonly string[];
  chosen: readonly ChosenRepository[];
  max: number;
  onChange: (next: ChosenRepository[]) => void;
  /** What the session holds already, which is not offered again. */
  held?: readonly string[];
}): JSX.Element {
  const [typed, setTyped] = useState("");
  // Read from the field itself, so a name pasted and added at once is the one added.
  const field = useRef<HTMLInputElement>(null);
  const [typedError, setTypedError] = useState<string | null>(null);
  const { named, owners } = listedRepositories(listed);
  const isChosen = (full: string): boolean => chosen.some((c) => repositoryName(c).toLowerCase() === full.toLowerCase());
  const full = chosen.length >= max;
  // The named ones, and any typed one chosen, which is unchosen the same way.
  const typedChosen = chosen.map(repositoryName).filter((c) => !named.some((n) => n.toLowerCase() === c.toLowerCase()));
  const offered = [...named, ...typedChosen].filter((n) => !held.some((h) => h.toLowerCase() === n.toLowerCase()));
  const toggle = (name: string): void => {
    if (isChosen(name)) onChange(chosen.filter((c) => repositoryName(c).toLowerCase() !== name.toLowerCase()));
    else if (!full) {
      const r = readRepository(name);
      if (r) onChange([...chosen, r]);
    }
  };
  const add = (): void => {
    const r = readRepository(field.current?.value ?? typed);
    if (!r) {
      setTypedError("Type it as owner/name, with @branch for one other than the default.");
      return;
    }
    const rest = chosen.filter((c) => repositoryName(c).toLowerCase() !== repositoryName(r).toLowerCase());
    if (rest.length >= max) {
      setTypedError(repositoriesLeft(rest.length, max));
      return;
    }
    onChange([...rest, r]);
    setTyped("");
    setTypedError(null);
  };

  if (listed.length === 0) {
    return <p className="note">Your team lists no GitHub repositories yet. A team admin adds them on the team’s page in the console.</p>;
  }
  return (
    <>
      {offered.map((n) => {
        const c = chosen.find((x) => repositoryName(x).toLowerCase() === n.toLowerCase());
        return (
          <button key={n} type="button" className="ns-opt" aria-pressed={Boolean(c)} disabled={!c && full} onClick={() => toggle(n)}>
            <span className="ns-opt-dot" aria-hidden="true" />
            <span className="ns-opt-body">
              <span className="ns-opt-head">
                <span className="ns-opt-label mono">{n}</span>
                {c && <span className="ns-opt-tag">{c.ref ?? "DEFAULT BRANCH"}</span>}
              </span>
            </span>
          </button>
        );
      })}
      <div className="ns-repo-typed">
        <label className="inline ns-small">
          <span>{owners.length > 0 ? `Another of ${owners.map((o) => `${o}/`).join(", ")}, or a branch` : "A branch other than the default"}</span>
          <input
            type="text"
            ref={field}
            value={typed}
            spellCheck={false}
            aria-label="Repository, as owner/name@branch"
            placeholder={`${owners[0] ?? named[0]?.split("/")[0] ?? "owner"}/name@branch`}
            onChange={(e) => setTyped(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                add();
              }
            }}
          />
        </label>
        <button type="button" onClick={add}>
          Add
        </button>
      </div>
      {typedError && <p className="note">{typedError}</p>}
      <p className="note">{repositoriesLeft(chosen.length, max)}</p>
    </>
  );
}

/**
 * A running or sleeping pod session's repositories in its Backstage: where each clone is
 * and what the session did there; Attach and Take off for its owner, the plane's sentence
 * where it would not.
 */
export function SessionRepositories({
  repositories,
  listed,
  owner,
  onAttach,
  onTakeOff,
}: {
  repositories: readonly SessionRepository[];
  listed: readonly string[];
  owner: boolean;
  /** Attach one; answers the plane's refusal in words, or null once it is done. */
  onAttach?: ((r: ChosenRepository) => Promise<string | null>) | undefined;
  onTakeOff?: ((name: string) => Promise<string | null>) | undefined;
}): JSX.Element | null {
  const [attaching, setAttaching] = useState(false);
  const [picked, setPicked] = useState<ChosenRepository[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  if (repositories.length === 0 && !(owner && onAttach && listed.length > 0)) return null;
  const held = repositories.map(repositoryName);

  const run = async (act: () => Promise<string | null>): Promise<boolean> => {
    setBusy(true);
    setError(null);
    const said = await act();
    setBusy(false);
    setError(said);
    return said === null;
  };

  return (
    <section aria-label="Repositories">
      <h3>Repositories</h3>
      {repositories.length === 0 ? (
        <p className="note">It works on no GitHub repository yet.</p>
      ) : (
        <dl className="facts">
          {repositories.map((r) => {
            const name = repositoryName(r);
            const onlyRoot = (!r.path || r.path === ".") && repositories.length === 1;
            return (
              <div key={name}>
                <dt className="mono">{name}</dt>
                <dd>
                  {repositoryWhere(r)}
                  {r.ref ? `, branch ${r.ref}` : ""} · {r.github?.pull_request ? <a href={r.github.pull_request.url} target="_blank" rel="noreferrer">{repositoryWork(r)}</a> : repositoryWork(r)}
                  {owner && onTakeOff && !onlyRoot && (
                    <>
                      {" "}
                      <button type="button" className="link" disabled={busy} aria-label={`Take off ${name}`} onClick={() => void run(() => onTakeOff(name))}>
                        Take off
                      </button>
                    </>
                  )}
                </dd>
              </div>
            );
          })}
        </dl>
      )}
      {owner && onAttach && listed.length > 0 && !attaching && (
        <button type="button" onClick={() => setAttaching(true)}>
          Attach a repository
        </button>
      )}
      {attaching && onAttach && (
        <div className="ns-picker" role="group" aria-label="attach a repository">
          <div className="ns-picker-grid">
            <RepositoryChooser listed={listed} chosen={picked} max={1} held={held} onChange={setPicked} />
          </div>
          <div className="actions">
            <button
              type="button"
              disabled={busy || picked.length === 0}
              onClick={() =>
                void run(() => onAttach(picked[0]!)).then((done) => {
                  if (done) {
                    setAttaching(false);
                    setPicked([]);
                  }
                })
              }
            >
              {busy ? "Attaching…" : "Attach"}
            </button>
            <button type="button" onClick={() => setAttaching(false)}>
              Cancel
            </button>
          </div>
        </div>
      )}
      {error && (
        <p className="note" role="alert">
          {error}
        </p>
      )}
    </section>
  );
}
