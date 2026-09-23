// The shell. Sign in, or use this computer only, then one list and the things you reach
// from it.
//
// There is no router and no session state: which screen is showing is a local
// variable, and every screen rebuilds itself from the platform and the machine running
// the work. Closing the window loses a scroll position.
//
// Which of the two the app is talking to is its mode (`mode.ts`), and the screens are
// handed what the mode gives them rather than guessing from whether somebody happens to
// be signed in: in local mode there is no `auth`, the screens that only a plane can fill
// are not offered, and nothing here calls a plane.

import { useCallback, useEffect, useState } from "react";
import type { JSX } from "react";
import { awaitingApproval } from "@troupe/client";
import type { AuthSession } from "@troupe/client";
import { useAdmin, useDaemon, useFleet } from "./hooks";
import { chooseLocalOnly, storedLocalOnly } from "./mode";
import type { AppMode } from "./mode";
import { capabilities, likelyPlaneUrl, prefs } from "./shell";
import { hasChosen, markChosen, useAppearance } from "./theme";
import { Approvals } from "./views/Approvals";
import { Local } from "./views/Local";
import { AppearanceSettings, Onboarding } from "./views/Appearance";
import { Review } from "./views/Review";
import { Sessions } from "./views/Sessions";
import { Session } from "./views/Session";
import { newSession, SignIn } from "./views/SignIn";
import { Eye, Wordmark } from "./views/brand";

type Where =
  | { screen: "sessions" }
  | { screen: "approvals" }
  | { screen: "review" }
  | { screen: "local" }
  | { screen: "appearance" }
  | { screen: "session"; id: string };

/** How often an app working offline asks whether the plane is back. */
const OFFLINE_RETRY_MS = 15_000;

