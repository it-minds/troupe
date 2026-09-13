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
import { hasChosen, markChosen, useAppearance } from "./theme";
import { Approvals } from "./views/Approvals";
import { AppearanceSettings, Onboarding } from "./views/Appearance";
import { Sessions } from "./views/Sessions";
import { Session } from "./views/Session";
import { SignIn } from "./views/SignIn";
import { Eye, Wordmark } from "./views/brand";

type Where = { screen: "sessions" } | { screen: "approvals" } | { screen: "appearance" } | { screen: "session"; id: string };

export function App(): JSX.Element {
  const [auth, setAuth] = useState<AuthSession | null>(null);
  const [where, setWhere] = useState<Where>({ screen: "sessions" });
  const { snapshot, refresh } = useFleet(auth);
  const appearance = useAppearance();
  // Asked once, on this person's first sign-in, and never again. Tracked per subject:
  // two people on one computer are two first sign-ins, and the second should not
  // inherit an answer the first one gave.
  const [chosen, setChosen] = useState(false);

  const signOut = useCallback(async () => {
    await auth?.signOut();
    setAuth(null);
    setWhere({ screen: "sessions" });
    // Whoever signs in next is a different person until proved otherwise, and whether
    // *they* have picked a theme is a question about them.
    setChosen(false);
  }, [auth]);

  if (!auth) return <SignIn onSignedIn={setAuth} />;

  if (!chosen && !hasChosen(auth.me?.subject)) {
    return (
      <Onboarding
        name={auth.me?.display_name ?? null}
        appearance={appearance}
        onDone={() => {
          markChosen(auth.me?.subject);
          setChosen(true);
        }}
      />
    );
  }

  const waiting = awaitingApproval(snapshot.rows).length;
  const planeError = snapshot.sources["plane"]?.error ?? null;
  const row = where.screen === "session" ? snapshot.rows.find((r) => r.id === where.id) : undefined;
  const caps = capabilities();

  return (
    <div className="app">
      <div className="rail">
        <Wordmark size={20} />
        <nav>
          <button aria-current={where.screen === "sessions" ? "page" : undefined} onClick={() => setWhere({ screen: "sessions" })}>
            Sessions <span className="count muted">{snapshot.rows.length}</span>
          </button>
          <button aria-current={where.screen === "approvals" ? "page" : undefined} onClick={() => setWhere({ screen: "approvals" })}>
            Waiting for you
            {waiting > 0 && (
              <span className="pill waiting">
                <Eye status="waiting" />
                {waiting}
              </span>
            )}
          </button>
          <button aria-current={where.screen === "appearance" ? "page" : undefined} onClick={() => setWhere({ screen: "appearance" })}>
            Appearance
          </button>
        </nav>
        <span className="spacer" />
        <div className="me">
          <div className="name">{auth.me?.display_name ?? auth.me?.subject ?? "Signed in"}</div>
          <div className="teams muted">{auth.me?.teams.join(", ") || "no team"}</div>
          <div className="host muted micro" title={`Your sign-in is kept in: ${caps.secrets.replace("-", " ")}`}>
            {caps.shellName ?? "browser"}
          </div>
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

        {where.screen === "appearance" && <AppearanceSettings {...appearance} />}

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
