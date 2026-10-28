// The person's artifacts in their own app (troupe #62): what they and their troupe published
// that they may open, through this computer's daemon and its sign-in, as the gallery in the
// console has them. A grid of cards grouped by when, filtered by who each is for (everyone,
// your teams and profiles, a link's, only you) and by a search; the one chosen in an aside
// with its versions, where it came from, who can see it, and for its owner the controls.
//
// Nothing of an artifact's content is drawn here: a card is its title, its kind and its
// size, and opening one shows it from the artifacts host in a window of the shell's own,
// granted nothing, at the one-time address `artifact.open` answers (a browser build opens a
// tab of its own instead). The app's own origin never fetches an artifact's files.
//
// Local only keeps the app off the plane, so the gallery asks nothing and says so. "New to
// you" is a version this device has not opened yet, kept in this device's storage alone.

import { useCallback, useEffect, useState } from "react";
import type { JSX } from "react";
import { audienceName, audienceOf, visibilityWords } from "@troupe/client";
import type { Artifact, ArtifactAudience, ArtifactDetail, ArtifactList, DaemonClient } from "@troupe/client";
import { copyText } from "../clipboard";
import { shell } from "../shell";
import { Loading, relative } from "./bits";
import { Publish, VisibilityOptions } from "./Publish";

type Filter = "all" | ArtifactAudience;

const AUDIENCE: Record<ArtifactAudience, { label: string; short: string; glyph: string; dots: number }> = {
  everyone: { label: "Everyone", short: "EVERYONE", glyph: "◉", dots: 3 },
  team: { label: "Your teams", short: "TEAM", glyph: "◎", dots: 2 },
  shared: { label: "Shared with you", short: "SHARED", glyph: "◐", dots: 2 },
  private: { label: "Only you", short: "ONLY YOU", glyph: "○", dots: 1 },
};

const KIND: Record<string, string> = { html: "HTML PAGE", markdown: "DOCUMENT", file: "FILE" };

const SEEN_KEY = "troupe.artifacts.seen";

/** The version of each artifact this device opened last, by id. */
function seenVersions(): Record<string, number> {
  try {
    const kept = JSON.parse(localStorage.getItem(SEEN_KEY) ?? "{}") as unknown;
    return kept && typeof kept === "object" ? (kept as Record<string, number>) : {};
  } catch {
    return {};
  }
}

function markSeen(id: string, version: number): void {
  try {
    const seen = seenVersions();
    if ((seen[id] ?? 0) >= version) return;
    localStorage.setItem(SEEN_KEY, JSON.stringify({ ...seen, [id]: version }));
  } catch {
    // A device that keeps nothing shows every artifact as new to it; nothing else changes.
  }
}

function sentence(e: unknown): string {
  const data = (e as { data?: { reason?: unknown } } | null)?.data;
  if (data && typeof data.reason === "string") return data.reason;
  return e instanceof Error ? e.message : String(e);
}

export function size(bytes: number | undefined): string {
  if (bytes === undefined || !Number.isFinite(bytes)) return "";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1).replace(/\.0$/, "")} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1).replace(/\.0$/, "")} MB`;
}

/** Today, This week or Earlier, by when its newest version was published. */
export function dayOf(iso: string | undefined, now = new Date()): "Today" | "This week" | "Earlier" {
  const at = iso ? new Date(iso) : null;
  if (!at || Number.isNaN(at.getTime())) return "Earlier";
  if (at.toDateString() === now.toDateString()) return "Today";
  return now.getTime() - at.getTime() < 7 * 24 * 3600 * 1000 ? "This week" : "Earlier";
}

function who(person: { subject: string; display_name?: string | null } | undefined | null, mine: boolean): string {
  if (mine) return "You";
  return person?.display_name || person?.subject || "somebody";
}

/** Who can see it, in a sentence, and what that means. */
function audienceWords(a: Artifact, audience: ArtifactAudience): { long: string; note: string } {
  const name = audienceName(a);
  switch (audience) {
    case "everyone":
      return { long: "Everyone in your organisation", note: "Anyone who can sign in to your Troupe plane can open it." };
    case "team":
      return a.visibility.startsWith("profile:")
        ? { long: `The ${name} profile's people`, note: `People granted the ${name} profile can open it. Nobody else can find it.` }
        : { long: `Everyone on ${name}`, note: `Members of ${name} can open it. People outside the team cannot find it.` };
    case "shared":
      return { long: "Shared with you by a link", note: `${who(a.owner, false)} made a link to it, and you opened it; you keep what the link gives you until it is revoked.` };
    case "private":
      return { long: "Only you", note: "Nobody else can find or open it. Make a link when you are ready to share it." };
  }
}

