// Your own MCP servers as one session on this computer has them: a line under the
// session's head saying how each stands there, and, opened, what to do about one that
// has failed, wants you signed in, or was added after the session began.
//
// The daemon says (`mcp.list` with the session's id): `ready`, `connecting`, `error`,
// `pending` (the workspace's question is unanswered: it waits in the transcript),
// `sign_in`, `disabled` or `stopped`; a server no state at all is one the session has not
// started, written after it began. Start or Restart reads the server's file again and
// starts it in this session (`mcp.check` with the session), which is also how a server
// signed in to elsewhere joins at once. Read again every few seconds and when the window
// comes back to the front, which is where a person returns from a browser's sign-in.

import { useCallback, useEffect, useState } from "react";
import type { JSX } from "react";
import type { DaemonClient, LocalServer } from "@troupe/client";
import { shell } from "../shell";

const READ_EVERY_MS = 5_000;

type Glyph = "✓" | "…" | "✗" | "→" | "·";

function standing(s: LocalServer): { glyph: Glyph; word: string } {
  if (s.disabled) return { glyph: "·", word: "disabled" };
  if (s.refused) return { glyph: "✗", word: "refused" };
  switch (s.state) {
    case "ready":
      return { glyph: "✓", word: `${s.tools.length} tools` };
    case "connecting":
      return { glyph: "…", word: "connecting" };
    case "error":
      return { glyph: "✗", word: "failed" };
    case "pending":
      return { glyph: "→", word: "waiting for your answer" };
    case "sign_in":
      return { glyph: "→", word: s.auth?.state === "expired" ? "sign in again" : "sign in" };
    case "stopped":
      return { glyph: "·", word: "stopped" };
    default:
      return { glyph: "·", word: "not in this session" };
  }
}

async function openExternal(url: string): Promise<void> {
  const open = shell()?.openExternal;
  if (open) await open(url);
  else globalThis.open?.(url, "_blank", "noopener,noreferrer");
}

export function SessionServers({
  daemon,
  sessionId,
  workspace,
  onManage,
}: {
  daemon: DaemonClient;
  sessionId: string;
  workspace: string | null;
  /** Open Tools and skills, where servers are added and changed. */
  onManage?: (() => void) | undefined;
}): JSX.Element | null {
  const [servers, setServers] = useState<LocalServer[] | null>(null);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [said, setSaid] = useState<string | null>(null);

  const read = useCallback(async () => {
    const listed = await daemon.listServers({ session_id: sessionId, ...(workspace ? { workspace } : {}) });
    setServers(listed.servers);
  }, [daemon, sessionId, workspace]);

  useEffect(() => {
    let live = true;
    const again = (): void => void read().catch(() => live && setServers((s) => s ?? []));
    again();
    const timer = setInterval(again, READ_EVERY_MS);
    globalThis.addEventListener("focus", again);
    return () => {
      live = false;
      clearInterval(timer);
      globalThis.removeEventListener("focus", again);
    };
  }, [read]);

  if (!servers || servers.length === 0) return null;

  const act = async (what: string, run: () => Promise<string>): Promise<void> => {
    setBusy(what);
    try {
      setSaid(await run());
      await read();
    } catch (e) {
      setSaid(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  };

  const start = (s: LocalServer): Promise<void> =>
    act(`start:${s.name}`, async () => {
      const { server } = await daemon.checkServer({ session_id: sessionId, name: s.name });
      return `${s.name}: ${server.state ?? "checked"}${server.error ? ` — ${server.error}` : server.tools.length ? `, ${server.tools.length} tools` : ""}`;
    });

  const signIn = (s: LocalServer): Promise<void> =>
    act(`sign-in:${s.name}`, async () => {
      const started = await daemon.signInServer(workspace ? { workspace, name: s.name } : { name: s.name });
      await openExternal(started.url);
      return `${s.name}: finish signing in in your browser; this session takes its tools once you have.`;
    });

  const trouble = servers.filter((s) => !s.disabled && s.state !== "ready").length;

  return (
    <div className="session-servers" role="region" aria-label="Your servers in this session">
      <button className="link" onClick={() => setOpen((o) => !o)} aria-expanded={open}>
        Servers:{" "}
        {servers.map((s) => {
          const { glyph } = standing(s);
          return (
            <span key={s.name} className="mono micro">
              {glyph} {s.name}{" "}
            </span>
          );
        })}
        {trouble > 0 && <span className="micro">({trouble} need you)</span>}
      </button>
      {open && (
        <ul className="session-servers-list">
          {servers.map((s) => {
            const { glyph, word } = standing(s);
            const wantsSignIn = Boolean(s.auth) && (s.state === "sign_in" || s.auth?.state === "expired" || Boolean(s.auth?.step_up));
            return (
              <li key={s.name}>
                <span className="mono">
                  {glyph} {s.name}
                </span>{" "}
                <span className="micro">
                  {word}
                  {s.error ? ` — ${s.error}` : ""}
                </span>{" "}
                {wantsSignIn && (
                  <button className="primary" onClick={() => void signIn(s)} disabled={busy !== null}>
                    Sign in
                  </button>
                )}{" "}
                {!s.disabled && s.state !== "pending" && (
                  <button onClick={() => void start(s)} disabled={busy !== null}>
                    {busy === `start:${s.name}` ? "Starting…" : s.state === null || s.state === "stopped" ? "Start" : "Restart"}
                  </button>
                )}
              </li>
            );
          })}
          {said && <li className="note">{said}</li>}
          {onManage && (
            <li>
              <button className="link" onClick={onManage}>
                Add or change servers on Tools and skills
              </button>
            </li>
          )}
        </ul>
      )}
    </div>
  );
}
