// The console: sign in to the plane, find out what this person administers there, and
// show them the console for that role, or say plainly that they administer nothing.
//
// It is an app of its own. It shares the protocol client and the design tokens with the
// desktop app and nothing else, needs no daemon and no desktop app to run, and talks to
// the plane through its sign-in and its `admin.*` methods alone, besides one `me` for who
// is signed in. A screen that needed anything else would be a door no other admin client
// has.

import { useCallback, useEffect, useMemo, useState } from "react";
import type { JSX } from "react";
import { AdminApi } from "@troupe/client";
import type { AuthSession, Discovery } from "@troupe/client";
import { ConsoleContext, describeError, planeOf, standing } from "./console";
import type { Signed, Standing } from "./console";
import { SignIn } from "./views/SignIn";
import { Shell } from "./views/Shell";
import { Wordmark } from "./views/brand";

type Phase = { kind: "signed-out" } | { kind: "resolving"; auth: AuthSession } | { kind: "failed"; auth: AuthSession; error: unknown } | { kind: "ready"; auth: AuthSession; standing: Standing; discovery: Discovery | null };

export function App({ navigate }: { navigate?: (url: string) => void } = {}): JSX.Element {
  const [phase, setPhase] = useState<Phase>({ kind: "signed-out" });
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

  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(null), 6000);
    return () => clearTimeout(t);
  }, [toast]);

  const signOut = useCallback(() => {
    if (phase.kind === "signed-out") return;
    void phase.auth.signOut().then(() => setPhase({ kind: "signed-out" }));
  }, [phase]);

  const signed = useMemo<Signed | null>(() => {
    if (phase.kind !== "ready" || phase.standing.kind !== "admin") return null;
    return {
      auth: phase.auth,
      admin: new AdminApi((m, p) => phase.auth.rpc(m, p)),
      me: phase.standing.me,
      role: phase.standing.role,
      teams: phase.standing.teams,
      plane: planeOf(phase.auth, phase.discovery),
      signOut,
      notify: setToast,
    };
  }, [phase, signOut]);

  if (phase.kind === "signed-out") return <SignIn onSignedIn={onSignedIn} {...(navigate ? { navigate } : {})} />;

  if (phase.kind === "resolving") {
    return (
      <main className="signin centred" role="status">
        Finding out what you administer…
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

  if (!signed) {
    const me = phase.standing.me;
    return (
      <main className="signin">
        <Wordmark size={40} />
        <h1>Nothing to administer here</h1>
        <p>
          You are signed in to {planeOf(phase.auth, phase.discovery).name} as {me.display_name ?? me.subject}, who administers no team and is not a
          platform admin. A platform admin is a member of the identity provider's group the plane names for it; a team admin is named on a team by a
          platform admin.
        </p>
        <div className="actions">
          <button type="button" onClick={signOut}>
            Sign out
          </button>
        </div>
      </main>
    );
  }

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
