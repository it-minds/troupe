// Artifacts: for an administrator, every artifact the plane holds that their role answers
// for (`admin.artifacts.list`: every one for a platform admin, a person's private ones too,
// their teams' for a team admin), first, with a takedown on each row; then, as for
// everybody who signs in, the pages and files a person, their organisation, their teams and
// their profiles' people have published, as tabs: Mine (the private ones among them), one for
// those a link gave them, one for the organisation's, one for their teams' (one list, the
// team named on each card) and one for each profile they are covered by; a card for each,
// and a page for one with its versions, newest first. Which tab a row is under is the
// plane's to say (`scope`), not this console's to work out.
//
// An administrator who opens an artifact that is not theirs reads its page as its
// administrator (`admin.artifact.get`): its links, who it is shared with and its comments
// too, a private one's as well, and the audit records each read. What its files hold stays
// its owner's and their links' holders': the page says so where it cannot be opened.
//
// An artifact is never drawn here. Its card is its title and its kind, with the picture its
// publisher sent where there is one (an image from the artifacts host), and its page says
// what it is and where it came from; opening it asks the plane for a one-time link at the
// moment it is opened, and the artifacts host shows it in a tab of its own that has no hold
// on this one. A published page's HTML or Markdown is a stranger's code to this console.
// The tab is opened at the click, before the plane answers, so a browser that blocks a tab
// opened later lets this one through. An edit's preview is the host's too, framed and
// sandboxed (`ArtifactEditor`).
//
// Beyond those two, nothing here is an administrative call: `artifact.*` are what any
// client of the person's asks the plane as that person. Deleting is the owner's, or a takedown of somebody else's
// by a platform admin or the admin of the team it is for, which the confirm says it is. A new version (an edit, a rollback) is the
// owner's or an edit link's holder's; pinning the version its address serves, and the links
// (`ArtifactLinks`), are the owner's. An artifact a team owns is every member's: the plane
// says so per row (`mine`, `role`), and the page says the team is whose it is. The owning
// person gives one of theirs to a team they are in, and an admin of the owning team takes
// it back (`artifact.transfer`). A link somebody followed lands on `#/artifacts/link/
// <token>`, which spends it as the person signed in here and goes on to the artifact.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { ArtifactApi, TroupeRpcError, appLink, blockedKindWords, blockedWords, bytes, ownerWords, teamOwned, visibilityWords as audienceWords } from "@troupe/client";
import { OpenInApp } from "./OpenInApp";
import type { AdminArtifactPage, Artifact, ArtifactDetail, ArtifactFilter, ArtifactList, ArtifactPerson } from "@troupe/client";
import { goesLine, goesSentence, versionGoes, versionsSentence } from "@troupe/client";
import { describeError, useConsole, useLoad } from "../console";
import { go, href } from "../route";
import type { Route } from "../route";
import { ArtifactEditor, editableFiles } from "./ArtifactEditor";
import { ArtifactComments, ArtifactPeople } from "./ArtifactComments";
import { ArtifactLinks } from "./ArtifactLinks";
import { AuditedPeople, AuditedThread } from "./ArtifactAudit";
import { PublishedArtifacts } from "./PublishedArtifacts";
import { FromSession } from "./SessionLink";
import { Empty, Fields, Loaded, Preview, Region, Status, count, when } from "./bits";

/** Which artifacts a tab lists: `every` is every one an administrator answers for, which a member's console shows as their own. */
export type ArtifactTab = { kind: "every" } | { kind: "mine" } | { kind: "shared" } | { kind: "organisation" } | { kind: "teams" } | { kind: "profile"; name: string };

/**
 * What an address under `#/artifacts` names: a tab (none for every artifact, `mine`,
 * `shared`, `organisation`, `profile/<name>`), a link somebody followed (`link/<token>`), an
 * artifact to go straight on to once signed in (`open/<id>[/v<n>]`, where the artifacts host
 * sends a signed-out viewer of it), or one artifact by its id, which the plane never makes
 * one of those words.
 */
