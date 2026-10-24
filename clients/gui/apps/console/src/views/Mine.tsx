// Mine: what is a person's own on this plane, for everybody who signs in, administrators
// too. The laptops' sessions offered to them, steered from here as themselves; their own
// sessions on the plane; which version of each of their clients the plane last saw, against
// its policy; and the memory their machines read into every session, to read.
//
// Nothing here is an administrative call. Each is what any client of the person's asks the
// plane as that person (`sessions.list`, `remote.*`, `me.clients`, `me.memory`), so the
// plane answers it as it answers the desktop app, and a member is shown nothing of anybody
// else's.

import type { JSX } from "react";
import type { SessionRow } from "@troupe/client";
import { show, useConsole, useLoad } from "../console";
import { Empty, Loaded, Region, Status, when } from "./bits";
import type { StatusKind } from "./bits";
import { RemoteSessions } from "./Remote";

/** One of the person's clients, as the plane last saw it. */
interface ClientSeen {
  component: string;
  version: string;
  platform?: string | null;
  seen_at?: string | null;
  standing: string;
  recommended?: string | null;
}

/** A memory document a person's machine reads, as `me.memory` answers it. */
interface MemoryDocument {
  scope: string;
  name?: string | null;
  version: number;
  updated_at?: string | null;
  text: string;
}

const COMPONENT: Record<string, string> = { tui: "terminal", daemon: "daemon", desktop: "desktop app" };

const STANDING: Record<string, { kind: StatusKind; glyph: string; word: string; why: (c: ClientSeen) => string | null }> = {
  current: { kind: "running", glyph: "●", word: "current", why: () => null },
  behind: { kind: "waiting", glyph: "◐", word: "behind", why: (c) => (c.recommended ? `the plane recommends ${c.recommended}` : "the plane recommends a newer one") },
  refused: { kind: "denied", glyph: "✕", word: "refused", why: () => "at its next start: update it" },
};

export function Mine(): JSX.Element {
  const { me, plane } = useConsole();
  return (
    <div className="page mine">
      <p className="lead">
        What is yours on {plane.name}, {me.display_name ?? me.subject}: the sessions offered to you from laptops, to follow and steer from here, your sessions, your clients'
        versions, and the memory your machines read.
      </p>
      <RemoteSessions />
      <YourSessions />
      <YourClients />
      <YourMemory />
    </div>
  );
}

function YourSessions(): JSX.Element {
  const { auth, me } = useConsole();
  const [load, reload] = useLoad(() => auth.rpc<{ sessions: SessionRow[] }>("sessions.list", {}).then((r) => r.sessions.filter((s) => s.owner === me.subject)), [auth, me.subject]);
  return (
    <section aria-label="Your sessions">
      <Region>Your sessions</Region>
      <Loaded load={load} what="your sessions" retry={reload}>
        {(rows) =>
          rows.length === 0 ? (
            <Empty title="No session of yours on the plane">One you start on a worker, from the desktop app or the terminal, is listed here.</Empty>
          ) : (
            <div className="scroll">
              <table className="sessions">
                <thead>
                  <tr>
                    <th>Session</th>
                    <th>Title</th>
                    <th>Profile</th>
                    <th>State</th>
                    <th>Last active</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((s) => (
                    <tr key={s.id}>
                      <td className="mono">{s.id}</td>
                      <td>{s.title ?? "—"}</td>
                      <td>{s.profile ?? "—"}</td>
                      <td>{s.status ? `${s.state} · ${s.status}` : s.state}</td>
                      <td>{when(s.last_active_at ?? null)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )
        }
      </Loaded>
    </section>
  );
}

function YourClients(): JSX.Element {
  const { auth } = useConsole();
  const [load, reload] = useLoad(
    () =>
      auth
        .rpc<{ clients: ClientSeen[] }>("me.clients", {})
        .then((r) => r.clients)
        .catch((e: unknown) => {
          // A plane from before it says nothing of a person's clients.
          if ((e as { code?: unknown }).code === -32601) return null;
          throw e;
        }),
    [auth],
  );
  return (
    <section aria-label="Your clients">
      <Region>Your clients</Region>
      <Loaded load={load} what="your clients' versions" retry={reload}>
        {(clients) =>
          clients === null ? (
            <Empty title="This plane does not say which versions your clients run" />
          ) : clients.length === 0 ? (
            <Empty title="No client of yours has signed in to this plane yet" />
          ) : (
            <ul className="clients-seen">
              {clients.map((c) => {
                const st = STANDING[c.standing] ?? { kind: "muted" as const, glyph: "○", word: c.standing, why: () => null };
                const why = st.why(c);
                return (
                  <li key={c.component}>
                    <b>{COMPONENT[c.component] ?? c.component}</b> <span className="mono">{c.version}</span>
                    {c.platform ? <span className="muted"> on {c.platform}</span> : null}{" "}
                    <Status kind={st.kind} glyph={st.glyph}>
                      {st.word}
                    </Status>
                    {why ? <span className="muted"> · {why}</span> : null}
                    {c.seen_at ? <span className="muted"> · last seen {when(c.seen_at)}</span> : null}
                  </li>
                );
              })}
            </ul>
          )
        }
      </Loaded>
    </section>
  );
}

function YourMemory(): JSX.Element {
  const { auth } = useConsole();
  const [load, reload] = useLoad(
    () =>
      auth
        .rpc<{ documents: MemoryDocument[] }>("me.memory", {})
        .then((r) => r.documents ?? [])
        .catch((e: unknown) => {
          if ((e as { code?: unknown }).code === -32601) return [] as MemoryDocument[];
          throw e;
        }),
    [auth],
  );
  return (
    <section aria-label="Your memory">
      <Region>Your memory</Region>
      <p className="note">What every session on your machines starts from, as instructions from your organisation, before your own. Read-only here: an administrator of its scope keeps it.</p>
      <Loaded load={load} what="your memory" retry={reload}>
        {(documents) =>
          documents.length === 0 ? (
            <Empty title="Your organisation keeps no memory for you" />
          ) : (
            <>
              {documents.map((d) => (
                <article key={`${d.scope}/${d.name ?? ""}`} className="memory-read" aria-label={d.scope === "team" ? `The ${d.name} team's memory` : "The organisation's memory"}>
                  <h3>
                    {d.scope === "team" ? `The ${d.name} team's` : "The organisation's"} <span className="meta">version {show(d.version)}{d.updated_at ? ` · ${when(d.updated_at)}` : ""}</span>
                  </h3>
                  <pre className="memory-text">{d.text}</pre>
                </article>
              ))}
            </>
          )
        }
      </Loaded>
    </section>
  );
}
