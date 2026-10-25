// Artifacts: the pages and files a person, their organisation and their profiles' people
// have published, for everybody who signs in, administrators too. A tab for their own, one
// for the organisation's and one for each profile they are covered by; a card for each,
// and a page for one with its versions, newest first.
//
// An artifact is never drawn here. Its card is its title and its kind, and its page says
// what it is and where it came from; opening it asks the plane for a one-time link at the
// moment it is opened, and the artifacts host shows it in a tab of its own that has no hold
// on this one. A published page's HTML or Markdown is a stranger's code to this console.
//
// Nothing here is an administrative call: `artifact.list`, `artifact.get`, `artifact.open`
// and `artifact.delete` are what any client of the person's asks the plane as that person.
// Deleting is the owner's, or a platform admin's takedown of somebody else's, which the
// confirm says it is.

import { useState } from "react";
import type { JSX } from "react";
import { ArtifactApi, TroupeRpcError } from "@troupe/client";
import type { Artifact, ArtifactDetail, ArtifactFilter, ArtifactList, ArtifactPerson } from "@troupe/client";
import { describeError, useConsole, useLoad } from "../console";
import { go, href } from "../route";
import type { Route } from "../route";
import { Empty, Fields, Loaded, Preview, Region, Status, bytes, count, when } from "./bits";

/** Which artifacts a tab lists. */
export type ArtifactTab = { kind: "mine" } | { kind: "organisation" } | { kind: "profile"; name: string };

/**
 * What an address under `#/artifacts` names: a tab (`mine`, `organisation`,
 * `profile/<name>`), or one artifact by its id, which the plane never makes one of those words.
 */
export function artifactPlace(path: string[]): { tab: ArtifactTab } | { id: string } {
  const [first, second] = path;
  if (!first || first === "mine") return { tab: { kind: "mine" } };
  if (first === "organisation") return { tab: { kind: "organisation" } };
  if (first === "profile" && second) return { tab: { kind: "profile", name: second } };
  return { id: first };
}

function routeOf(tab: ArtifactTab): Route {
  if (tab.kind === "mine") return { page: "artifacts" };
  if (tab.kind === "organisation") return { page: "artifacts", path: ["organisation"] };
  return { page: "artifacts", path: ["profile", tab.name] };
}

function filterOf(tab: ArtifactTab): ArtifactFilter {
  if (tab.kind === "mine") return { mine: true };
  if (tab.kind === "organisation") return { visibility: "organisation" };
  return { visibility: `profile:${tab.name}` };
}

function same(a: ArtifactTab, b: ArtifactTab): boolean {
  return a.kind === b.kind && (a.kind !== "profile" || (b.kind === "profile" && a.name === b.name));
}

const KIND: Record<string, string> = { html: "HTML page", markdown: "Markdown", file: "File" };

function kindWords(kind: string): string {
  return KIND[kind] ?? kind;
}