export function artifactPlace(path: string[]): { tab: ArtifactTab } | { id: string } | { link: string } | { open: { id: string; version?: number } } {
  const [first, second, third] = path;
  if (!first) return { tab: { kind: "every" } };
  if (first === "mine") return { tab: { kind: "mine" } };
  if (first === "shared") return { tab: { kind: "shared" } };
  if (first === "organisation") return { tab: { kind: "organisation" } };
  if (first === "teams") return { tab: { kind: "teams" } };
  if (first === "profile" && second) return { tab: { kind: "profile", name: second } };
  if (first === "link" && second) return { link: second };
  if (first === "open" && second) {
    const version = third && /^v[1-9]\d*$/.test(third) ? Number(third.slice(1)) : undefined;
    return { open: version === undefined ? { id: second } : { id: second, version } };
  }
  return { id: first };
}

function routeOf(tab: ArtifactTab): Route {
  if (tab.kind === "every") return { page: "artifacts" };
  if (tab.kind === "mine") return { page: "artifacts", path: ["mine"] };
  if (tab.kind === "shared") return { page: "artifacts", path: ["shared"] };
  if (tab.kind === "organisation") return { page: "artifacts", path: ["organisation"] };
  if (tab.kind === "teams") return { page: "artifacts", path: ["teams"] };
  return { page: "artifacts", path: ["profile", tab.name] };
}

function filterOf(tab: ArtifactTab): ArtifactFilter {
  // Every artifact is the administrators' table; the person's own list is still asked, for
  // the tabs it names (their profiles) and whether artifacts are on.
  if (tab.kind === "mine" || tab.kind === "every") return { mine: true };
  if (tab.kind === "shared") return { shared: true };
  if (tab.kind === "organisation") return { visibility: "organisation" };
  if (tab.kind === "teams") return { teams: true };
  return { visibility: `profile:${tab.name}` };
}

function same(a: ArtifactTab, b: ArtifactTab): boolean {
  return a.kind === b.kind && (a.kind !== "profile" || (b.kind === "profile" && a.name === b.name));
}

const KIND: Record<string, string> = { html: "HTML page", markdown: "Markdown", file: "File" };

/** What an artifact is, in the words its kind has here: an HTML page, Markdown, a file. */
export function kindWords(kind: string): string {
  return KIND[kind] ?? kind;
}

/** Who may open it, in words: a private one is its owner's, and whoever a link of theirs reached. */
function visibilityWords(a: Artifact): string {
  if (a.visibility === "private") {
    if (teamOwned(a)) return `the ${a.owner_team} team, whose it is, and whoever ${a.mine ? "you" : "they"} give a link`;
    return a.mine ? "only you, and whoever you give a link" : "its owner alone, and whoever they gave a link";
  }
  const words = audienceWords(a.visibility);
  return teamOwned(a) && a.visibility !== `team:${a.owner_team}` ? `${words}, and the ${a.owner_team} team, whose it is` : words;
}

function personWords(p: ArtifactPerson | null | undefined): string {
  if (!p) return "—";
  return p.display_name && p.display_name !== p.subject ? `${p.display_name} (${p.subject})` : p.subject;
}

function useArtifacts(): ArtifactApi {
  const { auth } = useConsole();
  return new ArtifactApi((m, p) => auth.rpc(m, p));
}

/** Said where an administrator switched artifacts off. */
function SwitchedOff(): JSX.Element {
  return (
    <section className="banner locked" role="note" aria-label="Artifacts are switched off">
      <Status kind="dormant" glyph="◆">
        Switched off
      </Status>
      <p>An administrator has switched artifacts off on this plane: nothing is published or opened here until they are switched on again.</p>
    </section>
  );
}

export function Artifacts({ tab: asked }: { tab: ArtifactTab }): JSX.Element {
  const { auth, role } = useConsole();
  // A member answers for nobody's artifacts but their own, so their first tab is Mine.
  const tab: ArtifactTab = asked.kind === "every" && role === "member" ? { kind: "mine" } : asked;
  const key = tab.kind === "profile" ? `profile:${tab.name}` : tab.kind;
  const [load, reload] = useLoad(() => new ArtifactApi((m, p) => auth.rpc(m, p)).list(filterOf(tab)), [auth, key]);
  return (
    <div className="page artifacts">
      <p className="lead">
        {role === "member"
          ? "The pages and files published on this plane that you may open: your own, your organisation's, your teams', and those of each profile you work in."
          : role === "platform_admin"
            ? "Every page and file published on this plane, people's private ones included, with a takedown for each; then, in the tabs, those you may open as anybody may: your own, your organisation's, your teams', and those of each profile you work in."
            : "Every page and file published for the teams you administer, with a takedown for each; then, in the tabs, those you may open as anybody may: your own, your organisation's, your teams', and those of each profile you work in."}
      </p>
      <Loaded load={load} what="the artifacts" retry={reload}>
        {(list) => (list.enabled ? <Gallery tab={tab} list={list} /> : <SwitchedOff />)}
      </Loaded>
    </div>
  );
}

