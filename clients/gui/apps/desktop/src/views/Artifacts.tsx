// The person's artifacts in their own app (troupe #62): what they and their troupe published
// that they may open, as the gallery in the console has them: from the plane itself where
// the app is signed in to one, through this computer's daemon and its sign-in otherwise. A grid of cards grouped by when, filtered by who each is for (everyone,
// your teams and profiles, a link's, only you) and by a search; the one chosen in an aside
// with its versions, where it came from, who can see it, whose it is, and for its owner the
// controls. An artifact a team owns is every member's: each has the owner's controls, and
// the owning person gives one of theirs to a team, or the team's admin takes it back.
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
import { audienceName, audienceOf, teamOwned, visibilityWords } from "@troupe/client";
import type { Artifact, ArtifactAudience, ArtifactDetail, ArtifactList, ArtifactShareRole, ArtifactThread, DaemonClient, OwnPlane, Person } from "@troupe/client";
import { copyText } from "../clipboard";
import { shell } from "../shell";
import { Loading, relative, unreachedWords } from "./bits";
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

/** Whose it is, for a card's byline: the team that owns it, or the person. */
function whose(a: Artifact): string {
  return teamOwned(a) ? `Team ${a.owner_team}` : who(a.owner, a.mine);
}

/** What a role shared with somebody lets them do, as a sentence's start. */
function mayWords(role: string | null | undefined): string {
  if (role === "edit") return "You can open it, comment on it and publish new versions of it";
  if (role === "comment") return "You can open it and comment on it";
  return "You can open it";
}

/** The roles an owner gives somebody, in the words the share control offers. */
const ROLES: Array<{ role: ArtifactShareRole; label: string }> = [
  { role: "view", label: "Can view" },
  { role: "comment", label: "Can comment" },
  { role: "edit", label: "Can edit" },
];

function roleLabel(role: string): string {
  return ROLES.find((r) => r.role === role)?.label ?? role;
}

/** Who can see it, in a sentence, and what that means. A team's is its members' whatever it is for. */
function audienceWords(a: Artifact, audience: ArtifactAudience): { long: string; note: string } {
  const name = audienceName(a);
  const members = teamOwned(a) ? ` Members of ${a.owner_team}, whose it is, can open it too.` : "";
  switch (audience) {
    case "everyone":
      return { long: "Everyone in your organisation", note: "Anyone who can sign in to your Troupe plane can open it." };
    case "team":
      return a.visibility.startsWith("profile:")
        ? { long: `The ${name} profile's people`, note: `People granted the ${name} profile can open it. Nobody else can find it.${members}` }
        : { long: `Everyone on ${name}`, note: `Members of ${name} can open it. People outside the team cannot find it.${a.owner_team && a.owner_team !== name ? members : ""}` };
    case "shared":
      return { long: "Shared with you", note: `${whose(a)} shared it with you, by name or by a link you opened. ${mayWords(a.role)} until they take it back.` };
    case "private":
      return teamOwned(a)
        ? { long: `Only the ${a.owner_team} team`, note: `Members of ${a.owner_team}, whose it is, can find and open it; nobody else can. Share it with somebody by name, or make a link, when you are ready.` }
        : { long: "Only you", note: "Nobody else can find or open it. Share it with somebody by name, or make a link, when you are ready." };
  }
}