/** Open an artifact, or one version, from its host: a window of the shell's, or a tab of its own. */
async function show(daemon: DaemonClient, a: { id: string; title: string }, version?: number): Promise<void> {
  const ticket = await daemon.openArtifact(a.id, version);
  const title = version === undefined ? a.title : `${a.title} (version ${version})`;
  const open = shell()?.openArtifactWindow;
  if (open) await open(ticket.url, title, a.id);
  else globalThis.open?.(ticket.url, "_blank", "noopener,noreferrer");
}

async function openExternal(url: string): Promise<void> {
  const open = shell()?.openExternal;
  if (open) await open(url);
  else globalThis.open?.(url, "_blank", "noopener,noreferrer");
}

export function Artifacts({
  daemon,
  localOnly,
  onOpenSession,
}: {
  daemon: DaemonClient | null;
  localOnly: boolean;
  /** A session the artifact came from, opened in the app where it is one of the list's. */
  onOpenSession?: ((id: string) => void) | undefined;
}): JSX.Element {
  const [list, setList] = useState<ArtifactList | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState<Filter>("all");
  const [selected, setSelected] = useState<string | null>(null);
  const [seen, setSeen] = useState(seenVersions);
  const [asked, setAsked] = useState(0);

  useEffect(() => {
    if (localOnly || !daemon) return;
    let live = true;
    setError(null);
    daemon.artifacts({}).then(
      (l) => {
        if (live) setList(l);
      },
      (e: unknown) => live && setError(sentence(e)),
    );
    return () => {
      live = false;
    };
  }, [daemon, localOnly, asked]);

  const reload = useCallback(() => setAsked((n) => n + 1), []);

  const head = (
    <header className="repertoire-head">
      <div className="lede">
        <span className="screen">The repertoire</span>
        <h1>Artifacts</h1>
        <p className="muted">Pages, documents and files your troupe has published. You only see what was published for you.</p>
      </div>
      {!localOnly && (
        <label className="search-field">
          <span aria-hidden="true">/</span>
          <input type="search" value={query} onChange={(e) => setQuery(e.target.value)} aria-label="Search artifacts" placeholder="Search by title, person or session" />
        </label>
      )}
    </header>
  );

  if (localOnly) {
    return (
      <div className="repertoire">
        {head}
        <p className="note">Local only: the plane is not asked. Artifacts are kept on your organisation's plane; turn Local only off to see them here.</p>
      </div>
    );
  }
  if (!daemon) return <div className="repertoire">{head}<p className="note">This computer's daemon is not connected, and the gallery is read through it.</p></div>;
  if (error) return <div className="repertoire">{head}<p className="note error">{error}</p></div>;
  if (!list) return <div className="repertoire">{head}<Loading what="Asking the plane for your artifacts…" /></div>;

  const q = query.trim().toLowerCase();
  const matches = (a: Artifact): boolean => !q || [a.title, who(a.owner, a.mine), a.owner?.subject ?? "", a.origin?.session_id ?? ""].join(" ").toLowerCase().includes(q);
  const searched = list.artifacts.filter(matches);
  const shown = searched.filter((a) => filter === "all" || audienceOf(a) === filter);
  const count = (f: Filter): number => searched.filter((a) => f === "all" || audienceOf(a) === f).length;
  const current = list.artifacts.find((a) => a.id === selected) ?? null;
  const groups = (["Today", "This week", "Earlier"] as const).map((day) => ({ day, items: shown.filter((a) => dayOf(a.published_at) === day) })).filter((g) => g.items.length > 0);

  return (
    <div className="repertoire">
      {head}
      <nav className="audiences" aria-label="Who it is for">
        {(["all", "everyone", "team", "shared", "private"] as const).map((f) => (
          <button key={f} type="button" className={`audience is-${f}`} aria-pressed={filter === f} onClick={() => setFilter(f)}>
            {f !== "all" && (
              <span className="dots" aria-hidden="true">
                {Array.from({ length: AUDIENCE[f].dots }, (_, i) => (
                  <span key={i} />
                ))}
              </span>
            )}
            <span>{f === "all" ? "All" : AUDIENCE[f].label}</span>
            <span className="n">{count(f)}</span>
          </button>
        ))}
        <span className="order micro">NEWEST FIRST</span>
      </nav>
      {!list.enabled && <p className="note">An administrator has switched artifacts off on this plane, so there are none to show.</p>}
      <div className="repertoire-body">
        <div className="repertoire-main">
          {groups.map((g) => (
            <section key={g.day} className="day" aria-label={g.day}>
              <h2>
                {g.day}
                <span className="n">{g.items.length}</span>
              </h2>
              <div className="cards">
                {g.items.map((a) => {
                  const audience = audienceOf(a);
                  const fresh = !a.mine && (seen[a.id] ?? 0) < a.version;
                  return (
                    <button key={a.id} type="button" className="card" aria-current={a.id === selected ? "true" : undefined} onClick={() => setSelected(a.id)}>
                      <span className="placeholder" aria-hidden="true">
                        <span className="what">
                          {a.kind} · {size(a.bytes)}
                        </span>
                        {fresh && <span className="fresh">NEW TO YOU</span>}
                      </span>
                      <span className="body">
                        <span className="title">{a.title}</span>
                        {fresh && <span className="visually-hidden">New to you.</span>}
                        <span className="byline">
                          {who(a.owner, a.mine)} · {relative(Date.parse(a.published_at))}
                        </span>
                        <span className="tags">
                          <span className={`audience-pill is-${audience}`}>
                            {AUDIENCE[audience].glyph} {audience === "team" ? (audienceName(a) ?? "TEAM").toUpperCase() : AUDIENCE[audience].short}
                          </span>
                          <span className="kind micro">{KIND[a.kind] ?? a.kind.toUpperCase()}</span>
                        </span>
                      </span>
                    </button>
                  );
                })}
              </div>
            </section>
          ))}
          {shown.length === 0 && (
            <div className="empty">
              <p className="title">{q ? `Nothing matches “${query.trim()}”` : "Nothing here yet"}</p>
              <p className="muted">{q ? "Try a person's name or the session it came from." : "When someone publishes for this audience, it appears here. Publish from any session with /publish."}</p>
              <button
                type="button"
                onClick={() => {
                  setFilter("all");
                  setQuery("");
                }}
              >
                Show everything
              </button>
            </div>
          )}
        </div>
        {current && (
          <Aside
            key={current.id}
            daemon={daemon}
            artifact={current}
            audience={audienceOf(current)}
            teams={list.teams}
            profiles={list.profiles}
            onOpened={(version) => {
              markSeen(current.id, version);
              setSeen(seenVersions());
            }}
            onChanged={reload}
            onOpenSession={onOpenSession}
          />
        )}
      </div>
    </div>
  );
}

