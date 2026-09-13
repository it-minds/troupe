// The shell. Sign in, then one list and the things you reach from it.
//
// There is no router and no session state: which screen is showing is a local
// variable, and every screen rebuilds itself from the platform and the machine running
// the work. Closing the window loses a scroll position.

import { useCallback, useState } from "react";
import type { JSX } from "react";
import { awaitingApproval } from "@troupe/client";
import type { AuthSession } from "@troupe/client";
import { useFleet } from "./hooks";
import { capabilities } from "./shell";
import { Approvals } from "./views/Approvals";
import { Sessions } from "./views/Sessions";
import { Session } from "./views/Session";
import { SignIn } from "./views/SignIn";
import { ThemeToggle } from "./views/bits";

type Where = { screen: "sessions" } | { screen: "approvals" } | { screen: "session"; id: string };

export function App(): JSX.Element {
  const [auth, setAuth] = useState<AuthSession | null>(null);
  const [where, setWhere] = useState<Where>({ screen: "sessions" });
  const { snapshot, refresh } = useFleet(auth);

  const signOut = useCallback(async () => {
    await auth?.signOut();
    setAuth(null);
    setWhere({ screen: "sessions" });
  }, [auth]);

  if (!auth) return <SignIn onSignedIn={setAuth} />;

  const waiting = awaitingApproval(snapshot.rows).length;
  const planeError = snapshot.sources["plane"]?.error ?? null;
  const row = where.screen === "session" ? snapshot.rows.find((r) => r.id === where.id) : undefined;
  const caps = capabilities();

  return (
    <div className="app">
      <div className="rail">
        <div className="wordmark">Troupe</div>
        <nav>
          <button aria-current={where.screen === "sessions" ? "page" : undefined} onClick={() => setWhere({ screen: "sessions" })}>
            Sessions <span className="count muted">{snapshot.rows.length}</span>
          </button>
          <button aria-current={where.screen === "approvals" ? "page" : undefined} onClick={() => setWhere({ screen: "approvals" })}>
            Waiting for you
            {waiting > 0 && (
              <span className="pill waiting">
                <span className="dot" aria-hidden="true" />
                {waiting}
              </span>
            )}
          </button>
        </nav>
        <span className="spacer" />
        <div className="me">
          <div className="name">{auth.me?.display_name ?? auth.me?.subject ?? "Signed in"}</div>
          <div className="teams muted">{auth.me?.teams.join(", ") || "no team"}</div>
          <div className="host muted micro" title={`Your sign-in is kept in: ${caps.secrets.replace("-", " ")}`}>
            {caps.shellName ?? "browser"}
          </div>
          <ThemeToggle />
          <button className="link" onClick={() => void signOut()}>
            Sign out
          </button>
        </div>
      </div>

      <main>
        {where.screen === "sessions" && (
          <Sessions
            auth={auth}
            rows={snapshot.rows}
            loading={snapshot.loading}
            error={planeError}
            onOpen={(id) => setWhere({ screen: "session", id })}
            onCreated={(id) => {
              refresh();
              setWhere({ screen: "session", id });
            }}
          />
        )}

        {where.screen === "approvals" && (
          <Approvals auth={auth} rows={snapshot.rows} onOpen={(id) => setWhere({ screen: "session", id })} onAnswered={refresh} />
        )}

        {where.screen === "session" && (
          <Session auth={auth} row={row} sessionId={where.id} onBack={() => setWhere({ screen: "sessions" })} />
        )}
      </main>
    </div>
  );
}
