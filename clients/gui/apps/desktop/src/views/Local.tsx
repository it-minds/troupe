// This computer: the daemon, what it is running, and the things only a local session
// has.
//
// Everything on this screen is about the machine rather than about a session — where the
// daemon is, who it thinks you are, which directories have worktrees left over, and
// which workspace is being watched. A local session's transcript is the same screen a
// team session's is, because it is the same protocol; what differs is here.
//
// The connect panel is the honest part. A desktop shell finds the daemon by reading the
// file it publishes and can start it; a browser tab can do neither, so it is given the
// two fields it would otherwise have to guess and told plainly why. Nothing pretends the
// two hosts are the same.

import { useCallback, useState } from "react";
import type { JSX } from "react";
import type { DaemonClient, DaemonEndpoint, DaemonIdentity, RecentWorkspace, Worktree } from "@troupe/client";
import { useAdminQuery } from "../hooks";
import { Loading, Pill, When } from "./bits";
import { Confirm, Failed, Table } from "./admin/bits";

export interface DaemonState {
  client: DaemonClient | null;
  endpoint: DaemonEndpoint | null;
  status: "unsupported" | "searching" | "absent" | "connected" | "error";
  identity: DaemonIdentity | null;
  error: string | null;
  canFind: boolean;
  connectTo: (endpoint: DaemonEndpoint) => void;
  forget: () => void;
  find: () => void;
  link: (who: { subject: string; display_name?: string; plane_url?: string }) => Promise<void>;
  unlink: () => Promise<void>;
}

export function Local({
  daemon,
  me,
  planeUrl,
}: {
  daemon: DaemonState;
  me: { subject: string; display_name?: string | undefined } | null;
  planeUrl: string;
}): JSX.Element {
  return (
    <>
      <header className="toolbar">
        <h2>This computer</h2>
        <span className="spacer" />
        <DaemonStatus daemon={daemon} />
      </header>

      <div className="listing">
        <Connect daemon={daemon} />
        {daemon.client && <WhoAmI daemon={daemon} me={me} planeUrl={planeUrl} />}
        {daemon.client && <Workspaces client={daemon.client} />}
        {daemon.client && <Worktrees client={daemon.client} />}
      </div>
    </>
  );
}

function DaemonStatus({ daemon }: { daemon: DaemonState }): JSX.Element {
  if (daemon.status === "connected") return <Pill status="running">Connected</Pill>;
  if (daemon.status === "searching") return <Pill status="queued">Looking</Pill>;
  if (daemon.status === "error") return <Pill status="error">Not answering</Pill>;
  if (daemon.status === "absent") return <Pill status="dormant">Not running</Pill>;
  return <Pill status="offline">No way to find it</Pill>;
}

function Connect({ daemon }: { daemon: DaemonState }): JSX.Element {
  const [port, setPort] = useState("");
  const [token, setToken] = useState("");

  if (daemon.status === "connected" && daemon.endpoint) {
    return (
      <section className="group">
        <h3>The daemon</h3>
        <dl className="facts wide">
          <dt>Reached at</dt>
          <dd className="mono micro">ws://127.0.0.1:{daemon.endpoint.port}/v1/socket</dd>
          <dt>Sessions</dt>
          <dd>Everything it is running is in your one list, marked as running on this computer.</dd>
        </dl>
        <button onClick={daemon.forget}>Disconnect</button>
      </section>
    );
  }

  return (
    <section className="group">
      <h3>The daemon</h3>
      <Failed error={daemon.error} />

      {daemon.canFind ? (
        <>
          <p className="copy">
            {daemon.status === "searching"
              ? "Looking for the daemon this computer is running…"
              : daemon.status === "absent"
                ? "Nothing is running here yet. Starting it takes a second, and it keeps running after this window closes."
                : "The daemon did not answer. It may have stopped since it last published where it was."}
          </p>
          <button className="primary" onClick={daemon.find} disabled={daemon.status === "searching"}>
            {daemon.status === "searching" ? "Looking…" : "Find it, and start it if it is not running"}
          </button>
        </>
      ) : (
        <>
          <p className="copy">
            A page cannot read the file the daemon publishes itself in, and cannot start a program. So it has to be told where the daemon
            is. Run <code className="mono">troupe daemon</code> and read the port and token out of{" "}
            <code className="mono">daemon.json</code> — the desktop application does this part for you.
          </p>
          <form
            className="inline-form"
            onSubmit={(e) => {
              e.preventDefault();
              const p = Number(port);
              if (Number.isInteger(p) && p > 0 && token.trim()) {
                daemon.connectTo({ transport: "ws", port: p, token: token.trim() });
              }
            }}
          >
            <label className="inline">
              Port
              <input value={port} onChange={(e) => setPort(e.target.value)} inputMode="numeric" placeholder="51837" />
            </label>
            <label className="inline">
              Token
              <input value={token} onChange={(e) => setToken(e.target.value)} spellCheck={false} type="password" />
            </label>
            <button type="submit" className="primary">
              Connect
            </button>
          </form>
          <p className="note">
            The token stays in this tab and is never written down. Closing the tab means typing it again — which is the same rule the
            sign-in screen follows, for the same reason.
          </p>
        </>
      )}
    </section>
  );
}