/** Who may open it, in words. */
function visibilityWords(visibility: string): string {
  if (visibility === "organisation") return "the whole organisation";
  if (visibility.startsWith("profile:")) return `the ${visibility.slice("profile:".length)} profile's people`;
  return visibility;
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

export function Artifacts({ tab }: { tab: ArtifactTab }): JSX.Element {
  const { auth } = useConsole();
  const key = tab.kind === "profile" ? `profile:${tab.name}` : tab.kind;
  const [load, reload] = useLoad(() => new ArtifactApi((m, p) => auth.rpc(m, p)).list(filterOf(tab)), [auth, key]);
  return (
    <div className="page artifacts">
      <p className="lead">The pages and files published on this plane that you may open: your own, your organisation's, and those of each profile you work in.</p>
      <Loaded load={load} what="the artifacts" retry={reload}>
        {(list) => (list.enabled ? <Gallery tab={tab} list={list} /> : <SwitchedOff />)}
      </Loaded>
    </div>
  );
}

function Gallery({ tab, list }: { tab: ArtifactTab; list: ArtifactList }): JSX.Element {
  const tabs: Array<{ tab: ArtifactTab; label: string }> = [
    { tab: { kind: "mine" }, label: "Mine" },
    { tab: { kind: "organisation" }, label: "Organisation" },
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
      {list.artifacts.length === 0 ? (
        <Empty title={tab.kind === "mine" ? "You have published nothing yet" : "Nothing published here yet"}>
          <p>
            An agent publishes a page or a file with its <code>publish_artifact</code> tool, and you can from the terminal client with <code>{"/publish <file>"}</code>.
          </p>
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

/** A card: the title and the kind where a thumbnail would be, and what it is beneath. Never its content. */
function Card({ artifact: a }: { artifact: Artifact }): JSX.Element {
  return (
    <li className="artifact-card">
      <a className="thumb" href={href({ page: "artifacts", path: [a.id] })}>
        <span className="thumb-title">{a.title}</span>
        <span className="thumb-kind">{kindWords(a.kind)}</span>
      </a>
      <p className="card-meta">
        {a.mine ? "yours" : (a.owner.display_name ?? a.owner.subject)} · version {a.version} · {bytes(a.bytes)}
      </p>
      <p className="card-meta">
        {a.mine ? `for ${visibilityWords(a.visibility)} · ` : ""}published {when(a.published_at)}
      </p>
    </li>
  );
}

const NOT_FOUND = -32005;

/** One artifact: what it is, where it came from, its versions, and the way to open it. */
export function ArtifactPage({ id }: { id: string }): JSX.Element {
  const { auth } = useConsole();
  const [load, reload] = useLoad(
    () =>
      new ArtifactApi((m, p) => auth.rpc(m, p)).get(id).catch((e: unknown) => {
        // One that does not exist and one this person may not see are the same answer.
        if (e instanceof TroupeRpcError && e.code === NOT_FOUND) return null;
        throw e;
      }),
    [auth, id],
  );
  return (
    <div className="page artifact">
      <Loaded load={load} what="the artifact" retry={reload}>
        {(a) =>
          a === null ? (
            <Empty title="No such artifact">
              It does not exist, it was deleted, or it is not one you may open. <a href={href({ page: "artifacts" })}>Your artifacts</a>
            </Empty>
          ) : (
            <Detail artifact={a} />
          )
        }
      </Loaded>
    </div>
  );
}

function Detail({ artifact: a }: { artifact: ArtifactDetail }): JSX.Element {
  const { notify, openTab } = useConsole();
  const api = useArtifacts();
  const [opening, setOpening] = useState<string | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [deleting, setDeleting] = useState(false);
  const takedown = !a.mine;
  const versions = [...a.versions].sort((x, y) => y.n - x.n);

  // The link is asked for at the click, since it is good once and for a minute.
  const open = (version?: number): void => {
    const what = version === undefined ? "latest" : `v${version}`;
    setOpening(what);
    setError(null);
    api.open(a.id, version).then(
      (ticket) => {
        setOpening(null);
        openTab(ticket.url);
      },
      (e: unknown) => {
        setOpening(null);
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
          ["Who may open it", visibilityWords(a.visibility)],
          ["Owner", a.mine ? `you, ${personWords(a.owner)}` : personWords(a.owner)],
          ["Team", a.team ?? "—"],
          ["Version", `${a.version} of ${count(versions.length, "version")}`],
          ["Size", bytes(a.bytes)],
          ["Published", when(a.published_at)],
          ["First published", when(a.created_at)],
        ]}
      />
      <Region>Where it came from</Region>
      <Origin artifact={a} />
      <div className="actions">
        <button type="button" className="primary" disabled={opening !== null} onClick={() => open()}>
          {opening === "latest" ? "Opening…" : "Open"}
        </button>
        {a.may_delete && !deleting && (
          <button type="button" className="danger" onClick={() => setDeleting(true)}>
            {takedown ? "Take down" : "Delete"}
          </button>
        )}
        <span className="hint">It opens in a tab of its own, on the artifacts host.</span>
      </div>
      {error !== null && (
        <p className="field-error" role="alert">
          Could not open it: {describeError(error)}
        </p>
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
        <ol className="artifact-versions">
          {versions.map((v) => (
            <li key={v.n} aria-label={`Version ${v.n}`}>
              <header>
                <b>Version {v.n}</b>
                <span className="muted">
                  {" "}
                  · published by {personWords(v.published_by)} · {when(v.published_at)} · {bytes(v.bytes)}
                </span>
                <button type="button" disabled={opening !== null} onClick={() => open(v.n)}>
                  {opening === `v${v.n}` ? "Opening…" : `Open version ${v.n}`}
                </button>
              </header>
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
    </>
  );
}

const WHERE: Record<string, string> = { pod: "a worker on the plane", laptop: "a laptop", person: "a person, by hand" };

/**
 * Where it was published from, and the session that published it. The console has no page of
 * one session: an administrator finds it by its id on Sessions, and a member finds their own
 * among Your sessions in Mine, which is where a laptop's sessions offered to them are too.
 */
function Origin({ artifact: a }: { artifact: ArtifactDetail }): JSX.Element {
  const { role } = useConsole();
  const o = a.origin ?? {};
  const words = [o.where ? `From ${WHERE[o.where] ?? o.where}` : null, o.agent ? `by ${o.agent}` : null, o.profile ? `on the ${o.profile} profile` : null].filter(Boolean).join(" ");
  const session = o.session_id ?? null;
  return (
    <div className="artifact-origin">
      <p>{words ? `${words}.` : "The plane does not say where it was published from."}</p>
      {session && role !== "member" && o.where !== "laptop" && (
        <p>
          <a href={href({ page: "sessions", path: [session] })}>View source session</a> <span className="mono">{session}</span>
        </p>
      )}
      {session && (role === "member" || o.where === "laptop") && a.mine && (
        <p>
          <a href={href({ page: "mine" })}>View source session</a> in Mine: it is <span className="mono">{session}</span>, among {o.where === "laptop" ? "the sessions offered to you" : "Your sessions"}.
        </p>
      )}
      {session && (role === "member" || o.where === "laptop") && !a.mine && (
        <p className="note">
          Published from session <span className="mono">{session}</span>, which is {personWords(a.owner)}'s and not yours to open.
        </p>
      )}
    </div>
  );
}
