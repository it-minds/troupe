// The connect screen. It says three things before anything else happens: which plane,
// who the identity provider is, and where this build is keeping the one long-lived
// secret it holds — because a browser build keeps it somewhere weaker than a desktop
// shell does, and that is the person's business, not a footnote.
//
// Two sign-ins, and the host decides which. A browser is sent to the provider and comes
// back with a code (authorization code + PKCE); anything without a redirect to come back
// from shows a code to type somewhere else (the device grant). The difference is not a
// preference — Microsoft Entra refuses a browser's request for a device code outright,
// and a page cannot even be told why.

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { AuthSession, PlaneUnreachableError } from "@troupe/client";
import type { DeviceAuthorization, Discovery } from "@troupe/client";
import { capabilities, likelyPlaneUrl, prefs, redirectUri, tokenStore } from "../shell";

const SECRETS: Record<string, string> = {
  "os-keychain": "Your sign-in is kept in this computer's credential store.",
  "browser-storage":
    "This is the browser version. Your sign-in is kept in this browser, where anything else running on this address could read it. The desktop app keeps it in the computer's own credential store.",
  memory: "Nothing can be saved here, so you will be asked to sign in again next time.",
};

export function SignIn({ onSignedIn }: { onSignedIn: (auth: AuthSession) => void }): JSX.Element {
  const [planeUrl, setPlaneUrl] = useState(() => prefs.get("planeUrl", likelyPlaneUrl()));
  const [device, setDevice] = useState<DeviceAuthorization | null>(null);
  const [discovery, setDiscovery] = useState<Discovery | null>(null);
  const [status, setStatus] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [restoring, setRestoring] = useState(true);
  const caps = capabilities();

  // Two things happen on load, in this order: finish a sign-in the provider is sending
  // back, or sign back in from what the store already holds. Either way, no questions.
  useEffect(() => {
    let live = true;
    const url = prefs.get("planeUrl", likelyPlaneUrl());
    const returning = AuthSession.returning;
    if (!url) {
      setRestoring(false);
      return;
    }
    const auth = new AuthSession({ planeUrl: url, store: tokenStore() });

    (async () => {
      if (returning) {
        setStatus("finishing your sign-in…");
        const credential = await auth.completeRedirectSignIn();
        if (credential) return auth;
      }
      return (await auth.restore()) ? auth : null;
    })()
      .then((signedIn) => {
        if (!live) return;
        if (signedIn) onSignedIn(signedIn);
        else setRestoring(false);
      })
      .catch((e: unknown) => {
        if (!live) return;
        setError(describe(e));
        setRestoring(false);
      });

    return () => {
      live = false;
    };
  }, [onSignedIn]);

  const signIn = async (): Promise<void> => {
    setBusy(true);
    setError(null);
    setDevice(null);
    prefs.set("planeUrl", planeUrl);
    const auth = new AuthSession({ planeUrl, store: tokenStore() });
    try {
      const found = await auth.discover();
      setDiscovery(found);

      if (auth.preferredFlow === "redirect") {
        setStatus(`taking you to ${hostOf(found.issuer)}…`);
        // `select_account` rather than a silent sign-in: on a shared machine the last
        // account is not reliably the one the person means, and being asked is cheap.
        const { url } = await auth.beginRedirectSignIn({ prompt: "select_account", redirectUri: redirectUri() });
        globalThis.location.assign(url);
        return; // this tab is leaving
      }

      await auth.signIn({ onDeviceCode: setDevice, onStatus: setStatus });
      onSignedIn(auth);
    } catch (e) {
      setError(describe(e));
      setDevice(null);
    } finally {
      setBusy(false);
      setStatus("");
    }
  };

  if (restoring) return <main className="centred muted">{status || "Signing you back in…"}</main>;

  return (
    <main className="signin">
      <header className="stack" style={{ gap: "var(--space-2)" }}>
        <div className="wordmark">Troupe</div>
        <p>Sign in to see your team's sessions, and answer what is waiting for you.</p>
      </header>

      <form
        onSubmit={(e) => {
          e.preventDefault();
          void signIn();
        }}
      >
        <label>
          Where your team's Troupe is
          <input
            value={planeUrl}
            onChange={(e) => setPlaneUrl(e.target.value)}
            placeholder="https://troupe.example.com"
            spellCheck={false}
            disabled={busy}
          />
        </label>
        <button type="submit" disabled={busy || !planeUrl.trim()}>
          {busy ? status || "Signing in…" : "Sign in"}
        </button>
      </form>

      {device && (
        <section className="device">
          <p>
            Open{" "}
            <a href={device.verification_uri_complete ?? device.verification_uri} target="_blank" rel="noreferrer noopener">
              {device.verification_uri}
            </a>{" "}
            and enter this code:
          </p>
          <code className="usercode">{device.user_code}</code>
          <p className="muted">{status}</p>
        </section>
      )}

      {error && <SignInError message={error} />}

      <footer>
        {discovery && <p>You will sign in with {hostOf(discovery.issuer)}.</p>}
        <p>{SECRETS[caps.secrets]}</p>
        {!caps.localSessions && <p>Sessions running on this computer are not available in the browser version.</p>}
      </footer>
    </main>
  );
}

/**
 * The two failures worth explaining rather than printing.
 *
 * A provider that refuses the redirect says so in the URL it sends back, and the two
 * reasons it gives are both a registration problem that no amount of retrying fixes —
 * so the message says what to register instead of inviting another attempt.
 */
function SignInError({ message }: { message: string }): JSX.Element {
  const origin = redirectUri() || "this address";
  const unregistered = /redirect_uri|AADSTS50011|invalid_client|unauthorized_client/i.test(message);

  return (
    <section className="banner error copy">
      <p>{message}</p>
      {unregistered && (
        <p>
          The identity provider does not know this address. Register <code>{origin}</code> as a{" "}
          <strong>single-page application</strong> redirect URI on the application this plane signs in with — for Microsoft Entra that is
          Authentication → Add a platform → Single-page application, not Web.
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
