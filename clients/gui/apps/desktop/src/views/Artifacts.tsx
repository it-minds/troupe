// The person's artifacts in their own app (troupe #62): what they and their troupe published
// that they may open, as the gallery in the console has them: from the plane itself where
// the app is signed in to one, through this computer's daemon and its sign-in otherwise. A grid of cards grouped by when, filtered by who each is for (everyone,
// your teams, a link's or a name's, only you) and by a search. The grid has the screen's
// width: a click on a card opens the artifact, and its Info opens a modal dialog in four tabs
// (Overview, Access, Versions, Comments) with where it came from, who reads it, whose it
// is, its versions, its thread, and for its owner the controls: who reads it is one menu
// (teams, people, the organisation switch) saved at once, kept across its versions, beside
// its links. An artifact a team owns is
// every member's: each has the owner's controls, and the owning person gives one of theirs
// to a team, or the team's admin takes it back.
//
// Nothing of an artifact's content is drawn here: a card is its title, its kind and its
// size, and the picture its publisher sent of it where there is one (an image the artifacts
// host serves at the row's `thumbnail_url`, never the page), and opening one shows it from
// the artifacts host in a window of the shell's own,
// granted nothing, at the one-time address `artifact.open` answers (a browser build opens a
// tab of its own instead). The app's own origin never fetches an artifact's files.
//
// Local only keeps the app off the plane, so the gallery asks nothing and says so. "New to
// you" is a version this device has not opened yet, kept in this device's storage alone.
// What the person keeps at the top is theirs on the plane (`artifact.keep`), so it follows
// them to every device; the team chips and the published range are this view's, reset with it.

import { useCallback, useEffect, useId, useRef, useState } from "react";
import type { JSX, KeyboardEvent as ReactKeyboardEvent, ReactNode } from "react";
import { accessChanges, accessWaiting, ago, artifactAccessWords, artifactLinkText, audienceOf, audienceTeams, blockedKindWords, blockedWords, bytes, errorText, teamOwned } from "@troupe/client";
import type { Artifact, ArtifactAccess, ArtifactAccessChange, ArtifactAudience, ArtifactDetail, ArtifactList, ArtifactShareRole, ArtifactThread, ArtifactVersion, DaemonClient, OwnPlane, Person } from "@troupe/client";
import { goesLine, goesSentence, versionGoes, versionsSentence } from "@troupe/client";
import { copyText } from "../clipboard";
import { shell } from "../shell";
import { Loading, unreachedWords } from "./bits";
import { Publish } from "./Publish";

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

/** Today, This week or Earlier, by when its newest version was published. */
export function dayOf(iso: string | undefined, now = new Date()): "Today" | "This week" | "Earlier" {
  const at = iso ? new Date(iso) : null;
  if (!at || Number.isNaN(at.getTime())) return "Earlier";
  if (at.toDateString() === now.toDateString()) return "Today";
  return now.getTime() - at.getTime() < 7 * 24 * 3600 * 1000 ? "This week" : "Earlier";
}

/** The local calendar day an instant falls on, as a date field says it (`YYYY-MM-DD`); "" for none. */
export function localDay(iso: string | undefined): string {
  const at = iso ? new Date(iso) : null;
  if (!at || Number.isNaN(at.getTime())) return "";
  const two = (n: number): string => String(n).padStart(2, "0");
  return `${at.getFullYear()}-${two(at.getMonth() + 1)}-${two(at.getDate())}`;
}

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

/** A date field's day in words: "3 November 2026". */
function dayWords(day: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(day);
  return m ? `${Number(m[3])} ${MONTHS[Number(m[2]) - 1] ?? m[2]} ${m[1]}` : day;
}

/** Published since … until …, in words, for the empty state: "" for no range. */
export function rangeWords(since: string, until: string): string {
  if (since && until) return since === until ? `on ${dayWords(since)}` : `between ${dayWords(since)} and ${dayWords(until)}`;
  if (since) return `since ${dayWords(since)}`;
  if (until) return `until ${dayWords(until)}`;
  return "";
}

/** Whether it was published inside the range, each end a day and both included; an empty end is open. */
function inRange(a: Artifact, since: string, until: string): boolean {
  if (!since && !until) return true;
  const day = localDay(a.published_at);
  return (!since || day >= since) && (!until || day <= until);
}

const KINDS: Record<string, string> = { html: "pages", markdown: "documents", file: "files" };

function who(person: { subject: string; display_name?: string | null } | undefined | null, mine: boolean): string {
  if (mine) return "You";
  return person?.display_name || person?.subject || "somebody";
}

/** Whose it is, for a card's byline: the team that owns it, or the person. */
function whose(a: Artifact): string {
  return teamOwned(a) ? `Team ${a.owner_team}` : who(a.owner, a.mine);
}

/**
 * A card's picture, from the artifacts host: an image and nothing that runs. One that does not
 * load (its address past its hour or two, the artifact gone) leaves the striped placeholder.
 */