function Gallery({ tab, list }: { tab: ArtifactTab; list: ArtifactList }): JSX.Element {
  const { role } = useConsole();
  const tabs: Array<{ tab: ArtifactTab; label: string }> = [
    ...(role === "member" ? [] : [{ tab: { kind: "every" } as ArtifactTab, label: "Every artifact" }]),
    { tab: { kind: "mine" }, label: "Mine" },
    { tab: { kind: "shared" }, label: "Shared with you" },
    { tab: { kind: "organisation" }, label: "Organisation" },
    { tab: { kind: "teams" }, label: "Teams" },
    ...list.profiles.map((name) => ({ tab: { kind: "profile" as const, name }, label: name })),
  ];
  return (
    <>
      <nav className="tabs" aria-label="Whose artifacts">
        {tabs.map((t) => (
          <a key={t.label} href={href(routeOf(t.tab))} aria-current={same(t.tab, tab) ? "page" : undefined}>
            {t.label}
          </a>
        ))}
      </nav>
      {tab.kind === "every" ? (
        <PublishedArtifacts />
      ) : list.artifacts.length === 0 ? (
        <Empty title={tab.kind === "mine" ? "You have published nothing yet" : tab.kind === "shared" ? "Nothing is shared with you yet" : tab.kind === "teams" ? "Nothing published for a team of yours yet" : "Nothing published here yet"}>
          {tab.kind === "mine" && (
            <p>
              You publish a page or a file with the desktop app's Publish…, the terminal's <code>{"/publish <file>"}</code>, or an agent of yours with its <code>publish_artifact</code> tool.
            </p>
          )}
          {tab.kind === "shared" && <p>Somebody shares an artifact with you by name, and it shows here at once; or by sending its link, and it shows here once you have opened it.</p>}
          {tab.kind === "organisation" && list.publish_organisation === "platform_admins" && <p>Only a platform admin may publish to the whole organisation here.</p>}
        </Empty>
      ) : (
        <ul className="artifact-cards" aria-label="Artifacts">
          {list.artifacts.map((a) => (
            <Card key={a.id} artifact={a} />
          ))}
        </ul>
      )}
    </>
  );
}

/**
 * A card: the picture its publisher sent where there is one, the title and the kind, and what
 * it is beneath. Never its content: the picture is an image the artifacts host serves.
 */
function Card({ artifact: a }: { artifact: Artifact }): JSX.Element {
  const { plane } = useConsole();
  const [pictured, setPictured] = useState(true);
  useEffect(() => setPictured(true), [a.thumbnail_url]);
  return (
    <li className="artifact-card">
      <a className="thumb" href={href({ page: "artifacts", path: [a.id] })}>
        {a.thumbnail_url && pictured && (
          <img className="thumb-picture" src={a.thumbnail_url} alt={a.title} loading="lazy" referrerPolicy="no-referrer" onError={() => setPictured(false)} />
        )}
        <span className="thumb-title">{a.title}</span>
        <span className="thumb-kind">{kindWords(a.kind)}</span>
      </a>
      <p className="card-meta">
        {teamOwned(a) ? `the ${a.owner_team} team's` : a.mine ? "yours" : (a.owner.display_name ?? a.owner.subject)} · version {a.version} · {bytes(a.bytes)}
      </p>
      <p className="card-meta">
        {a.mine || a.visibility.startsWith("team:") ? `for ${visibilityWords(a)} · ` : ""}published {when(a.published_at)}
      </p>
      {(a.public || a.pinned || a.role === "edit") && (
        <p className="card-meta">
          {[a.public ? "public link" : null, a.pinned ? `pinned to version ${a.pinned}` : null, a.role === "edit" ? "you may edit it" : null].filter(Boolean).join(" · ")}
        </p>
      )}
      {a.goes_at && <p className="card-meta">{goesLine(a)}</p>}
      <p className="card-meta">
        <OpenInApp link={appLink({ kind: "artifact", id: a.id, plane: plane.url })} />
      </p>
    </li>
  );
}