/**
 * Who the daemon says its user is.
 *
 * Unlinked, it calls you by the operating system's username, which means nothing off
 * this machine — so nothing it records could be billed, listed by a plane, or opened
 * from another device. Linking is what makes a local session yours rather than this
 * login's, and it is the precondition for a private session.
 */
function WhoAmI({
  daemon,
  me,
  planeUrl,
}: {
  daemon: DaemonState;
  me: { subject: string; display_name?: string | undefined } | null;
  planeUrl: string;
}): JSX.Element {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const identity = daemon.identity;

  const act = async (link: boolean): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      if (link && me) {
        await daemon.link({
          subject: me.subject,
          ...(me.display_name ? { display_name: me.display_name } : {}),
          plane_url: planeUrl,
        });
      } else {
        await daemon.unlink();
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="group">
      <h3>Who it records</h3>
      <Failed error={error} />

      {identity?.linked ? (
        <>
          <p className="copy">
            Sessions started here are recorded as <strong>{identity.display_name ?? identity.subject}</strong>
            {identity.plane_url ? <> , signed in at {identity.plane_url}</> : null}. That name travels: a session synced to the platform is
            yours on any machine you sign in from.
          </p>
          <button onClick={() => void act(false)} disabled={busy}>
            {busy ? "Working…" : "Stop using my account here"}
          </button>
        </>
      ) : (
        <>
          <p className="copy">
            Sessions started here are recorded under this computer&apos;s login, which means nothing anywhere else. Using your account
            instead is what lets a session on this machine be listed by the platform and opened from another device.
          </p>
          <button className="primary" onClick={() => void act(true)} disabled={busy || !me}>
            {busy ? "Working…" : `Use my account${me ? ` (${me.display_name ?? me.subject})` : ""}`}
          </button>
          <p className="note">
            This is a label, not a sign-in. Anything that can already reach the daemon can already do everything on it; what changes is the
            name in the record.
          </p>
        </>
      )}
    </section>
  );
}

function Workspaces({ client }: { client: DaemonClient }): JSX.Element {
  const load = useCallback(() => client.recentWorkspaces().then((r) => r.workspaces), [client]);
  const { data, loading, error } = useAdminQuery<RecentWorkspace[]>(load, [load]);

  return (
    <section className="group">
      <h3>Where you have been working</h3>
      <Failed error={error} />
      {loading && !data && <Loading what="Reading recent workspaces…" />}
      {data && data.length === 0 && !loading && <p className="note">No session has run on this computer yet.</p>}
      {data && data.length > 0 && (
        <Table head={["Directory", "Sessions", "Last used"]}>
          {data.map((w) => (
            <tr key={w.path}>
              <th scope="row" className="mono micro">
                {w.path}
              </th>
              <td>{w.sessions}</td>
              <td>
                <When iso={w.last_used_at} />
              </td>
            </tr>
          ))}
        </Table>
      )}
    </section>
  );
}

/**
 * Worktrees left behind.
 *
 * A second session in a workspace that already has a live one gets its own git worktree
 * on `troupe/<slug>`, which is what keeps two agents out of each other's checkout. They
 * outlive the session, so this is where they are removed — and a dirty one is refused
 * rather than discarded, because uncommitted work in a branch nobody remembers making is
 * exactly the thing not to delete quietly.
 */
function Worktrees({ client }: { client: DaemonClient }): JSX.Element {
  const [round, setRound] = useState(0);
  const [removing, setRemoving] = useState<Worktree | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(() => client.worktrees().then((r) => r.worktrees), [client]);
  const { data, loading, error: readError } = useAdminQuery<Worktree[]>(load, [load, round]);

  const remove = async (worktree: Worktree, force: boolean): Promise<void> => {
    setBusy(true);
    setError(null);
    try {
      await client.removeWorktree(worktree.path, force);
      setRemoving(null);
      setRound((n) => n + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="group">
      <h3>Worktrees</h3>
      <Failed error={readError ?? error} />
      {loading && !data && <Loading what="Reading the worktrees…" />}
      {data && data.length === 0 && !loading && (
        <p className="note">None. A second session in a workspace that is already busy gets one of these.</p>
      )}
      {data && data.length > 0 && (
        <Table head={["Directory", "Branch", "Session", "State", "  "]}>
          {data.map((w) => (
            <tr key={w.path}>
              <th scope="row" className="mono micro">
                {w.path}
              </th>
              <td className="mono micro">{w.branch ?? "—"}</td>
              <td className="mono micro">{w.session_id ?? "none"}</td>
              <td>{w.dirty ? <Pill status="waiting">Uncommitted work</Pill> : <Pill status="allowed">Clean</Pill>}</td>
              <td>
                <button className="link" onClick={() => setRemoving(w)}>
                  Remove
                </button>
              </td>
            </tr>
          ))}
        </Table>
      )}

      {removing && (
        <Confirm
          what={removing.dirty ? "Remove it and lose the changes" : "Remove this worktree"}
          identifier={removing.branch ?? removing.path}
          consequence={
            removing.dirty
              ? `${removing.path} has changes that are not committed anywhere. Removing it destroys them, and nothing here keeps a copy.`
              : `${removing.path} is deleted. The branch it was on stays, and so does everything committed to it.`
          }
          busy={busy}
          onCancel={() => setRemoving(null)}
          onConfirm={() => void remove(removing, removing.dirty)}
        />
      )}
    </section>
  );
}