function Picture({ src, alt }: { src: string; alt: string }): JSX.Element | null {
  const [failed, setFailed] = useState(false);
  useEffect(() => setFailed(false), [src]);
  if (failed) return null;
  return <img className="picture" src={src} alt={alt} loading="lazy" referrerPolicy="no-referrer" onError={() => setFailed(true)} />;
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
  const teams = a.teams ?? audienceTeams(a);
  const named = teams.length === 1 ? teams[0]! : teams.length > 1 ? `${teams.slice(0, -1).join(", ")} and ${teams[teams.length - 1]}` : "your team";
  const members = teamOwned(a) && !teams.includes(a.owner_team ?? "") ? ` Members of ${a.owner_team}, whose it is, can open it too.` : "";
  switch (audience) {
    case "everyone":
      return { long: "Everyone in your organisation", note: "Anyone who can sign in to your Troupe plane can open it." };
    case "team":
      return { long: `Everyone on ${named}`, note: `Members of ${named} can open it. People outside ${teams.length > 1 ? "those teams" : "the team"} cannot find it unless it is shared with them.${members}` };
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
  open,
  via,
  daemon,
  daemonState,
  localOnly,
  onOpenSession,
  webApp = null,
}: {
  /** The artifact a `troupe://artifact/` link or the web app's address named, chosen as the gallery opens. */
  open?: string | undefined;
  /** The plane's web app (`plane.app`), for the web line under a copied link. */
  webApp?: string | null;
  via: OwnPlane | null;
  daemon: DaemonClient | null;
  daemonState: { status: "unsupported" | "searching" | "absent" | "connected" | "error"; error: string | null };
  localOnly: boolean;
  /** Open the session an artifact came from: null once it is open, or the sentence saying why it is not. */
  onOpenSession?: ((id: string) => Promise<string | null>) | undefined;
}): JSX.Element {
  const [list, setList] = useState<(ArtifactList & { plane_url?: string }) | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState<Filter>("all");
  const [kind, setKind] = useState<"all" | Artifact["kind"]>("all");
  // Inside Your teams, one team's (its visibility), or all of them.
  const [team, setTeam] = useState("all");
  // Published since … until …, each a day or "" for open; this device's for as long as the app runs.
  const [since, setSince] = useState("");
  const [until, setUntil] = useState("");
  // The one whose Info is open: a link's choice as the gallery opens, else the card's Info.
  const [selected, setSelected] = useState<string | null>(open ?? null);
  const [seen, setSeen] = useState(seenVersions);
  const [asked, setAsked] = useState(0);
  // Why a card's Open did not open it, said above the grid.
  const [notOpened, setNotOpened] = useState<string | null>(null);

  useEffect(() => {
    if (localOnly || !via) return;
    let live = true;
    setError(null);
    via.artifacts({}).then(
      (l) => {
        if (live) setList(l);
      },
      (e: unknown) => live && setError(errorText(e)),
    );
    return () => {
      live = false;
    };
  }, [via, localOnly, asked]);

  const reload = useCallback(() => setAsked((n) => n + 1), []);

  const opened = (id: string, version: number): void => {
    markSeen(id, version);
    setSeen(seenVersions());
  };

  // A card opens the version its address serves, as Open in its Info does.
  const openCard = (a: Artifact): void => {
    if (!via) return;
    setNotOpened(null);
    show(via, a).then(
      () => opened(a.id, a.current ?? a.version),
      (e: unknown) => setNotOpened(`${a.title} did not open: ${errorText(e)}`),
    );
  };

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
  const searched = list.artifacts.filter((a) => matches(a) && (kind === "all" || a.kind === kind) && inRange(a, since, until));
  const audienced = searched.filter((a) => filter === "all" || audienceOf(a) === filter);
  // The teams of what Your teams shows: a choice only where there are two or more.
  const teamsShown = filter === "team" ? [...new Set(audienced.flatMap(audienceTeams))].sort((x, y) => x.localeCompare(y)) : [];
  const byTeam = teamsShown.length > 1 && teamsShown.includes(team) ? team : "all";
  const shown = audienced.filter((a) => byTeam === "all" || audienceTeams(a).includes(byTeam));
  const count = (f: Filter): number => searched.filter((a) => f === "all" || audienceOf(a) === f).length;
  const current = list.artifacts.find((a) => a.id === selected) ?? null;
  // The ones the person keeps at the top form a group above the days; the rest go by when.
  const groups = [
    { day: "Kept at the top", items: shown.filter((a) => a.kept === true) },
    ...(["Today", "This week", "Earlier"] as const).map((day) => ({ day, items: shown.filter((a) => a.kept !== true && dayOf(a.published_at) === day) })),
  ].filter((g) => g.items.length > 0);
  const range = rangeWords(since, until);
  // What narrows the list beside the search, in the empty state's one sentence.
  const narrowedBy = [kind !== "all" ? `among ${KINDS[kind] ?? kind}` : "", byTeam !== "all" ? `for ${byTeam}` : "", range ? `published ${range}` : ""].filter(Boolean).join(" ");
  const widen = [range ? "wider dates" : "", kind !== "all" ? "every kind" : "", byTeam !== "all" ? "all of your teams" : ""].filter(Boolean);

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
        <span className="published-range micro">
          <label>
            Published since <input type="date" value={since} max={until || undefined} onChange={(e) => setSince(e.target.value)} aria-label="Published since" />
          </label>
          <label>
            until <input type="date" value={until} min={since || undefined} onChange={(e) => setUntil(e.target.value)} aria-label="Published until" />
          </label>
        </span>
        <span className="order micro">NEWEST FIRST</span>
      </nav>
      {teamsShown.length > 1 && (
        <nav className="audiences teams-row" aria-label="Which of your teams">
          {["all", ...teamsShown].map((t) => (
            <button key={t} type="button" className="audience is-team" aria-pressed={byTeam === t} onClick={() => setTeam(t)}>
              <span>{t === "all" ? "All of them" : t}</span>
              <span className="n">{audienced.filter((a) => t === "all" || audienceTeams(a).includes(t)).length}</span>
            </button>
          ))}
        </nav>
      )}
      {!list.enabled && <p className="note">An administrator has switched artifacts off on this plane, so there are none to show.</p>}
      {open && selected === open && !current && list.enabled && (
        <p className="note">The artifact the link named is not one published for you here. A link someone shared opens it in a browser first, which gives you its role.</p>
      )}
      {notOpened && (
        <p className="note error" role="alert">
          {notOpened}
        </p>
      )}
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
                  // A click anywhere on the card opens it, since opening is what people come
                  // for; Open and Info over its picture are the keyboard's way to the same two.
                  <article key={a.id} className="card" onClick={() => openCard(a)}>
                    <span className="placeholder-frame">
                      <span className={a.thumbnail_url ? "placeholder has-picture" : "placeholder"} aria-hidden={a.thumbnail_url ? undefined : "true"}>
                        {a.thumbnail_url && <Picture src={a.thumbnail_url} alt={a.title} />}
                        <span className="what" aria-hidden="true">
                          {a.kind} · {bytes(a.bytes)}
                        </span>
                        {fresh && (
                          <span className="fresh" aria-hidden="true">
                            NEW TO YOU
                          </span>
                        )}
                      </span>
                      <span className="card-actions">
                        <button
                          type="button"
                          className="primary card-open"
                          aria-label={`Open ${a.title}`}
                          onClick={(e) => {
                            e.stopPropagation();
                            openCard(a);
                          }}
                        >
                          Open
                        </button>
                        <button
                          type="button"
                          className="card-info"
                          aria-label={`Info about ${a.title}`}
                          onClick={(e) => {
                            e.stopPropagation();
                            setSelected(a.id);
                          }}
                        >
                          Info
                        </button>
                      </span>
                    </span>
                    <span className="body">
                      <span className="title">{a.title}</span>
                      {fresh && <span className="visually-hidden">New to you.</span>}
                      <span className="byline">
                        {whose(a)} · {ago(Date.parse(a.published_at))}
                      </span>
                      <span className="tags">
                        <span className={`audience-pill is-${audience}`}>
                          {AUDIENCE[audience].glyph} {audience === "team" ? (audienceTeams(a)[0] ?? "TEAM").toUpperCase() : AUDIENCE[audience].short}
                        </span>
                        <span className="kind micro">{KIND[a.kind] ?? a.kind.toUpperCase()}</span>
                        {(a.comments ?? 0) > 0 && <span className="kind micro">{a.comments === 1 ? "1 COMMENT" : `${a.comments} COMMENTS`}</span>}
                      </span>
                      {a.goes_at && <span className="byline goes">{goesLine(a)}</span>}
                    </span>
                  </article>
                );
              })}
            </div>
          </section>
        ))}
        {shown.length === 0 && (
          <div className="empty">
            <p className="title">{q ? `Nothing matches “${query.trim()}”${narrowedBy ? ` ${narrowedBy}` : ""}` : narrowedBy ? `Nothing here ${narrowedBy}` : "Nothing here yet"}</p>
            <p className="muted">
              {q
                ? "Try a person's name or the session it came from."
                : widen.length > 0
                  ? `Try ${widen.join(" or ")}.`
                  : "When someone publishes for this audience, it appears here. Publish from any session with /publish."}
            </p>
            {/* Only where something narrows the list: with every audience shown and
                nothing typed it would show what is already shown, which is nothing. */}
            {(q || filter !== "all" || kind !== "all" || range) && (
              <button
                type="button"
                onClick={() => {
                  setFilter("all");
                  setKind("all");
                  setTeam("all");
                  setSince("");
                  setUntil("");
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
        <Info
          key={current.id}
          via={via}
          daemon={daemon}
          artifact={current}
          audience={audienceOf(current)}
          teams={list.teams}
          publishOrganisation={list.publish_organisation}
          onOpened={(version) => opened(current.id, version)}
          onChanged={reload}
          onClose={() => setSelected(null)}
          onOpenSession={onOpenSession}
          planeUrl={list.plane_url ?? null}
          webApp={webApp}
        />
      )}
    </div>
  );
}

/**
 * What the artifacts host blocks in the version its address serves, as the plane read its
 * files at publish: one line, and the references themselves on request.
 */
function Blocked({ artifact, versions }: { artifact: Artifact; versions: ArtifactVersion[] }): JSX.Element | null {
  const line = blockedWords(artifact.blocked_count);
  if (!line) return null;
  const serving = versions.find((v) => v.n === (artifact.current ?? artifact.version)) ?? versions[0];
  const found = serving?.blocked ?? [];
  return (
    <div className="note blocked" role="note">
      <p>{line}</p>
      {found.length > 0 && (
        <details>
          <summary>What is blocked</summary>
          <ul>
            {found.map((b, i) => (
              <li key={i}>
                <code>
                  {b.file}
                  {b.line ? `:${b.line}` : ""}
                </code>{" "}
                {b.reference} ({blockedKindWords(b.kind)})
              </li>
            ))}
          </ul>
        </details>
      )}
    </div>
  );
}

/**
 * The session an artifact came from, opened in the app as its `troupe://session` link opens
 * it; where the plane answers that there is none to open, the line says so instead. Nothing
 * is asked until the click.
 */
function FromSession({ id, onOpen }: { id: string; onOpen: (id: string) => Promise<string | null> }): JSX.Element {
  const [said, setSaid] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  if (said) return <p className="muted from-session">{said}</p>;
  return (
    <p className="muted from-session">
      Published from a session.{" "}
      <button
        type="button"
        className="link"
        disabled={busy}
        onClick={() => {
          setBusy(true);
          void onOpen(id).then((sentence) => {
            setBusy(false);
            setSaid(sentence);
          });
        }}
      >
        {busy ? "Opening…" : "Open session"}
      </button>
    </p>
  );
}

type InfoTab = "overview" | "access" | "versions" | "comments";

/**
 * A native modal dialog, opened with `showModal()`: the browser traps focus in it, makes the
 * page behind it inert and offers Escape. Escape and a click on the backdrop close it here;
 * `onClose` decides whether it may (a dialog of its own open inside it keeps it). A page
 * without `showModal` (a test's) gets it shown open, the same markup.
 */
function Modal({ className, labelledBy, onClose, onShown, children }: { className: string; labelledBy: string; onClose: () => void; onShown: (el: HTMLDialogElement) => void; children: ReactNode }): JSX.Element {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const before = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    if (typeof el.showModal === "function") {
      if (!el.open) el.showModal();
    } else el.setAttribute("open", "");
    onShown(el);
    return () => {
      if (typeof el.close === "function" && el.open) el.close();
      if (before?.isConnected) before.focus();
    };
    // Shown once, as it mounts; closed as it goes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  return (
    <dialog
      ref={ref}
      className={className}
      aria-labelledby={labelledBy}
      onCancel={(e) => {
        e.preventDefault();
        onClose();
      }}
      onKeyDown={(e) => {
        if (e.key !== "Escape") return;
        e.preventDefault();
        e.stopPropagation();
        onClose();
      }}
      onClick={(e) => {
        // The dialog itself is hit only outside its content, on the backdrop.
        if (e.target === e.currentTarget) onClose();
      }}
    >
      {children}
    </dialog>
  );
}

/**
 * The artifact's Info, in a modal dialog of four tabs: Overview (what it is, Open, Copy link,
 * Open in browser, Keep at the top, where it came from), Access (who can see it, who it is
 * shared with, its links, whose it is), Versions, and Comments. Every panel stays drawn while
 * the dialog is open, hidden but for the chosen one, so a draft or a search typed in one is
 * still there after a look at another. An owner's controls are absent for anybody else.
 */
function Info({
  via,
  daemon,
  artifact,
  audience,
  teams,
  publishOrganisation,
  onOpened,
  onChanged,
  onClose,
  onOpenSession,
  planeUrl = null,
  webApp = null,
}: {
  onClose: () => void;
  via: OwnPlane;
  daemon: DaemonClient | null;
  /** The plane the artifact is on, for the `troupe://` line under its link. */
  planeUrl?: string | null;
  /** The plane's web app, for the line under that one. */
  webApp?: string | null;
  artifact: Artifact;
  audience: ArtifactAudience;
  teams: string[] | undefined;
  /** Who may publish to the whole organisation here, which the organisation switch follows. */
  publishOrganisation?: ArtifactList["publish_organisation"] | undefined;
  onOpened: (version: number) => void;
  onChanged: () => void;
  onOpenSession?: ((id: string) => Promise<string | null>) | undefined;
}): JSX.Element {
  const [detail, setDetail] = useState<ArtifactDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [said, setSaid] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [busy, setBusy] = useState(false);
  const [publishing, setPublishing] = useState(false);
  const [asked, setAsked] = useState(0);
  const [giveTo, setGiveTo] = useState(teams?.[0] ?? "");
  const [tab, setTab] = useState<InfoTab>("overview");
  // The thread's length once it is read (the row's count till then); null for a plane with no threads.
  const [commentCount, setCommentCount] = useState<number | null>(artifact.comments ?? 0);
  const id = useId();
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
      (e: unknown) => live && setError(errorText(e)),
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
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  const open = (version?: number): void => {
    setError(null);
    show(via, artifact, version).then(
      () => onOpened(version ?? detail?.current ?? artifact.current ?? artifact.version),
      (e: unknown) => setError(errorText(e)),
    );
  };

  // Its owner's link is a view link made now, shown once; anybody else's is its address, which signs them in.
  // Under it, the app's own link to the same artifact, which carries no part of the link's
  // key: it opens the artifact in the app for whoever may see it already; and the web app at
  // it, for somebody without the app.
  const copy = async (): Promise<void> => {
    setError(null);
    try {
      const url = owner ? (await via.shareArtifact(artifact.id, "view")).url : artifact.url;
      await copyText(artifactLinkText(url, artifact.id, planeUrl, webApp));
      setCopied(true);
      if (owner) setAsked((n) => n + 1);
    } catch (e) {
      setError(`Not copied: ${errorText(e)}`);
    }
  };

  // Its address in the person's browser, which signs them in; a shell that refuses says why here.
  const browse = (): void => {
    setError(null);
    openExternal(artifact.url).catch((e: unknown) => setError(`Not opened: ${errorText(e)}`));
  };

  const words = audienceWords(artifact, audience);
  const versions = detail?.versions ?? [];
  const pinned = detail?.pinned ?? artifact.pinned ?? null;
  const shares = (detail?.shares ?? []).filter((s) => s.state === "live");
  const summary = versions[0]?.note ?? null;

  // A count where one helps: how many versions it keeps, once read, and how long its thread is.
  const tabs: Array<{ key: InfoTab; label: string; count?: number | undefined }> = [
    { key: "overview", label: "Overview" },
    { key: "access", label: "Access" },
    { key: "versions", label: "Versions", count: detail ? versions.length : undefined },
    ...(commentCount === null ? [] : [{ key: "comments" as const, label: "Comments", count: commentCount }]),
  ];
  const tabId = (k: InfoTab): string => `${id}-tab-${k}`;
  const panelId = (k: InfoTab): string => `${id}-panel-${k}`;
  const choose = (k: InfoTab, dialog?: HTMLElement | null): void => {
    setTab(k);
    (dialog ?? document).querySelector<HTMLElement>(`[id="${tabId(k)}"]`)?.focus();
  };
  // Left and right move between the tabs, Home and End to the first and the last.
  const onTabKey = (e: ReactKeyboardEvent<HTMLElement>): void => {
    const at = tabs.findIndex((t) => t.key === tab);
    const to = e.key === "ArrowRight" ? (at + 1) % tabs.length : e.key === "ArrowLeft" ? (at - 1 + tabs.length) % tabs.length : e.key === "Home" ? 0 : e.key === "End" ? tabs.length - 1 : -1;
    if (to < 0) return;
    e.preventDefault();
    choose(tabs[to]!.key, e.currentTarget.closest("dialog"));
  };
  const panel = (k: InfoTab): { id: string; role: "tabpanel"; "aria-labelledby": string; hidden: boolean; className: string } => ({
    id: panelId(k),
    role: "tabpanel",
    "aria-labelledby": tabId(k),
    hidden: tab !== k,
    className: "info-panel",
  });

  return (
    <Modal
      className="dialog artifact-info"
      labelledBy={`${id}-title`}
      // Publishing a version is a dialog of its own inside this one: it closes first.
      onClose={() => {
        if (!publishing) onClose();
      }}
      onShown={(el) => el.querySelector<HTMLElement>('[role="tab"][aria-selected="true"]')?.focus()}
    >
      <div className="info-head">
        <div className="micro what">
          {KIND[artifact.kind] ?? artifact.kind.toUpperCase()} · VERSION {artifact.version} · {bytes(artifact.bytes)}
        </div>
        <h2 id={`${id}-title`}>{artifact.title}</h2>
        <button type="button" className="link info-close" onClick={onClose}>
          Close
        </button>
        <div className="tabs" role="tablist" aria-label="About this artifact" onKeyDown={onTabKey}>
          {tabs.map((t) => (
            <button
              key={t.key}
              type="button"
              role="tab"
              className="tab"
              id={tabId(t.key)}
              aria-controls={panelId(t.key)}
              aria-selected={tab === t.key}
              tabIndex={tab === t.key ? 0 : -1}
              onClick={() => setTab(t.key)}
            >
              {t.label}
              {t.count !== undefined && <span className="n"> {t.count}</span>}
            </button>
          ))}
        </div>
      </div>
      {error && <p className="note error">{error}</p>}
      {said && (
        <p className="note" role="status">
          {said}
        </p>
      )}

      <div {...panel("overview")}>
        {summary && <p className="summary">{summary}</p>}
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
          {/* The person's own gallery's: on the plane, so every device and app of theirs shows
              it at the top. A plane that does not say `kept` keeps none, so there is no choice. */}
          {artifact.kept !== undefined && (
            <button
              type="button"
              disabled={busy}
              onClick={() =>
                void act(
                  () => via.keepArtifact(artifact.id, !artifact.kept),
                  artifact.kept ? "Let go: it is back under when it was published." : "Kept at the top of your gallery, on every device you sign in on.",
                )
              }
            >
              {artifact.kept ? "Let go from the top" : "Keep at the top"}
            </button>
          )}
        </div>
        {(detail ?? artifact).goes_at && <p className="muted goes">{goesSentence(detail ?? artifact)}</p>}
        <Blocked artifact={detail ?? artifact} versions={versions} />

        <section>
          <h3 className="screen">Where it came from</h3>
          <dl className="origin">
            <dt>BY</dt>
            <dd>{who(artifact.owner, artifact.mine && !ofTeam)}</dd>
            {artifact.origin?.session_id && (
              <>
                <dt>SESSION</dt>
                <dd className="mono">{artifact.origin.session_id}</dd>
              </>
            )}
            {artifact.origin?.profile && (
              <>
                <dt>PROFILE</dt>
                <dd className="profile">{artifact.origin.profile}</dd>
              </>
            )}
          </dl>
          {artifact.origin?.session_id && onOpenSession && <FromSession id={artifact.origin.session_id} onOpen={onOpenSession} />}
        </section>
      </div>

      <div {...panel("access")}>
        <section>
          <h3 className="screen">Who can see it</h3>
          <p className={`audience-line is-${audience}`}>
            {AUDIENCE[audience].glyph} {words.long}
          </p>
          <p className="muted">{words.note}</p>
          {owner && (
            <AccessMenu
              via={via}
              artifact={artifact}
              organisationAllowed={publishOrganisation !== "platform_admins" || artifact.visibility === "organisation"}
              onChanged={() => {
                setAsked((n) => n + 1);
                onChanged();
              }}
            />
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
      </div>

      <div {...panel("versions")}>
        <section>
          <h3 className="screen">Versions</h3>
          {!detail && !error && <Loading what="Reading its versions…" />}
          {pinned !== null && <p className="muted micro">Its address serves version {pinned}, pinned by its owner.</p>}
          {detail && versionsSentence(detail) && <p className="muted micro">{versionsSentence(detail)}</p>}
          <ol className="versions">
            {versions.map((v, i) => (
              <li key={v.n} className={i === 0 ? "newest" : undefined}>
                <span className="n">v{v.n}</span>
                <span className="note-text">{v.note ?? (v.n === 1 ? "First publish" : "")}</span>
                <span className="micro" title={v.published_at}>
                  {ago(Date.parse(v.published_at))}
                </span>
                {v.goes_at && <span className="micro goes">{versionGoes(v)}</span>}
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
      </div>

      {/* Drawn while the dialog is open, so a draft survives a look at another tab; a plane
          from before threads has no tab for it. */}
      <div {...panel("comments")} hidden={tab !== "comments" || commentCount === null}>
        <Thread via={via} artifact={artifact} onRead={setCommentCount} />
      </div>

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
    </Modal>
  );
}

/** A person in the Access menu's draft: who, and the role they will have once it is saved. */
interface Reader {
  subject: string;
  display_name?: string | null;
  role: ArtifactShareRole;
}

/** Whether two lists of names hold the same names, in any order. */
function sameNames(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((x) => b.includes(x));
}

/**
 * Who reads it, as its owner changes it: one menu over the set, saved at once. The teams as
 * checkboxes, those granted the profile its session ran on first and then the owner's other
 * teams, and a team that reads it but is neither shown as it is, with why; the people it is
 * shared with by name at their roles, and the picker that adds somebody (people who share a
 * team with the owner, and those its session's profile covers); the organisation switch where
 * the plane allows it. Save sends the whole of each part changed (`artifact.access.set`),
 * which the plane applies as the difference and makes no version of, and says what changed;
 * a refusal is said here and the draft kept, and a change from a sensitive session that waits
 * on a team administrator says so.
 */
function AccessMenu({ via, artifact, organisationAllowed, onChanged }: { via: OwnPlane; artifact: Artifact; organisationAllowed: boolean; onChanged: () => void }): JSX.Element {
  const [access, setAccess] = useState<ArtifactAccess | null>(null);
  const [granted, setGranted] = useState<string[]>([]);
  const [teams, setTeams] = useState<string[]>([]);
  const [people, setPeople] = useState<Reader[]>([]);
  const [organisation, setOrganisation] = useState(false);
  const [query, setQuery] = useState("");
  const [found, setFound] = useState<Person[]>([]);
  const [role, setRole] = useState<ArtifactShareRole>("view");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [said, setSaid] = useState<string | null>(null);
  const [asked, setAsked] = useState(0);
  const profile = artifact.origin?.profile ?? null;

  const take = (a: ArtifactAccess): void => {
    setAccess(a);
    setTeams(a.teams.map((t) => t.name));
    setPeople(a.people.map((p) => ({ subject: p.subject, display_name: p.display_name ?? null, role: p.role })));
    setOrganisation(a.organisation);
  };

  useEffect(() => {
    let live = true;
    via.artifactAccess(artifact.id).then(
      (a) => live && take(a),
      (e: unknown) => live && setError(errorText(e)),
    );
    return () => {
      live = false;
    };
  }, [via, artifact.id, asked]);

  // The teams granted the profile its session ran on, which come first: none for one no pod session published.
  useEffect(() => {
    if (!profile) return;
    let live = true;
    via.profileTeams(profile).then(
      (r) => live && setGranted(r.teams),
      () => live && setGranted([]),
    );
    return () => {
      live = false;
    };
  }, [via, profile]);

  useEffect(() => {
    const q = query.trim();
    if (q === "") return setFound([]);
    let live = true;
    const t = setTimeout(() => {
      via.searchPeople(q, { artifact: artifact.id }).then(
        (r) => live && setFound(r.people.filter((p) => !people.some((s) => s.subject === p.subject))),
        () => live && setFound([]),
      );
    }, 150);
    return () => {
      live = false;
      clearTimeout(t);
    };
  }, [via, artifact.id, query, people.length]);

  if (!access) return error ? <p className="note error">{error}</p> : <Loading what="Reading who reads it…" />;

  const mayAdd = access.may_add;
  const ordered = [...granted.filter((t) => mayAdd.includes(t)), ...mayAdd.filter((t) => !granted.includes(t))];
  // A team that reads it but that the owner may not give it to (a platform admin's doing, or a team they left).
  const fixed = access.teams.map((t) => t.name).filter((t) => !mayAdd.includes(t));
  const had = access.people;
  const change: ArtifactAccessChange = {
    ...(sameNames(teams, access.teams.map((t) => t.name)) ? {} : { teams }),
    ...(people.length === had.length && people.every((p) => had.some((h) => h.subject === p.subject && h.role === p.role)) ? {} : { people: people.map((p) => ({ subject: p.subject, role: p.role })) }),
    ...(organisation === access.organisation ? {} : { organisation }),
  };
  const changed = Object.keys(change).length > 0;
  const name = (p: { subject: string; display_name?: string | null }): string => p.display_name || p.subject;

  const save = async (): Promise<void> => {
    setBusy(true);
    setError(null);
    setSaid(null);
    try {
      const answer = await via.setArtifactAccess(artifact.id, change);
      if (accessWaiting(answer)) {
        setSaid(`Not changed yet: ${answer.reason}.`);
        take(access);
      } else {
        const names = new Map(people.map((p) => [p.subject, name(p)] as const));
        setSaid(`Saved: ${accessChanges(access, change, names)}. It is ${artifactAccessWords(answer)} now.`);
        take(answer);
        onChanged();
      }
    } catch (e) {
      setError(errorText(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="shared-with access-menu">
      <h4 className="micro">WHO READS IT</h4>
      <p className="muted">It is {artifactAccessWords(access)}. A new version keeps who reads it; changing it here makes no version.</p>
      <fieldset className="teams" disabled={busy}>
        <legend className="micro">TEAMS</legend>
        {ordered.map((t) => (
          <label key={t} className="inline">
            <input type="checkbox" checked={teams.includes(t)} onChange={(e) => setTeams((now) => (e.target.checked ? [...now, t] : now.filter((x) => x !== t)))} /> The {t} team
            {granted.includes(t) && profile && <span className="muted micro"> · granted {profile}, which its session ran on</span>}
          </label>
        ))}
        {fixed.map((t) => (
          <label key={t} className="inline">
            <input type="checkbox" checked disabled /> The {t} team
            <span className="muted micro"> · shown as it is: you are not in it and {profile ? `${profile} is not granted to it` : "no session's profile grants it"}, so it is not yours to change here</span>
          </label>
        ))}
        {ordered.length === 0 && fixed.length === 0 && <p className="muted">No team of yours is known here.</p>}
      </fieldset>
      {(organisationAllowed || organisation) && (
        <label className="inline">
          <input type="checkbox" checked={organisation} disabled={busy} onChange={(e) => setOrganisation(e.target.checked)} /> The whole organisation: anyone who can sign in to your Troupe plane
        </label>
      )}
      <h4 className="micro">PEOPLE</h4>
      {people.length === 0 ? (
        <p className="muted">Nobody by name. Pick somebody below, or make a link.</p>
      ) : (
        <ul className="links" aria-label="Shared with">
          {people.map((p) => (
            <li key={p.subject}>
              <span>{name(p)}</span>
              <select aria-label={`What ${name(p)} may do`} value={p.role} disabled={busy} onChange={(e) => setPeople((now) => now.map((x) => (x.subject === p.subject ? { ...x, role: e.target.value as ArtifactShareRole } : x)))}>
                {ROLES.map((r) => (
                  <option key={r.role} value={r.role}>
                    {r.label}
                  </option>
                ))}
              </select>
              <button type="button" className="link" disabled={busy} aria-label={`Remove ${name(p)}`} onClick={() => setPeople((now) => now.filter((x) => x.subject !== p.subject))}>
                Remove
              </button>
            </li>
          ))}
        </ul>
      )}
      <div className="move-visibility">
        <label>
          Add somebody
          <input value={query} disabled={busy} onChange={(e) => setQuery(e.target.value)} placeholder="A name or an email" />
        </label>
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
      </div>
      {found.length > 0 && (
        <ul className="people" aria-label="People">
          {found.map((p) => (
            <li key={p.subject}>
              <button
                type="button"
                className="tab"
                onClick={() => {
                  setPeople((now) => [...now, { subject: p.subject, display_name: p.display_name ?? null, role }]);
                  setQuery("");
                }}
              >
                {name(p)}
                {p.email && p.email !== name(p) ? ` · ${p.email}` : ""}
              </button>
            </li>
          ))}
        </ul>
      )}
      {query.trim() !== "" && found.length === 0 && <p className="muted micro">Nobody you can share with has a name that starts with that.</p>}
      <div className="actions">
        <button type="button" className="primary" disabled={busy || !changed} onClick={() => void save()}>
          {busy ? "Saving…" : "Save who reads it"}
        </button>
        {changed && (
          <button type="button" className="link" disabled={busy} onClick={() => take(access)}>
            Undo changes
          </button>
        )}
      </div>
      {changed && <p className="muted micro">Not saved yet: {accessChanges(access, change, new Map(people.map((p) => [p.subject, name(p)] as const)))}.</p>}
      {error && (
        <p className="note error" role="alert">
          Not saved: {error}
        </p>
      )}
      {said && (
        <p className="note" role="status">
          {said}
        </p>
      )}
      {said?.startsWith("Not changed yet") && (
        <button type="button" className="link" onClick={() => setAsked((n) => n + 1)}>
          Read it again
        </button>
      )}
    </div>
  );
}

/**
 * The artifact's thread, oldest first, each comment with who wrote it and when; a box to
 * write one for whoever the plane says may (its owners, and anybody given comment or edit).
 * The session it came from is told of each, so whoever steers it can ask its agent to act.
 * Its author edits a comment (marked edited) and deletes it; an owner, or whoever may take
 * the artifact down, deletes any. Each control is there only for whoever may use it.
 */
function Thread({ via, artifact, onRead }: { via: OwnPlane; artifact: Artifact; onRead: (count: number | null) => void }): JSX.Element {
  const [thread, setThread] = useState<ArtifactThread | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [asked, setAsked] = useState(0);
  const [absent, setAbsent] = useState(false);
  const [editing, setEditing] = useState<string | null>(null);
  const [editDraft, setEditDraft] = useState("");
  const [confirming, setConfirming] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    via.artifactComments(artifact.id).then(
      (t) => {
        if (!live) return;
        setThread(t);
        onRead(t.comments.length);
      },
      (e: unknown) => {
        if (!live) return;
        // A plane from before comments has no thread to show, which is no fault.
        if ((e as { code?: unknown } | null)?.code === -32601) {
          setAbsent(true);
          onRead(null);
        } else setError(errorText(e));
      },
    );
    return () => {
      live = false;
    };
    // `onRead` is the dialog's setter, the same on every render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
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
      setError(`Not posted: ${errorText(e)}`);
    } finally {
      setBusy(false);
    }
  };

  // A comment's own controls, offered only where the plane says this person may: their own
  // to edit, and their own (or any, for an owner or whoever may take the artifact down) to
  // delete. Deleting asks once, saying what it does.
  const remove = async (comment: string): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      await via.deleteArtifactComment(artifact.id, comment);
      setConfirming(null);
      setAsked((n) => n + 1);
    } catch (e) {
      setError(`Not deleted: ${errorText(e)}`);
    } finally {
      setBusy(false);
    }
  };

  const save = async (comment: string): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      await via.editArtifactComment(artifact.id, comment, editDraft);
      setEditing(null);
      setAsked((n) => n + 1);
    } catch (e) {
      setError(`Not saved: ${errorText(e)}`);
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
                <span title={c.created_at}>{ago(Date.parse(c.created_at))}</span>
                {c.edited_at && (
                  <>
                    {" "}
                    · <span title={c.edited_at}>edited {ago(Date.parse(c.edited_at))}</span>
                  </>
                )}
              </p>
              {editing === c.id ? (
                <form
                  className="comment-form"
                  onSubmit={(e) => {
                    e.preventDefault();
                    if (editDraft.trim() !== "") void save(c.id);
                  }}
                >
                  <label>
                    <span className="visually-hidden">Edit your comment</span>
                    <textarea value={editDraft} maxLength={thread?.max_length} disabled={busy} onChange={(e) => setEditDraft(e.target.value)} rows={3} />
                  </label>
                  <div className="comment-edit-actions">
                    <button type="submit" disabled={busy || editDraft.trim() === ""}>
                      Save
                    </button>
                    <button type="button" className="link" disabled={busy} onClick={() => setEditing(null)}>
                      Cancel
                    </button>
                  </div>
                </form>
              ) : (
                <p className="comment-body">{c.body}</p>
              )}
              {confirming === c.id ? (
                <p className="micro" role="group" aria-label="Delete this comment?">
                  It goes from the thread for everybody, and cannot be brought back.{" "}
                  <button type="button" className="danger" disabled={busy} onClick={() => void remove(c.id)}>
                    Delete
                  </button>{" "}
                  <button type="button" className="link" disabled={busy} onClick={() => setConfirming(null)}>
                    Keep it
                  </button>
                </p>
              ) : (
                editing !== c.id &&
                (c.may_edit || c.may_delete) && (
                  <p className="micro comment-actions">
                    {c.may_edit && (
                      <button
                        type="button"
                        className="link"
                        disabled={busy}
                        onClick={() => {
                          setEditing(c.id);
                          setEditDraft(c.body);
                        }}
                      >
                        Edit
                      </button>
                    )}{" "}
                    {c.may_delete && (
                      <button type="button" className="link" disabled={busy} onClick={() => setConfirming(c.id)}>
                        Delete
                      </button>
                    )}
                  </p>
                )
              )}
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