/** The artifact chosen: what it is, Open and Copy link, who can see it, where it came from, its versions, and its owner's controls. */
function Aside({
  daemon,
  artifact,
  audience,
  teams,
  profiles,
  onOpened,
  onChanged,
  onOpenSession,
}: {
  daemon: DaemonClient;
  artifact: Artifact;
  audience: ArtifactAudience;
  teams: string[] | undefined;
  profiles: string[] | undefined;
  onOpened: (version: number) => void;
  onChanged: () => void;
  onOpenSession?: ((id: string) => void) | undefined;
}): JSX.Element {
  const [detail, setDetail] = useState<ArtifactDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [said, setSaid] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [busy, setBusy] = useState(false);
  const [publishing, setPublishing] = useState(false);
  const [asked, setAsked] = useState(0);
  const [moveTo, setMoveTo] = useState(artifact.visibility);
  const owner = artifact.mine || artifact.role === "owner";

  useEffect(() => {
    let live = true;
    daemon.artifact(artifact.id).then(
      (d) => live && setDetail(d),
      (e: unknown) => live && setError(sentence(e)),
    );
    return () => {
      live = false;
    };
  }, [daemon, artifact.id, asked]);

  const act = async (what: () => Promise<unknown>, done: string): Promise<void> => {
    setBusy(true);
    setError(null);
    setSaid(null);
    try {
      await what();
      setSaid(done);
      setAsked((n) => n + 1);
      onChanged();
    } catch (e) {
      setError(sentence(e));
    } finally {
      setBusy(false);
    }
  };

  const open = (version?: number): void => {
    setError(null);
    show(daemon, artifact, version).then(
      () => onOpened(version ?? detail?.current ?? artifact.current ?? artifact.version),
      (e: unknown) => setError(sentence(e)),
    );
  };

  // Its owner's link is a view link made now, shown once; anybody else's is its address, which signs them in.
  const copy = async (): Promise<void> => {
    setError(null);
    try {
      const url = owner ? (await daemon.shareArtifact(artifact.id, "view")).url : artifact.url;
      await copyText(url);
      setCopied(true);
      if (owner) setAsked((n) => n + 1);
    } catch (e) {
      setError(`Not copied: ${sentence(e)}`);
    }
  };

  // Its address in the person's browser, which signs them in; a shell that refuses says why here.
  const browse = (): void => {
    setError(null);
    openExternal(artifact.url).catch((e: unknown) => setError(`Not opened: ${sentence(e)}`));
  };

  const words = audienceWords(artifact, audience);
  const versions = detail?.versions ?? [];
  const pinned = detail?.pinned ?? artifact.pinned ?? null;
  const shares = (detail?.shares ?? []).filter((s) => s.state === "live");
  const summary = versions[0]?.note ?? null;

  return (
    <aside className="repertoire-aside" aria-label="Artifact details">
      <div>
        <div className="micro what">
          {KIND[artifact.kind] ?? artifact.kind.toUpperCase()} · VERSION {artifact.version} · {size(artifact.bytes)}
        </div>
        <h2>{artifact.title}</h2>
        {summary && <p className="muted">{summary}</p>}
      </div>
      <div className="actions">
        <button type="button" className="primary" onClick={() => open()}>
          Open
        </button>
        <button type="button" onClick={() => void copy()}>
          {copied ? "Link copied" : "Copy link"}
        </button>
        <button type="button" onClick={browse}>
          Open in browser
        </button>
      </div>
      {error && <p className="note error">{error}</p>}
      {said && <p className="note" role="status">{said}</p>}

      <section>
        <h3 className="screen">Who can see it</h3>
        <p className={`audience-line is-${audience}`}>
          {AUDIENCE[audience].glyph} {words.long}
        </p>
        <p className="muted">{words.note}</p>
        {owner && (
          <div className="move-visibility">
            <label>
              Who may open it
              <select value={moveTo} disabled={busy} onChange={(e) => setMoveTo(e.target.value)}>
                <VisibilityOptions teams={teams} profiles={profiles} />
              </select>
            </label>
            <button
              type="button"
              disabled={busy || moveTo === artifact.visibility}
              onClick={() =>
                void act(
                  () => daemon.moveArtifact(artifact.id, artifact.version, moveTo),
                  `Moved: ${artifact.title} is for ${visibilityWords(moveTo)} now, as version ${artifact.version + 1} with the same files.`,
                )
              }
            >
              Change who can see it
            </button>
          </div>
        )}
      </section>

      <section>
        <h3 className="screen">Where it came from</h3>
        <dl className="origin">
          <dt>BY</dt>
          <dd>{who(artifact.owner, artifact.mine)}</dd>
          {artifact.origin?.session_id && (
            <>
              <dt>SESSION</dt>
              <dd>
                {onOpenSession ? (
                  <button type="button" className="link" onClick={() => onOpenSession(artifact.origin.session_id!)}>
                    {artifact.origin.session_id}
                  </button>
                ) : (
                  artifact.origin.session_id
                )}
              </dd>
            </>
          )}
          {artifact.origin?.profile && (
            <>
              <dt>PROFILE</dt>
              <dd className="profile">{artifact.origin.profile}</dd>
            </>
          )}
        </dl>
      </section>

      <section>
        <h3 className="screen">Versions</h3>
        {!detail && !error && <Loading what="Reading its versions…" />}
        {pinned !== null && <p className="muted micro">Its address serves version {pinned}, pinned by its owner.</p>}
        <ol className="versions">
          {versions.map((v, i) => (
            <li key={v.n} className={i === 0 ? "newest" : undefined}>
              <span className="n">v{v.n}</span>
              <span className="note-text">{v.note ?? (v.n === 1 ? "First publish" : "")}</span>
              <span className="micro" title={v.published_at}>
                {relative(Date.parse(v.published_at))}
              </span>
              <span className="version-actions">
                <button type="button" className="link" onClick={() => open(v.n)} aria-label={`Open version ${v.n}`}>
                  Open
                </button>
                {(owner || artifact.may_edit) && i > 0 && (
                  <button type="button" className="link" disabled={busy} onClick={() => void act(() => daemon.rollbackArtifact(artifact.id, v.n), `Rolled back: version ${v.n}'s files are the newest version now.`)}>
                    Roll back to it
                  </button>
                )}
                {owner && (
                  <button
                    type="button"
                    className="link"
                    disabled={busy}
                    onClick={() =>
                      void act(
                        () => daemon.pinArtifact(artifact.id, pinned === v.n ? null : v.n),
                        pinned === v.n ? "Unpinned: its address serves the newest version." : `Pinned: its address serves version ${v.n}.`,
                      )
                    }
                  >
                    {pinned === v.n ? "Unpin" : "Pin"}
                  </button>
                )}
              </span>
            </li>
          ))}
        </ol>
        {owner && (
          <button type="button" onClick={() => setPublishing(true)}>
            Publish a new version
          </button>
        )}
      </section>

      {owner && detail && (
        <section>
          <h3 className="screen">Links</h3>
          {shares.length === 0 ? (
            <p className="muted">No link to it is open. Copy link makes one that opens it for whoever the plane signs in through it.</p>
          ) : (
            <ul className="links">
              {shares.map((s) => (
                <li key={s.id}>
                  <span>
                    {s.role === "edit" ? "Can edit" : "Can view"}
                    {s.used_by.length > 0 && ` · opened by ${s.used_by.map((u) => u.person.display_name || u.person.subject).join(", ")}`}
                  </span>
                  <button type="button" className="link" disabled={busy} onClick={() => void act(() => daemon.unshareArtifact(artifact.id, { share: s.id }), "Revoked: that link opens nothing now.")}>
                    Revoke
                  </button>
                </li>
              ))}
            </ul>
          )}
        </section>
      )}

      {publishing && (
        <Publish
          daemon={daemon}
          target={artifact.id}
          onClose={() => {
            setPublishing(false);
            setAsked((n) => n + 1);
            onChanged();
          }}
        />
      )}
    </aside>
  );
}