const NOT_FOUND = -32005;

/** One artifact: what it is, where it came from, its versions, and the way to open it. */
export function ArtifactPage({ id }: { id: string }): JSX.Element {
  const { auth, admin, role } = useConsole();
  const [load, reload] = useLoad(async (): Promise<{ artifact: ArtifactDetail; audit: AdminArtifactPage | null } | null> => {
    // One that does not exist and one this person may not see are the same answer.
    const missing = (e: unknown): null => {
      if (e instanceof TroupeRpcError && e.code === NOT_FOUND) return null;
      throw e;
    };
    const own = await new ArtifactApi((m, p) => auth.rpc(m, p)).get(id).catch(missing);
    if (own?.mine || role === "member") return own && { artifact: own, audit: null };
    // Somebody else's, to an administrator: its page as its administrator reads it, which
    // the audit records, or as anybody reads it where their role does not answer for it.
    const audit = await admin.artifactPage(id).catch(missing);
    if (audit) return { artifact: audit, audit };
    return own && { artifact: own, audit: null };
  }, [auth, admin, role, id]);
  return (
    <div className="page artifact">
      <Loaded load={load} what="the artifact" retry={reload}>
        {(found) =>
          found === null ? (
            <Empty title="No such artifact">
              It does not exist, it was deleted, or it is not one you may open. <a href={href({ page: "artifacts", path: ["mine"] })}>Your artifacts</a>
            </Empty>
          ) : (
            <Detail artifact={found.artifact} audit={found.audit} reload={reload} />
          )
        }
      </Loaded>
    </div>
  );
}

/**
 * What the artifacts host blocks in the version its address serves, as the plane read its
 * files at publish: one line, and the references themselves on request.
 */