export function App(): JSX.Element {
  const [localOnly, setLocalOnlyState] = useState(storedLocalOnly);
  // Plane mode with the plane not answering, and the person carrying on here meanwhile.
  // Not remembered: the next launch asks the plane first, which is the point of it.
  const [offline, setOffline] = useState(false);
  // Offline, and the plane has answered again but no longer honours the stored sign-in.
  const [expired, setExpired] = useState(false);
  const [asking, setAsking] = useState(0);
  const [checking, setChecking] = useState(false);
  const [auth, setAuth] = useState<AuthSession | null>(null);
  const mode: AppMode = localOnly || offline ? "local" : "plane";
  const [where, setWhere] = useState<Where>({ screen: "sessions" });
  const daemon = useDaemon();
  const { snapshot, refresh } = useFleet(auth, daemon.client);
  // Only the Review screen still needs it: `admin.runs.list` is how a reviewer finds
  // the runs nobody has looked at. Administration itself is the console's, at /admin.
  const adminApi = useAdmin(auth);
  const appearance = useAppearance();
  // Asked once, on this person's first sign-in, and never again. Tracked per subject:
  // two people on one computer are two first sign-ins, and the second should not
  // inherit an answer the first one gave.
  const [chosen, setChosen] = useState(false);
  const planeUrl = prefs.get("planeUrl", likelyPlaneUrl());

  const signOut = useCallback(async () => {
    await auth?.signOut();
    setAuth(null);
    setWhere({ screen: "sessions" });
    // Whoever signs in next is a different person until proved otherwise, and whether
    // *they* have picked a theme is a question about them.
    setChosen(false);
  }, [auth]);

  const setLocalOnly = useCallback((on: boolean) => {
    chooseLocalOnly(on);
    setLocalOnlyState(on);
    setOffline(false);
    setExpired(false);
    // Let go of, not signed out of: the refresh token stays in its store, so turning
    // this off again signs straight back in. Signing out is a different button.
    if (on) setAuth(null);
  }, []);

  // Offline, the plane is asked again every so often, and the app goes back to it the
  // moment it answers — with the sessions that ran here still in the one list, because
  // they were never the plane's to take away. "Try now" asks at once.
  useEffect(() => {
    if (!offline || expired || !planeUrl) return;
    let live = true;
    const ask = (): void => {
      const session = newSession(planeUrl);
      setChecking(true);
      // Discovery first, because it is the question "is it there?": a stored sign-in
      // that is missing answers `null` without asking anybody, which is not the plane
      // coming back.
      session
        .discover()
        .then(() => session.restore())
        .then((signedIn) => {
          if (!live) return;
          if (signedIn) {
            setAuth(session);
            setOffline(false);
          } else {
            setExpired(true);
          }
        })
        .catch(() => undefined) // still not answering
        .finally(() => live && setChecking(false));
    };
    if (asking > 0) ask();
    const timer = setInterval(ask, OFFLINE_RETRY_MS);
    return () => {
      live = false;
      clearInterval(timer);
    };
  }, [offline, expired, planeUrl, asking]);

  if (mode === "plane" && !auth) {
    return <SignIn onSignedIn={setAuth} onLocalOnly={() => setLocalOnly(true)} onOffline={() => setOffline(true)} />;
  }

  if (auth && !chosen && !hasChosen(auth.me?.subject)) {
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
  const local = snapshot.rows.filter((r) => r.kind !== "team").length;

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
          {/* Review reads the plane's record of unattended runs. There is none without
              a plane, so it is not offered, rather than offered and empty. */}
          {auth && (
            <button aria-current={where.screen === "review" ? "page" : undefined} onClick={() => setWhere({ screen: "review" })}>
              Review
            </button>
          )}
          <button aria-current={where.screen === "local" ? "page" : undefined} onClick={() => setWhere({ screen: "local" })}>
            This computer
            {daemon.status === "connected" && <span className="count muted">{local}</span>}
          </button>
          <button aria-current={where.screen === "appearance" ? "page" : undefined} onClick={() => setWhere({ screen: "appearance" })}>
            Appearance
          </button>
        </nav>
        <span className="spacer" />
        {auth ? (
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
        ) : (
          // Nobody is signed in, and nobody needs to be: the sessions here belong to
          // this computer's user, so that is who is named.
          <div className="me">
            <div className="name">This computer</div>
            <div className="teams muted">{daemon.user?.name ?? "the daemon is not connected"}</div>
            <div className="host muted micro">
              {!offline ? "local only" : expired ? "not signed in to the platform" : "the platform is not answering"} ·{" "}
              {caps.shellName ?? "browser"}
            </div>
          </div>
        )}
      </div>

      <main>
        {offline && (
          <div className="banner offline">
            <p>
              {expired
                ? "The platform is answering again. Sign in to see your team's sessions beside these; the ones here carry on either way."
                : "The platform is not answering, so this is the sessions on this computer. Troupe goes back to it by itself when it answers."}
            </p>
            <span className="micro">{planeUrl}</span>
            {expired ? (
              <button
                className="link"
                onClick={() => {
                  setOffline(false);
                  setExpired(false);
                }}
              >
                Sign in
              </button>
            ) : (
              <button className="link" disabled={checking} onClick={() => setAsking((n) => n + 1)}>
                {checking ? "Asking…" : "Try now"}
              </button>
            )}
          </div>
        )}

        {where.screen === "sessions" && (
          <Sessions
            auth={auth}
            daemon={daemon.client}
            linked={Boolean(daemon.identity?.linked)}
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

        {where.screen === "local" && (
          <Local
            daemon={daemon}
            auth={auth}
            me={auth?.me ? { subject: auth.me.subject, display_name: auth.me.display_name } : null}
            planeUrl={auth?.planeUrl ?? ""}
            localOnly={localOnly}
            onLocalOnly={setLocalOnly}
          />
        )}

        {where.screen === "review" && auth && (
          <Review auth={auth} admin={adminApi} daemon={daemon.client} teams={auth.me?.teams ?? []} onOpen={(id) => setWhere({ screen: "session", id })} />
        )}

        {where.screen === "appearance" && <AppearanceSettings {...appearance} />}

        {where.screen === "approvals" && (
          <Approvals
            auth={auth}
            daemon={daemon.client}
            rows={snapshot.rows}
            onOpen={(id) => setWhere({ screen: "session", id })}
            onAnswered={refresh}
          />
        )}

        {where.screen === "session" && (
          <Session
            auth={auth}
            daemon={daemon.client}
            machineUser={daemon.user?.subject ?? null}
            row={row}
            sessionId={where.id}
            onBack={() => setWhere({ screen: "sessions" })}
          />
        )}
      </main>
    </div>
  );
}
