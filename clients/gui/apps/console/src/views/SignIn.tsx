// The way in: which plane, and the identity provider's page and back.
//
// On a deployment the console is on the plane's own host, so the address is the page's
// own and the screen is one button. On load it first finishes a sign-in the provider is
// sending back, then tries the one this tab already holds; either way no questions. A deep
// link opened signed out is where the console lands once the provider sends the browser
// back, not its first screen.
//
// Below the provider's button, and only on a plane whose discovery says it has one, is the
// break-glass door: the plane's break-glass token, typed, for a session that leans on the
// provider for nothing. It is the way in on the day the provider signs nobody in, which is
// exactly the day the button above it does not work, so it lives on this screen and not
// behind it.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { AuthSession, PlaneUnreachableError, errorText, hostOf, unregisteredRedirect } from "@troupe/client";
import { likelyPlaneUrl, newSession, redirectUri, rememberPlace, rememberPlane, restorePlace } from "../plane";
import { parse } from "../route";
import { Wordmark } from "./brand";
import { Field } from "./bits";

export function SignIn({
  onSignedIn,
  navigate = (url) => globalThis.location.assign(url),
  notice = null,
}: {
  onSignedIn: (auth: AuthSession) => void;
  /** Leave for the provider. A test catches the address instead of going. */
  navigate?: (url: string) => void;
  /** Why the last session ended, when it ended by itself: said here, where the person lands. */
  notice?: string | null;
}): JSX.Element {
  const [planeUrl, setPlaneUrl] = useState(likelyPlaneUrl);
  const [restoring, setRestoring] = useState(true);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState("");
  const [error, setError] = useState<string | null>(notice);
  // A plane that did not answer may answer the next time; one that answered "no" wants another sign-in.
  const [unreachable, setUnreachable] = useState(false);
  const [door, setDoor] = useState(false);
  const [glass, setGlass] = useState("");
  const [breaking, setBreaking] = useState(false);

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
        try {
          if (await auth.completeRedirectSignIn()) return auth;
        } finally {
          // Back from the provider, signed in or not: the place asked for goes back in the
          // address, so the console opens there, or a second try keeps it.
          restorePlace();
        }
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
        setError(errorText(e));
        setUnreachable(e instanceof PlaneUnreachableError);
        setRestoring(false);
      },
    );
    return () => {
      live = false;
    };
  }, [onSignedIn]);

  // Whether this plane has a break-glass door is its discovery's to say, asked once the
  // address stands still: on a deployment at load, in development a moment after typing.
  // A plane that does not answer has no door to show, and says nothing here: the button
  // above says what is wrong once it is pressed.
  useEffect(() => {
    if (restoring) return;
    const url = planeUrl.trim();
    if (!/^https?:\/\/\S+$/.test(url)) {
      setDoor(false);
      return;
    }
    let live = true;
    const t = setTimeout(() => {
      newSession(url)
        .discover()
        .then(
          (found) => live && setDoor(found.breakglass === true),
          () => live && setDoor(false),
        );
    }, 300);
    return () => {
      live = false;
      clearTimeout(t);
    };
  }, [planeUrl, restoring]);

  const signIn = async (): Promise<void> => {
    setBusy(true);
    setError(null);
    setUnreachable(false);
    const url = planeUrl.trim();
    rememberPlane(url);
    try {
      const auth = newSession(url);
      const found = await auth.discover();
      setStatus(`Taking you to ${hostOf(found.issuer)}…`);
      // `select_account`: on a shared machine the last account is not reliably the one
      // the person means, and an administrator's is the one to be sure of.
      const { url: there } = await auth.beginRedirectSignIn({ prompt: "select_account", redirectUri: redirectUri() });
      rememberPlace(globalThis.location?.hash ?? "");
      navigate(there);
    } catch (e) {
      setError(errorText(e));
      setUnreachable(e instanceof PlaneUnreachableError);
      setBusy(false);
      setStatus("");
    }
  };

  const breakGlass = async (): Promise<void> => {
    setBreaking(true);
    setError(null);
    const url = planeUrl.trim();
    rememberPlane(url);
    try {
      onSignedIn(await AuthSession.breakGlass(url, glass));
    } catch (e) {
      setError(errorText(e));
      setUnreachable(false);
      setBreaking(false);
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
  const purpose = purposeOf(globalThis.location?.hash ?? "");
  return (
    <main className="signin">
      <header>
        <span className="screen">Console</span>
        <Wordmark size={40} />
        <p>Steer the laptop sessions offered to you, and see what is yours on the plane; if you administer it, its teams, what people's own machines are held to, and which clients it serves.</p>
      </header>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          void signIn();
        }}
      >
        {purpose && <p>{purpose}</p>}
        {!mounted && (
          <Field label="The plane's address">
            {(p) => <input {...p} value={planeUrl} onChange={(e) => setPlaneUrl(e.target.value)} placeholder="https://troupe.example.com" spellCheck={false} disabled={busy} />}
          </Field>
        )}
        <button type="submit" className="primary" disabled={busy || !planeUrl.trim()}>
          {busy ? status || "Signing in…" : "Sign in"}
        </button>
      </form>
      {error && <SignInError message={error} onRetry={unreachable && !busy && planeUrl.trim() ? () => void signIn() : null} />}
      {door && (
        <form
          className="breakglass"
          aria-labelledby="breakglass-title"
          onSubmit={(e) => {
            e.preventDefault();
            void breakGlass();
          }}
        >
          <h2 id="breakglass-title">Break glass</h2>
          <p>
            For the day the identity provider cannot sign anybody in. This door takes the plane's break-glass token, which its administrators hold
            outside the provider, and opens the console as a platform administrator until the session the plane answers runs out. Every use is recorded.
          </p>
          <Field label="Break-glass token">
            {(p) => <input {...p} type="password" value={glass} onChange={(e) => setGlass(e.target.value)} autoComplete="off" spellCheck={false} disabled={breaking || busy} />}
          </Field>
          <button type="submit" disabled={breaking || busy || !glass.trim()}>
            {breaking ? "Opening the door…" : "Break glass"}
          </button>
        </form>
      )}
      <footer>
        <p>The plane's own sign-in, through its identity provider. Your sign-in lasts as long as this tab.</p>
      </footer>
    </main>
  );
}

/**
 * What this sign-in is for, when the address says: the artifacts host sends a signed-out
 * viewer here to open an artifact, or to spend a link to one, and the console goes on there
 * once signed in. Which artifact it cannot say before then. Any other address is the
 * console's own sign-in, which needs no line.
 */
function purposeOf(hash: string): string | null {
  const route = parse(hash);
  if (route?.page !== "artifacts") return null;
  const [first, second] = route.path ?? [];
  if (!second) return null;
  if (first === "open") return "Sign in to open an artifact";
  if (first === "link") return "Sign in to open a shared artifact";
  return null;
}

/**
 * A failed sign-in, as an alert: a plane that did not answer is asked again from here, and a
 * provider that does not know this address says so in words a registration can act on.
 */
function SignInError({ message, onRetry }: { message: string; onRetry: (() => void) | null }): JSX.Element {
  const unregistered = unregisteredRedirect(message);
  return (
    <section className="banner error" role="alert">
      <p>{message}</p>
      {onRetry && (
        <p className="actions">
          <button type="button" onClick={onRetry}>
            Try again
          </button>
        </p>
      )}
      {unregistered && (
        <p>
          The identity provider does not know this address. Register <code>{redirectUri()}</code> as a single-page application redirect URI on the
          application this plane signs in with.
        </p>
      )}
    </section>
  );
}