/** Open an artifact, or one version, from its host: a window of the shell's, or a tab of its own. */
async function show(via: OwnPlane, a: { id: string; title: string }, version?: number): Promise<void> {
  const ticket = await via.openArtifact(a.id, version);
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

/**
 * The gallery. `via` is what the person's artifacts are read and changed through: the plane
 * itself where the app is signed in to one, this computer's daemon otherwise, and nothing
 * under Local only or with neither. `daemon` publishes a new version, which sends files from
 * this computer.
 */
export function Artifacts({
  via,
  daemon,
  daemonState,
  localOnly,
  onOpenSession,
}: {
  via: OwnPlane | null;
  daemon: DaemonClient | null;
  daemonState: { status: "unsupported" | "searching" | "absent" | "connected" | "error"; error: string | null };
  localOnly: boolean;
  /** A session the artifact came from, opened in the app where it is one of the list's. */
  onOpenSession?: ((id: string) => void) | undefined;
}): JSX.Element {
  const [list, setList] = useState<ArtifactList | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState<Filter>("all");
  const [kind, setKind] = useState<"all" | Artifact["kind"]>("all");
  const [selected, setSelected] = useState<string | null>(null);
  const [seen, setSeen] = useState(seenVersions);
  const [asked, setAsked] = useState(0);

  useEffect(() => {
    if (localOnly || !via) return;
    let live = true;
    setError(null);
    via.artifacts({}).then(
      (l) => {
        if (live) setList(l);
      },
      (e: unknown) => live && setError(sentence(e)),
    );
    return () => {
      live = false;
    };
  }, [via, localOnly, asked]);

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
  if (!via) {
    const unreached = unreachedWords(daemonState, "your artifacts");
    return <div className="repertoire">{head}{unreached ? <p className="note">{unreached}</p> : <Loading what="Looking for this computer's daemon…" />}</div>;
  }
  if (error) return <div className="repertoire">{head}<p className="note error">{error}</p></div>;
  if (!list) return <div className="repertoire">{head}<Loading what="Asking the plane for your artifacts…" /></div>;

  const q = query.trim().toLowerCase();
  const matches = (a: Artifact): boolean => !q || [a.title, whose(a), who(a.owner, a.mine), a.owner?.subject ?? "", a.origin?.session_id ?? ""].join(" ").toLowerCase().includes(q);
  const searched = list.artifacts.filter((a) => matches(a) && (kind === "all" || a.kind === kind));
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
        <label className="kind-filter micro">
          <span className="visually-hidden">Kind</span>
          <select value={kind} onChange={(e) => setKind(e.target.value as typeof kind)} aria-label="Kind">
            <option value="all">Every kind</option>
            <option value="html">Pages</option>
            <option value="markdown">Documents</option>
            <option value="file">Files</option>
          </select>
        </label>
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
                          {whose(a)} · {relative(Date.parse(a.published_at))}
                        </span>
                        <span className="tags">
                          <span className={`audience-pill is-${audience}`}>
                            {AUDIENCE[audience].glyph} {audience === "team" ? (audienceName(a) ?? "TEAM").toUpperCase() : AUDIENCE[audience].short}
                          </span>
                          <span className="kind micro">{KIND[a.kind] ?? a.kind.toUpperCase()}</span>
                          {(a.comments ?? 0) > 0 && <span className="kind micro">{a.comments === 1 ? "1 COMMENT" : `${a.comments} COMMENTS`}</span>}
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
              {/* Only where something narrows the list: with every audience shown and
                  nothing typed it would show what is already shown, which is nothing. */}
              {(q || filter !== "all" || kind !== "all") && (
                <button
                  type="button"
                  onClick={() => {
                    setFilter("all");
                    setKind("all");
                    setQuery("");
                  }}
                >
                  Show everything
                </button>
              )}
            </div>
          )}
        </div>
        {current && (
          <Aside
            key={current.id}
            via={via}
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
  via,
  daemon,
  artifact,
  audience,
  teams,
  profiles,
  onOpened,
  onChanged,
  onOpenSession,
}: {
  via: OwnPlane;
  daemon: DaemonClient | null;
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
  const [giveTo, setGiveTo] = useState(teams?.[0] ?? "");
  // A member of the team that owns it is its owner, as the plane says it (`role`, `mine`).
  const owner = artifact.mine || artifact.role === "owner";
  const ofTeam = teamOwned(artifact);
  // The owning person gives it to a team of theirs; the owning team's admin takes it back.
  const mayGive = !ofTeam && artifact.may_transfer === true && (teams?.length ?? 0) > 0;
  const mayTakeBack = ofTeam && artifact.may_transfer === true;

  useEffect(() => {
    let live = true;
    via.artifact(artifact.id).then(
      (d) => live && setDetail(d),
      (e: unknown) => live && setError(sentence(e)),
    );
    return () => {
      live = false;
    };
  }, [via, artifact.id, asked]);

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
    show(via, artifact, version).then(
      () => onOpened(version ?? detail?.current ?? artifact.current ?? artifact.version),
      (e: unknown) => setError(sentence(e)),
    );
  };

  // Its owner's link is a view link made now, shown once; anybody else's is its address, which signs them in.
  const copy = async (): Promise<void> => {
    setError(null);
    try {
      const url = owner ? (await via.shareArtifact(artifact.id, "view")).url : artifact.url;
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
                  () => via.moveArtifact(artifact.id, artifact.version, moveTo),
                  `Moved: ${artifact.title} is for ${visibilityWords(moveTo)} now, as version ${artifact.version + 1} with the same files.`,
                )
              }
            >
              Change who can see it
            </button>
          </div>
        )}
        {owner && detail && <SharedWith via={via} artifact={artifact} detail={detail} onChanged={() => setAsked((n) => n + 1)} />}
      </section>

      <section>
        <h3 className="screen">Whose it is</h3>
        <p className="owner-line">{ofTeam ? `Team ${artifact.owner_team}${artifact.mine ? " (you are a member)" : ""}` : who(artifact.owner, artifact.mine)}</p>
        <p className="muted">
          {ofTeam
            ? `Anyone on ${artifact.owner_team} can publish versions, change who can see it, share and delete it; a member leaving the team changes nothing.${!artifact.mine && artifact.owner ? ` ${who(artifact.owner, false)} first published it.` : ""}`
            : artifact.mine
              ? "Only you have its owner's controls."
              : `Only ${who(artifact.owner, false)} has its owner's controls.`}
        </p>
        {mayGive && (
          <div className="move-visibility">
            <label>
              Give to team
              <select value={giveTo} disabled={busy} onChange={(e) => setGiveTo(e.target.value)} aria-label="Give to team">
                {(teams ?? []).map((t) => (
                  <option key={t} value={t}>
                    {t}
                  </option>
                ))}
              </select>
            </label>
            <button
              type="button"
              disabled={busy || giveTo === ""}
              onClick={() => void act(() => via.transferArtifact(artifact.id, `team:${giveTo}`), `Given: ${artifact.title} is the ${giveTo} team's now, and every member of it is its owner.`)}
            >
              Give it to the team
            </button>
          </div>
        )}
        {mayTakeBack && (
          <div className="move-visibility">
            <button type="button" disabled={busy} onClick={() => void act(() => via.transferArtifact(artifact.id, "me"), `Taken back: ${artifact.title} is yours now, not the ${artifact.owner_team} team's.`)}>
              Take back
            </button>
          </div>
        )}
      </section>

      <section>
        <h3 className="screen">Where it came from</h3>
        <dl className="origin">
          <dt>BY</dt>
          <dd>{who(artifact.owner, artifact.mine && !ofTeam)}</dd>
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
                  <button type="button" className="link" disabled={busy} onClick={() => void act(() => via.rollbackArtifact(artifact.id, v.n), `Rolled back: version ${v.n}'s files are the newest version now.`)}>
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
                        () => via.pinArtifact(artifact.id, pinned === v.n ? null : v.n),
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
        {/* A new version's files are this computer's, sent by its daemon. */}
        {owner && daemon && (
          <button type="button" onClick={() => setPublishing(true)}>
            Publish a new version
          </button>
        )}
      </section>

      <Thread via={via} artifact={artifact} />

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
                    {roleLabel(s.role)}
                    {s.used_by.length > 0 && ` · opened by ${s.used_by.map((u) => u.person.display_name || u.person.subject).join(", ")}`}
                  </span>
                  <button type="button" className="link" disabled={busy} onClick={() => void act(() => via.unshareArtifact(artifact.id, { share: s.id }), "Revoked: that link opens nothing now.")}>
                    Revoke
                  </button>
                </li>
              ))}
            </ul>
          )}
        </section>
      )}

      {publishing && daemon && (
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

/**
 * Who its owner shared it with by name, each at a role, and the picker that adds somebody:
 * people whose name starts with what is typed, among those the plane lets the owner find, as
 * the session's invitation picker has them. Naming somebody again changes their role.
 */
function SharedWith({ via, artifact, detail, onChanged }: { via: OwnPlane; artifact: Artifact; detail: ArtifactDetail; onChanged: () => void }): JSX.Element {
  const [query, setQuery] = useState("");
  const [found, setFound] = useState<Person[]>([]);
  const [chosen, setChosen] = useState<Person | null>(null);
  const [role, setRole] = useState<ArtifactShareRole>("view");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [said, setSaid] = useState<string | null>(null);
  const people = detail.people ?? [];

  useEffect(() => {
    const q = query.trim();
    if (q === "" || chosen) return setFound([]);
    let live = true;
    const t = setTimeout(() => {
      via.searchPeople(q).then(
        (r) => live && setFound(r.people.filter((p) => !people.some((s) => s.subject === p.subject))),
        () => live && setFound([]),
      );
    }, 150);
    return () => {
      live = false;
      clearTimeout(t);
    };
  }, [via, query, chosen, people.length]);

  const act = async (what: () => Promise<unknown>, done: string): Promise<void> => {
    setBusy(true);
    setError(null);
    setSaid(null);
    try {
      await what();
      setSaid(done);
      setQuery("");
      setChosen(null);
      onChanged();
    } catch (e) {
      setError(sentence(e));
    } finally {
      setBusy(false);
    }
  };

  const name = (p: { subject: string; display_name?: string | null }): string => p.display_name || p.subject;

  return (
    <div className="shared-with">
      <h4 className="micro">SHARED WITH</h4>
      {people.length === 0 ? (
        <p className="muted">Nobody by name. Pick somebody below, or make a link.</p>
      ) : (
        <ul className="links" aria-label="Shared with">
          {people.map((p) => (
            <li key={p.subject}>
              <span>
                {name(p)} · {roleLabel(p.role)}
              </span>
              <button type="button" className="link" disabled={busy} aria-label={`Remove ${name(p)}`} onClick={() => void act(() => via.unshareArtifact(artifact.id, { person: p.subject }), `Removed: ${name(p)} cannot open ${artifact.title} now, unless it is for somebody they are.`)}>
                Remove
              </button>
            </li>
          ))}
        </ul>
      )}
      <form
        className="move-visibility"
        onSubmit={(e) => {
          e.preventDefault();
          if (chosen) void act(() => via.sharePersonArtifact(artifact.id, chosen.subject, role), `Shared: ${name(chosen)} finds ${artifact.title} under Shared with you, and ${roleLabel(role).toLowerCase()}.`);
        }}
      >
        <label>
          Share with
          <input
            value={query}
            disabled={busy}
            onChange={(e) => {
              setQuery(e.target.value);
              setChosen(null);
            }}
            placeholder="A name or an email"
          />
        </label>
        {found.length > 0 && (
          <ul className="people" aria-label="People">
            {found.map((p) => (
              <li key={p.subject}>
                <button
                  type="button"
                  className="tab"
                  onClick={() => {
                    setChosen(p);
                    setQuery(name(p));
                  }}
                >
                  {name(p)}
                  {p.email && p.email !== name(p) ? ` · ${p.email}` : ""}
                </button>
              </li>
            ))}
          </ul>
        )}
        <label>
          They may
          <select value={role} disabled={busy} onChange={(e) => setRole(e.target.value as ArtifactShareRole)}>
            {ROLES.map((r) => (
              <option key={r.role} value={r.role}>
                {r.label.replace(/^Can /, "")}
              </option>
            ))}
          </select>
        </label>
        <button type="submit" disabled={busy || !chosen}>
          Share
        </button>
      </form>
      {query.trim() !== "" && !chosen && found.length === 0 && <p className="muted micro">Nobody you can share with has a name that starts with that.</p>}
      {error && <p className="note error">{error}</p>}
      {said && <p className="note" role="status">{said}</p>}
    </div>
  );
}

/**
 * The artifact's thread, oldest first, each comment with who wrote it and when; a box to
 * write one for whoever the plane says may (its owners, and anybody given comment or edit).
 * The session it came from is told of each, so whoever steers it can ask its agent to act.
 */
function Thread({ via, artifact }: { via: OwnPlane; artifact: Artifact }): JSX.Element {
  const [thread, setThread] = useState<ArtifactThread | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [asked, setAsked] = useState(0);
  const [absent, setAbsent] = useState(false);

  useEffect(() => {
    let live = true;
    via.artifactComments(artifact.id).then(
      (t) => live && setThread(t),
      (e: unknown) => {
        if (!live) return;
        // A plane from before comments has no thread to show, which is no fault.
        if ((e as { code?: unknown } | null)?.code === -32601) setAbsent(true);
        else setError(sentence(e));
      },
    );
    return () => {
      live = false;
    };
  }, [via, artifact.id, asked]);

  if (absent) return <></>;

  const send = async (): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      await via.commentArtifact(artifact.id, draft);
      setDraft("");
      setAsked((n) => n + 1);
    } catch (e) {
      setError(`Not posted: ${sentence(e)}`);
    } finally {
      setBusy(false);
    }
  };

  const comments = thread?.comments ?? [];
  return (
    <section aria-label="Comments">
      <h3 className="screen">Comments</h3>
      {!thread && !error && <Loading what="Reading its comments…" />}
      {thread && comments.length === 0 && <p className="muted">No comments yet.{thread.may_comment ? " Its owners and editors, and the session it came from, see what you write here." : ""}</p>}
      {comments.length > 0 && (
        <ol className="comments">
          {comments.map((c) => (
            <li key={c.id}>
              <p className="micro">
                <span className="author">{c.author.display_name || c.author.subject}</span> ·{" "}
                <span title={c.created_at}>{relative(Date.parse(c.created_at))}</span>
              </p>
              <p className="comment-body">{c.body}</p>
            </li>
          ))}
        </ol>
      )}
      {thread?.may_comment && (
        <form
          className="comment-form"
          onSubmit={(e) => {
            e.preventDefault();
            if (draft.trim() !== "") void send();
          }}
        >
          <label>
            <span className="visually-hidden">Write a comment</span>
            <textarea value={draft} maxLength={thread.max_length} disabled={busy} onChange={(e) => setDraft(e.target.value)} placeholder="Write a comment" rows={3} />
          </label>
          <button type="submit" disabled={busy || draft.trim() === ""}>
            Comment
          </button>
        </form>
      )}
      {thread && !thread.may_comment && <p className="muted micro">You can read the comments. Its owner decides who may write them.</p>}
      {error && <p className="note error">{error}</p>}
    </section>
  );
}