function Blocked({ artifact: a, current }: { artifact: ArtifactDetail; current: number }): JSX.Element | null {
  const line = blockedWords(a.blocked_count);
  if (!line) return null;
  const found = a.versions.find((v) => v.n === current)?.blocked ?? [];
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
 * `audit` is the page as its administrator reads it, for somebody else's: then its links and
 * who it is shared with are listed to read, and where its administrator may not open it as
 * anybody may (another person's private one), nothing on the page asks the plane as them.
 */
function Detail({ artifact: a, audit, reload }: { artifact: ArtifactDetail; audit: AdminArtifactPage | null; reload: () => void }): JSX.Element {
  const { me, notify, reserveTab, plane } = useConsole();
  const reach = audit === null || audit.may_open;
  const api = useArtifacts();
  const [opening, setOpening] = useState<string | null>(null);
  const [error, setError] = useState<unknown>(null);
  // What failed, for the sentence: opening it, or something done to it.
  const [failed, setFailed] = useState("open it");
  const [deleting, setDeleting] = useState(false);
  const [editing, setEditing] = useState(false);
  const [switched, setSwitched] = useState<string>("current");
  const [acting, setActing] = useState(false);
  const myTeams = me.teams.map((t) => t.name);
  const [giveTo, setGiveTo] = useState(myTeams[0] ?? "");
  const takedown = !a.mine;
  const ofTeam = teamOwned(a);
  // The owning person gives it to a team of theirs; an admin of the owning team takes it back.
  const mayGive = reach && !ofTeam && a.may_transfer === true && myTeams.length > 0;
  const mayTakeBack = reach && ofTeam && a.may_transfer === true;
  const versions = [...a.versions].sort((x, y) => y.n - x.n);
  const current = a.current ?? a.version;
  const editable = reach && a.may_edit === true && (a.kind === "html" || a.kind === "markdown") && editableFiles(versions[0]?.files ?? []).length > 0;

  // The link is asked for at the click, since it is good once and for a minute; the tab is
  // opened in the click itself, so a popup blocker lets it through, and pointed at the link
  // when the plane answers, or closed if it refuses.
  const open = (version?: number): void => {
    const what = version === undefined ? "latest" : `v${version}`;
    const tab = reserveTab();
    setOpening(what);
    setError(null);
    setFailed("open it");
    api.open(a.id, version).then(
      (ticket) => {
        setOpening(null);
        tab(ticket.url);
      },
      (e: unknown) => {
        tab(null);
        setOpening(null);
        setError(e);
      },
    );
  };

  const act = (work: Promise<unknown>, done: string, doing = "change it"): void => {
    setActing(true);
    setError(null);
    setFailed(doing);
    work.then(
      () => {
        setActing(false);
        notify(done);
        reload();
      },
      (e: unknown) => {
        setActing(false);
        setError(e);
      },
    );
  };

  return (
    <>
      <header className="artifact-head">
        <h2>{a.title}</h2>
        <span className="mono muted">{a.id}</span>
      </header>
      <Fields
        rows={[
          ["Kind", kindWords(a.kind)],
          ["Who may open it", visibilityWords(a)],
          ["Owner", ofTeam ? `${ownerWords(a)}; ${personWords(a.owner)} first published it` : a.mine ? `you, ${personWords(a.owner)}` : personWords(a.owner)],
          ["Team", a.team ?? "—"],
          ["Version", a.pinned ? `${current}, pinned by its owner; the newest is ${a.version}` : `${a.version} of ${count(versions.length, "version")}`],
          [
            "You",
            audit && !audit.may_open
              ? "read its page as an administrator who may take it down; only its owner and those they gave it to open it"
              : a.mine
                ? ofTeam
                  ? `an owner, as every member of ${a.owner_team} is`
                  : "its owner"
                : a.role === "edit"
                  ? "may comment and publish new versions, shared with you"
                  : a.role === "comment"
                    ? "may open it and comment on it, shared with you"
                    : "may open it",
          ],
          ["Size", bytes(a.bytes)],
          ["Published", when(a.published_at)],
          ["First published", when(a.created_at)],
        ]}
      />
      {a.goes_at && <p className="muted">{goesSentence(a)}</p>}
      <Blocked artifact={a} current={current} />
      <Region>Where it came from</Region>
      <Origin artifact={a} />
      {audit && (
        <p className="note" role="note">
          You read this page as an administrator, and the audit records it as <code>artifact.read</code>, each time it is opened.
          {!audit.may_open && " What its files hold is for its owner and those they gave it to, so it does not open here; you may take it down."}
        </p>
      )}
      <div className="actions">
        {reach && (
          <>
            <button type="button" className="primary" disabled={opening !== null} onClick={() => open()}>
              {opening === "latest" ? "Opening…" : "Open"}
            </button>
            <select aria-label="Version to open" value={switched} onChange={(e) => setSwitched(e.target.value)}>
              <option value="current">The current version ({current})</option>
              {versions.map((v) => (
                <option key={v.n} value={String(v.n)}>
                  Version {v.n}
                  {v.note ? `: ${v.note}` : ""}
                </option>
              ))}
            </select>
            <button type="button" disabled={opening !== null} onClick={() => open(switched === "current" ? undefined : Number(switched))}>
              Open that version
            </button>
            <OpenInApp link={appLink({ kind: "artifact", id: a.id, plane: plane.url })} />
          </>
        )}
        {editable && !editing && (
          <button type="button" onClick={() => setEditing(true)}>
            Edit
          </button>
        )}
        {a.may_delete && !deleting && (
          <button type="button" className="danger" onClick={() => setDeleting(true)}>
            {takedown ? "Take down" : "Delete"}
          </button>
        )}
        {reach && <span className="hint">It opens in a tab of its own, on the artifacts host.</span>}
      </div>
      {(mayGive || mayTakeBack) && (
        <div className="actions" aria-label="Whose it is">
          {mayGive && (
            <>
              <label>
                Give to team
                <select value={giveTo} disabled={acting} onChange={(e) => setGiveTo(e.target.value)}>
                  {myTeams.map((t) => (
                    <option key={t} value={t}>
                      {t}
                    </option>
                  ))}
                </select>
              </label>
              <button type="button" disabled={acting || giveTo === ""} onClick={() => act(api.transfer(a.id, `team:${giveTo}`), `${a.title} is the ${giveTo} team's now: every member of it is its owner.`, "give it to the team")}>
                Give it to the team
              </button>
              <span className="hint">Anyone on the team can then change, share or delete it; its admin can take it back.</span>
            </>
          )}
          {mayTakeBack && (
            <>
              <button type="button" disabled={acting} onClick={() => act(api.transfer(a.id, "me"), `${a.title} is yours now, not the ${a.owner_team} team's.`, "take it back")}>
                Take back
              </button>
              <span className="hint">It becomes yours alone, and the team's members lose the owner's controls.</span>
            </>
          )}
        </div>
      )}
      {error !== null && (
        <p className="field-error" role="alert">
          Could not {failed}: {describeError(error)}
        </p>
      )}
      {editing && (
        <ArtifactEditor
          artifact={a}
          api={api}
          onClose={() => setEditing(false)}
          onSaved={() => {
            setEditing(false);
            reload();
          }}
        />
      )}
      {deleting && (
        <Preview
          title={`artifact/${a.id}`}
          lines={[{ field: "artifact", from: a.title, to: null }]}
          effects={[
            ...(takedown ? [`This is a takedown: ${a.title} is ${personWords(a.owner)}'s, not yours, and they are not asked first.`] : []),
            `Every version of ${a.title} is deleted, and its link stops opening for everybody who has it.`,
            "A deleted artifact cannot be brought back.",
          ]}
          verb={takedown ? "Take it down" : "Delete it"}
          typeToConfirm={a.id}
          onCancel={() => setDeleting(false)}
          onConfirm={async () => {
            await api.delete(a.id);
            notify(takedown ? `${a.title} is taken down.` : `${a.title} is deleted.`);
            go({ page: "artifacts" });
          }}
        />
      )}
      <section aria-label="Versions">
        <Region>Versions</Region>
        {versionsSentence(a) && <p className="muted">{versionsSentence(a)}</p>}
        <ol className="artifact-versions">
          {versions.map((v) => (
            <li key={v.n} aria-label={`Version ${v.n}`}>
              <header>
                <b>Version {v.n}</b>
                <span className="muted">
                  {" "}
                  · published by {personWords(v.published_by)} · {when(v.published_at)} · {bytes(v.bytes)}
                  {v.goes_at && ` · ${versionGoes(v)}`}
                </span>
                <span className="version-actions">
                  {reach && (
                    <button type="button" disabled={opening !== null} onClick={() => open(v.n)}>
                      {opening === `v${v.n}` ? "Opening…" : `Open version ${v.n}`}
                    </button>
                  )}
                  {reach && a.may_edit && v.n !== a.version && (
                    <button type="button" disabled={acting} onClick={() => act(api.rollback(a.id, v.n), `Version ${v.n}'s files are version ${a.version + 1} now.`)}>
                      Roll back to version {v.n}
                    </button>
                  )}
                  {a.mine && a.pinned !== v.n && (
                    <button type="button" disabled={acting} onClick={() => act(api.pin(a.id, v.n), `Its address serves version ${v.n} now.`)}>
                      Pin version {v.n}
                    </button>
                  )}
                  {a.mine && a.pinned === v.n && (
                    <button type="button" disabled={acting} onClick={() => act(api.pin(a.id, null), "Its address serves the newest version again.")}>
                      Unpin
                    </button>
                  )}
                </span>
              </header>
              {(v.note || v.n === current) && (
                <p className="note">
                  {v.n === current ? "Its address serves this version. " : ""}
                  {v.note ?? ""}
                </p>
              )}
              <div className="scroll">
                <table>
                  <thead>
                    <tr>
                      <th>File</th>
                      <th>Type</th>
                      <th className="num">Size</th>
                    </tr>
                  </thead>
                  <tbody>
                    {v.files.map((f) => (
                      <tr key={f.path}>
                        <td className="mono">{f.path}</td>
                        <td className="mono">{f.content_type}</td>
                        <td className="num">{bytes(f.bytes)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </li>
          ))}
        </ol>
      </section>
      {reach ? <ArtifactComments artifact={a} api={api} /> : <AuditedThread comments={audit?.thread ?? []} />}
      {a.mine && <ArtifactPeople artifact={a} api={api} reload={reload} />}
      {a.mine && <ArtifactLinks artifact={a} api={api} reload={reload} />}
      {!a.mine && audit && <AuditedPeople artifact={audit} />}
    </>
  );
}

/**
 * A link somebody followed to an artifact, landing here once the plane signed them in: it is
 * spent as them, and this tab goes on to the artifact on its host. One that expired, was
 * revoked or is not one says so.
 */
export function ArtifactLink({ token }: { token: string }): JSX.Element {
  const { follow } = useConsole();
  const api = useArtifacts();
  const [error, setError] = useState<unknown>(null);
  useEffect(() => {
    let live = true;
    api.redeem(token).then(
      (opened) => live && follow(opened.url),
      (e: unknown) => live && setError(e),
    );
    return () => {
      live = false;
    };
    // The link is spent once, when the page is reached, whatever else changes.
  }, [token]);
  return (
    <div className="page artifact">
      {error === null ? (
        <p className="lead" role="status">
          Opening the artifact this link is to…
        </p>
      ) : (
        <Empty title="This link opens nothing">
          It has expired, its owner revoked it, or it is not a link to an artifact: {describeError(error)} <a href={href({ page: "artifacts", path: ["mine"] })}>Your artifacts</a>
        </Empty>
      )}
    </div>
  );
}

/**
 * An artifact's own address, followed while signed out: the artifacts host sent the person
 * here to sign in, and this tab goes straight back to the artifact on its host, at the
 * version they asked for, with a ticket asked for as them. The artifact's page in the
 * console is where they can go instead when the plane will not open it to them.
 */
export function ArtifactOpen({ id, version }: { id: string; version?: number | undefined }): JSX.Element {
  const { follow } = useConsole();
  const api = useArtifacts();
  const [error, setError] = useState<unknown>(null);
  useEffect(() => {
    let live = true;
    api.open(id, version).then(
      (ticket) => live && follow(ticket.url),
      (e: unknown) => live && setError(e),
    );
    return () => {
      live = false;
    };
    // Asked once, for the address the person came with.
  }, [id, version]);
  return (
    <div className="page artifact">
      {error === null ? (
        <p className="lead" role="status">
          Opening the artifact…
        </p>
      ) : (
        <Empty title="This artifact cannot be opened">
          It does not exist, it was deleted, or it is not one you may open: {describeError(error)} <a href={href({ page: "artifacts", path: [id] })}>Its page</a>
        </Empty>
      )}
    </div>
  );
}

const WHERE: Record<string, string> = { pod: "the platform", laptop: "a laptop", person: "a person, by hand" };

/**
 * Where it was published from, and the session that published it. The console has no page of
 * one session: an administrator finds it by its id on Sessions, and a member finds their own
 * among Your sessions under Mine on Sessions, which is where a laptop's sessions offered to them are too.
 */
function Origin({ artifact: a }: { artifact: ArtifactDetail }): JSX.Element {
  const { role } = useConsole();
  const o = a.origin ?? {};
  // An agent is named as the apps name one, without the plane's `agent:` prefix.
  const agent = o.agent ? o.agent.replace(/^agent:/, "") : null;
  const words = [o.where ? `From ${WHERE[o.where] ?? o.where}` : null, o.profile ? `on the ${o.profile} profile` : null].filter(Boolean).join(" ") + (agent ? `${o.where || o.profile ? ", by" : "By"} ${agent}, an agent` : "");
  const session = o.session_id ?? null;
  return (
    <div className="artifact-origin">
      <p>{words ? `${words}.` : "The plane does not say where it was published from."}</p>
      {session && <FromSession id={session} />}
      {session && role !== "member" && o.where !== "laptop" && (
        <p>
          <a href={href({ page: "sessions", path: [session] })}>View source session</a> <span className="mono">{session}</span>
        </p>
      )}
      {session && (role === "member" || o.where === "laptop") && a.mine && (
        <p>
          <a href={href({ page: "sessions", path: ["mine"] })}>View source session</a> on Sessions, under Mine: it is <span className="mono">{session}</span>, among {o.where === "laptop" ? "the sessions offered to you" : "Your sessions"}.
        </p>
      )}
      {session && (role === "member" || o.where === "laptop") && !a.mine && (
        <p className="note">
          Published from session <span className="mono">{session}</span>, which is {personWords(a.owner)}'s: the plane opens it only for the people it is shared with.
        </p>
      )}
    </div>
  );
}
