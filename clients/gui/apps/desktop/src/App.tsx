import { useEffect, useRef, useState } from "react";
import { PlaneClient, TroupeConnection, normalizeEndpoint } from "@troupe/client";
import type { Attachment, DeviceAuthorization, Discovery, PlaneCredential } from "@troupe/client";
import { useSession } from "./useSession";

type Mode = "worker" | "plane";

interface Connected {
  conn: TroupeConnection;
  sessionId: string;
  label: string;
}

const remembered = (k: string, d = "") => {
  try {
    return localStorage.getItem(`troupe.${k}`) ?? d;
  } catch {
    return d;
  }
};
const remember = (k: string, v: string) => {
  try {
    localStorage.setItem(`troupe.${k}`, v);
  } catch {
    /* private mode */
  }
};

export function App() {
  const [connected, setConnected] = useState<Connected | null>(null);
  const [status, setStatus] = useState<string>("");

  if (!connected) {
    return <ConnectPanel onConnected={setConnected} status={status} setStatus={setStatus} />;
  }
  return (
    <SessionPanel
      connected={connected}
      onDisconnect={() => {
        connected.conn.close();
        setConnected(null);
      }}
    />
  );
}

function ConnectPanel({
  onConnected,
  status,
  setStatus,
}: {
  onConnected: (c: Connected) => void;
  status: string;
  setStatus: (s: string) => void;
}) {
  const [mode, setMode] = useState<Mode>((remembered("mode", "plane") as Mode) || "plane");
  const [wsUrl, setWsUrl] = useState(remembered("wsUrl", "ws://localhost:4000/v1/socket"));
  const [token, setToken] = useState("");
  const [workspace, setWorkspace] = useState(remembered("workspace", "/workspace"));
  const [planeUrl, setPlaneUrl] = useState(remembered("planeUrl", "http://plane.localtest.me:30080"));
  const [device, setDevice] = useState<DeviceAuthorization | null>(null);
  const [cred, setCred] = useState<PlaneCredential | null>(null);
  const [discovery, setDiscovery] = useState<Discovery | null>(null);
  const [profile, setProfile] = useState("");
  const [busy, setBusy] = useState(false);

  const openWorker = async (url: string, tok: string, sessionId: string, label: string) => {
    const conn = await TroupeConnection.open(
      { url: normalizeEndpoint(url), token: tok, clientInfo: { name: "troupe-gui", version: "0.1.0" } },
      { onClose: (r) => setStatus(`connection closed: ${r}`) },
    );
    onConnected({ conn, sessionId, label });
  };

  const connectWorker = async () => {
    setBusy(true);
    setStatus("connecting…");
    try {
      remember("mode", "worker");
      remember("wsUrl", wsUrl);
      remember("workspace", workspace);
      const conn = await TroupeConnection.open(
        { url: normalizeEndpoint(wsUrl), token: token || undefined, clientInfo: { name: "troupe-gui", version: "0.1.0" } },
        { onClose: (r) => setStatus(`connection closed: ${r}`) },
      );
      const created = await conn.call<{ session_id: string }>("session.create", {
        command_id: conn.nextCommandId(),
        workspace,
        worktree: "never",
      });
      onConnected({ conn, sessionId: created.session_id, label: `${conn.hello.server_info.name} · ${created.session_id}` });
    } catch (e) {
      setStatus(String(e));
    } finally {
      setBusy(false);
    }
  };

  const startLogin = async () => {
    setBusy(true);
    setStatus("discovering plane…");
    try {
      remember("mode", "plane");
      remember("planeUrl", planeUrl);
      const plane = new PlaneClient(planeUrl);
      const d = await plane.discover();
      setDiscovery(d);
      const auth = await plane.startDeviceFlow(d);
      setDevice(auth);
      setStatus("waiting for you to approve the sign-in…");
      const tokens = await plane.pollDeviceFlow(d, auth);
      const idToken = tokens.id_token ?? tokens.access_token;
      if (!idToken) throw new Error("the identity provider returned no token");
      const c = await plane.exchange(idToken);
      setCred(c);
      setDevice(null);
      setProfile(c.profiles[0] ?? "");
      setStatus(`signed in as ${c.display_name ?? c.subject}`);
    } catch (e) {
      setStatus(String(e));
      setDevice(null);
    } finally {
      setBusy(false);
    }
  };

  const createViaPlane = async () => {
    if (!cred) return;
    setBusy(true);
    setStatus("placing a session…");
    try {
      const plane = new PlaneClient(planeUrl);
      const att: Attachment = await plane.createSession(cred.token, { profile, title: "from the GUI" });
      if (!att.token) throw new Error("the plane returned no pod token");
      setStatus(`dialing ${att.endpoint}…`);
      await openWorker(att.endpoint, att.token, att.session_id, `${att.pod ?? att.worker_id} · ${att.session_id}`);
    } catch (e) {
      setStatus(String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <main className="connect">
      <h1>Troupe</h1>
      <div className="tabs">
        <button className={mode === "plane" ? "active" : ""} onClick={() => setMode("plane")}>
          Plane
        </button>
        <button className={mode === "worker" ? "active" : ""} onClick={() => setMode("worker")}>
          Worker (direct)
        </button>
      </div>

      {mode === "worker" && (
        <form
          onSubmit={(e) => {
            e.preventDefault();
            void connectWorker();
          }}
        >
          <label>
            WebSocket URL
            <input value={wsUrl} onChange={(e) => setWsUrl(e.target.value)} placeholder="wss://0.dev.workers.example.com/v1/socket" />
          </label>
          <label>
            Token <small>(optional on a local daemon)</small>
            <input value={token} onChange={(e) => setToken(e.target.value)} type="password" autoComplete="off" />
          </label>
          <label>
            Workspace
            <input value={workspace} onChange={(e) => setWorkspace(e.target.value)} />
          </label>
          <button type="submit" disabled={busy}>
            Connect and create a session
          </button>
        </form>
      )}

      {mode === "plane" && (
        <div className="stack">
          <label>
            Plane URL
            <input value={planeUrl} onChange={(e) => setPlaneUrl(e.target.value)} placeholder="https://troupe.example.com" />
          </label>
          {!cred && (
            <button onClick={() => void startLogin()} disabled={busy}>
              Sign in
            </button>
          )}
          {device && (
            <div className="device">
              <p>
                Open <a href={device.verification_uri_complete ?? device.verification_uri} target="_blank" rel="noreferrer">
                  {device.verification_uri}
                </a>{" "}
                and enter the code:
              </p>
              <code className="usercode">{device.user_code}</code>
            </div>
          )}
          {cred && (
            <>
              <p>
                Signed in as <strong>{cred.display_name ?? cred.subject}</strong>
                {discovery ? ` via ${new URL(discovery.issuer).host}` : ""}. Teams: {cred.teams.join(", ") || "none"}.
              </p>
              <label>
                Profile
                <select value={profile} onChange={(e) => setProfile(e.target.value)}>
                  {cred.profiles.map((p) => (
                    <option key={p} value={p}>
                      {p}
                    </option>
                  ))}
                </select>
              </label>
              <button onClick={() => void createViaPlane()} disabled={busy || !profile}>
                Create a session
              </button>
            </>
          )}
        </div>
      )}
      <p className="status">{status}</p>
    </main>
  );
}

function SessionPanel({ connected, onDisconnect }: { connected: Connected; onDisconnect: () => void }) {
  const { state, send, respond, cancel } = useSession(connected.conn, connected.sessionId);
  const [draft, setDraft] = useState("");
  const bottom = useRef<HTMLDivElement>(null);

  useEffect(() => {
    bottom.current?.scrollIntoView({ block: "end" });
  }, [state.entries.length, state.streaming]);

  const busy = ["thinking", "acting", "compacting"].includes(state.agentState);

  return (
    <main className="session">
      <header>
        <span className="label">{connected.label}</span>
        <span className={`state ${state.agentState}`}>{state.agentState}</span>
        <span className="seq">seq {state.lastSeq}</span>
        <button onClick={onDisconnect}>Disconnect</button>
      </header>
      <section className="transcript">
        {state.entries.map((en) => {
          switch (en.kind) {
            case "user":
              return (
                <div key={en.seq} className="msg user">
                  <div className="who">{en.author ?? "you"}</div>
                  <pre>{en.text}</pre>
                </div>
              );
            case "assistant":
              return (
                <div key={en.seq} className="msg assistant">
                  <div className="who">agent</div>
                  <pre>{en.text}</pre>
                </div>
              );
            case "tool":
              return (
                <details key={en.seq} className={`tool ${en.ok === undefined ? "running" : en.ok ? "ok" : "failed"}`}>
                  <summary>
                    {en.name} {en.ok === undefined ? "…" : en.ok ? "✓" : "✗"}
                  </summary>
                  <pre>{JSON.stringify(en.args, null, 2)}</pre>
                  {en.content && <pre className="result">{en.content}</pre>}
                </details>
              );
            case "approval":
              return (
                <div key={en.seq} className="approval">
                  <div>
                    <strong>{en.tool}</strong> wants to run
                  </div>
                  <pre>{JSON.stringify(en.args, null, 2)}</pre>
                  {en.decided ? (
                    <em>{en.decided}</em>
                  ) : (
                    <div className="row">
                      <button onClick={() => void respond(en.callId, "allow")}>Allow</button>
                      <button onClick={() => void respond(en.callId, "allow_session")}>Allow for session</button>
                      <button onClick={() => void respond(en.callId, "deny")}>Deny</button>
                    </div>
                  )}
                </div>
              );
            case "system":
              return (
                <div key={en.seq} className="sys">
                  {en.text}
                </div>
              );
          }
        })}
        {state.streaming && (
          <div className="msg assistant streaming">
            <div className="who">agent</div>
            <pre>{state.streaming}</pre>
          </div>
        )}
        {state.error && <div className="error">{state.error}</div>}
        <div ref={bottom} />
      </section>
      <form
        className="composer"
        onSubmit={(e) => {
          e.preventDefault();
          const text = draft.trim();
          if (!text) return;
          setDraft("");
          void send(text);
        }}
      >
        <textarea
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          placeholder="Ask the agent… (Enter to send, Shift+Enter for a newline)"
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              e.currentTarget.form?.requestSubmit();
            }
          }}
        />
        <div className="row">
          <button type="submit" disabled={!draft.trim()}>
            Send
          </button>
          <button type="button" onClick={() => void cancel()} disabled={!busy}>
            Cancel turn
          </button>
        </div>
      </form>
    </main>
  );
}
