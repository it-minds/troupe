// The way in: which plane, and the identity provider's page and back.
//
// On a deployment the console is on the plane's own host, so the address is the page's
// own and the screen is one button. On load it first finishes a sign-in the provider is
// sending back, then tries the one this tab already holds; either way no questions.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { AuthSession, PlaneUnreachableError } from "@troupe/client";
import { likelyPlaneUrl, newSession, redirectUri, rememberPlane } from "../plane";
import { Wordmark } from "./brand";

export function SignIn({
  onSignedIn,
  navigate = (url) => globalThis.location.assign(url),
}: {
  onSignedIn: (auth: AuthSession) => void;
  /** Leave for the provider. A test catches the address instead of going. */
  navigate?: (url: string) => void;
}): JSX.Element {
  const [planeUrl, setPlaneUrl] = useState(likelyPlaneUrl);
  const [restoring, setRestoring] = useState(true);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState("");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    const url = likelyPlaneUrl();
    if (!url) {
      setRestoring(false);
      return;
    }
    const auth = newSession(url);
    (async () => {
      if (AuthSession.returning) {
        setStatus("Finishing your sign-in…");
        if (await auth.completeRedirectSignIn()) return auth;
      }
      return (await auth.restore()) ? auth : null;
    })().then(
      (signedIn) => {
        if (!live) return;
        if (signedIn) onSignedIn(signedIn);
        else setRestoring(false);
      },
      (e: unknown) => {
        if (!live) return;
        setError(describe(e));
        setRestoring(false);
      },
    );
    return () => {
      live = false;
    };
  }, [onSignedIn]);

  const signIn = async (): Promise<void> => {
    setBusy(true);
    setError(null);
    const url = planeUrl.trim();
    rememberPlane(url);
    try {
      const auth = newSession(url);
      const found = await auth.discover();
      setStatus(`Taking you to ${hostOf(found.issuer)}…`);
      // `select_account`: on a shared machine the last account is not reliably the one
      // the person means, and an administrator's is the one to be sure of.
      const { url: there } = await auth.beginRedirectSignIn({ prompt: "select_account", redirectUri: redirectUri() });
      navigate(there);
    } catch (e) {
      setError(describe(e));
      setBusy(false);
      setStatus("");
    }
  };

  if (restoring) {
    return (
      <main className="signin centred" role="status">
        {status || "Signing you back in…"}
      </main>
    );
  }

  const mounted = (import.meta.env.BASE_URL || "/") !== "/";
  return (
    <main className="signin">
      <header>
        <span className="screen">Console</span>
        <Wordmark size={40} />
        <p>Administer the platform: its teams, what people's own machines are held to, and which clients it serves.</p>
      </header>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          void signIn();
        }}
      >
        {!mounted && (
          <label>
            The plane's address
            <input value={planeUrl} onChange={(e) => setPlaneUrl(e.target.value)} placeholder="https://troupe.example.com" spellCheck={false} disabled={busy} />
          </label>
        )}
        <button type="submit" className="primary" disabled={busy || !planeUrl.trim()}>
          {busy ? status || "Signing in…" : "Sign in"}
        </button>
      </form>
      {error && <SignInError message={error} />}
      <footer>
        <p>The plane's own sign-in, through its identity provider. Your sign-in lasts as long as this tab.</p>
      </footer>
    </main>
  );
}

/** A provider that does not know this address says so in words a registration can act on. */
function SignInError({ message }: { message: string }): JSX.Element {
  const unregistered = /redirect_uri|AADSTS50011|invalid_client|unauthorized_client/i.test(message);
  return (
    <section className="banner error" role="alert">
      <p>{message}</p>
      {unregistered && (
        <p>
          The identity provider does not know this address. Register <code>{redirectUri()}</code> as a single-page application redirect URI on the
          application this plane signs in with.
        </p>
      )}
    </section>
  );
}

function describe(e: unknown): string {
  if (e instanceof PlaneUnreachableError) return e.message;
  return e instanceof Error ? e.message : String(e);
}

function hostOf(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
}
