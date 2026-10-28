// The console: sign in to the plane, find out what this person administers there, and
// show them the console for that role. Everybody the plane knows signs in: a person who
// administers nothing is a member, whose console is what is theirs (Mine), and an
// administrative role adds the administrative areas.
//
// It is an app of its own. It shares the protocol client and the design tokens with the
// desktop app and nothing else, needs no daemon and no desktop app to run, and talks to
// the plane through its sign-in, its `admin.*` methods for the administrative areas, and
// for the person's own areas the methods any client of the person's calls (`me`,
// `me.clients`, `me.memory`, `sessions.list`, `remote.*`, `artifact.*`), as that person. A
// screen that needed anything else would be a door no other client has.

import { useCallback, useEffect, useMemo, useState } from "react";
import type { JSX } from "react";
import { AdminApi } from "@troupe/client";
import type { AuthSession, Discovery } from "@troupe/client";
import { ConsoleContext, describeError, openInNewTab, planeOf, reserveNewTab, standing } from "./console";
import type { Signed, Standing } from "./console";
import { SignIn } from "./views/SignIn";
import { Shell } from "./views/Shell";
import { Wordmark } from "./views/brand";

type Phase = { kind: "signed-out"; notice: string | null } | { kind: "resolving"; auth: AuthSession } | { kind: "failed"; auth: AuthSession; error: unknown } | { kind: "ready"; auth: AuthSession; standing: Standing; discovery: Discovery | null };

export function App({
  navigate,
  openTab,
}: {
  navigate?: (url: string) => void;
  /** Open an artifact's link in a tab of its own. A test catches the address instead. */
  openTab?: (url: string) => void;
} = {}): JSX.Element {
  const [phase, setPhase] = useState<Phase>({ kind: "signed-out", notice: null });
  const [toast, setToast] = useState<string | null>(null);

  const onSignedIn = useCallback((auth: AuthSession) => setPhase({ kind: "resolving", auth }), []);

  useEffect(() => {
    if (phase.kind !== "resolving") return;
    let live = true;
    const admin = new AdminApi((m, p) => phase.auth.rpc(m, p));
    Promise.all([standing(phase.auth, admin), phase.auth.discover().catch(() => null)]).then(
      ([found, discovery]) => live && setPhase({ kind: "ready", auth: phase.auth, standing: found, discovery }),
      (error: unknown) => live && setPhase({ kind: "failed", auth: phase.auth, error }),
    );
    return () => {
      live = false;
    };
  }, [phase]);

  // A break-glass session ends at its token's expiry with nothing to renew it. The console
  // goes back to its sign-in then, saying so, rather than leaving a page whose every call
  // fails: the session says when it ends, and is asked for its token at that moment, so
  // the screen does not wait for the next click to find out.
  useEffect(() => {
    if (phase.kind !== "ready" || !phase.auth.isBreakGlass) return;
    const { auth } = phase;
    const off = auth.onEnded((why) => setPhase({ kind: "signed-out", notice: why }));
    const until = (auth.me?.expires_at ?? 0) * 1000 - Date.now();
    const t = setTimeout(() => void auth.token().catch(() => undefined), Math.min(Math.max(until, 0) + 50, 2 ** 31 - 1));
    return () => {
      off();
      clearTimeout(t);
    };
  }, [phase]);

  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(null), 6000);
    return () => clearTimeout(t);
  }, [toast]);

  const signOut = useCallback(() => {
    if (phase.kind === "signed-out") return;
    void phase.auth.signOut().then(() => setPhase({ kind: "signed-out", notice: null }));
  }, [phase]);

  const signed = useMemo<Signed | null>(() => {
    if (phase.kind !== "ready") return null;
    return {
      auth: phase.auth,
      admin: new AdminApi((m, p) => phase.auth.rpc(m, p)),
      me: phase.standing.me,
      role: phase.standing.role,
      teams: phase.standing.teams,
      plane: planeOf(phase.auth, phase.discovery),
      signOut,
      notify: setToast,
      openTab: openTab ?? openInNewTab,
      // A test's catch is handed the address when it comes; a browser's tab is opened at the click.
      reserveTab: openTab ? () => (url: string | null) => void (url && openTab(url)) : reserveNewTab,
      follow: navigate ?? ((url: string) => globalThis.location.assign(url)),
    };
  }, [phase, signOut, openTab, navigate]);

  if (phase.kind === "signed-out") return <SignIn onSignedIn={onSignedIn} notice={phase.notice} {...(navigate ? { navigate } : {})} />;

  if (phase.kind === "resolving") {
    return (
      <main className="signin centred" role="status">
        Finding out what is yours here…
      </main>
    );
  }

  if (phase.kind === "failed") {
    return (
      <main className="signin">
        <Wordmark size={40} />
        <section className="banner error" role="alert">
          <p>Signed in, but the plane did not say what you administer: {describeError(phase.error)}</p>
        </section>
        <div className="actions">
          <button type="button" className="primary" onClick={() => setPhase({ kind: "resolving", auth: phase.auth })}>
            Try again
          </button>
          <button type="button" onClick={signOut}>
            Sign out
          </button>
        </div>
      </main>
    );
  }

  if (!signed) return <main className="signin centred" role="status" />;

  return (
    <ConsoleContext.Provider value={signed}>
      <Shell />
      {toast && (
        <div className="toast" role="status">
          <span className="status running" aria-hidden="true">
            ●
          </span>
          <span>{toast}</span>
          <button type="button" aria-label="Dismiss" onClick={() => setToast(null)}>
            ×
          </button>
        </div>
      )}
    </ConsoleContext.Provider>
  );
}
