// The desktop app, offered from its own browser build (troupe #959, #1118): one line at the
// top of the shell that opens the app at the place the person is at, or installs it where it
// is not. The browser build is the surface that has a twin in the app; the console has none.
//
// "Open in the app" follows the place's `troupe://` link and watches whether the page loses
// sight of itself (`followAppLink`, whose comment says where that guess is wrong); when
// nothing opened, the line becomes the install for this platform, the plane's recommended
// version from where the plane says releases are, with the other two platforms beside it.
// Dismissed, it stays away in this browser until the plane recommends another version. On a
// phone it says the app is for a computer and offers this page's address to send yourself.
// Never inside the desktop app's own shell, which is this same bundle.
//
// The same rules hold on the docs site, in a plain script in its theme (docs/overrides/main.html).

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { BANNER_WORDS, PLATFORM_NAME, bannerDismissed, dismissBanner, downloadsOf, followAppLink, inDesktopApp, installOffer, pageWatch, platformOf, webAppOf } from "@troupe/client";
import type { AppDownloads, AuthSession } from "@troupe/client";

/** What the plane signed in to offers a web page: the release it recommends, and where its web app is. */
export interface PlaneOffers {
  downloads: AppDownloads;
  /** `plane.app`, for the web line under a copied link; null where the plane names none. */
  app: string | null;
}

/**
 * Read from the plane's discovery document, which the sign-in holds already. Without a
 * sign-in, the public release page and no web app.
 */
export function usePlaneOffers(auth: AuthSession | null): PlaneOffers {
  const [offers, setOffers] = useState<PlaneOffers>(() => ({ downloads: downloadsOf(null), app: null }));
  useEffect(() => {
    let live = true;
    if (!auth) {
      setOffers({ downloads: downloadsOf(null), app: null });
      return;
    }
    auth.discover().then(
      (d) => live && setOffers({ downloads: downloadsOf(d), app: webAppOf(d) }),
      () => undefined, // a plane that does not answer offers the release page, as before
    );
    return () => {
      live = false;
    };
  }, [auth]);
  return offers;
}

function storage(): Storage | null {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
}

type Stage = "offer" | "opening" | "install" | "nothing";

export function AppBanner({ link, downloads }: { link: string; downloads: AppDownloads }): JSX.Element | null {
  const [dismissed, setDismissed] = useState(() => bannerDismissed(storage(), downloads.version));
  // A plane read after the first draw may recommend another version than the one dismissed.
  const [dismissedAt, setDismissedAt] = useState(downloads.version);
  if (dismissedAt !== downloads.version) {
    setDismissedAt(downloads.version);
    setDismissed(bannerDismissed(storage(), downloads.version));
  }
  const [stage, setStage] = useState<Stage>("offer");
  const [copied, setCopied] = useState(false);
  const platform = platformOf(globalThis.navigator?.userAgent ?? "", globalThis.navigator?.maxTouchPoints ?? 0);

  if (inDesktopApp(globalThis) || dismissed) return null;

  const dismiss = (
    <button
      type="button"
      className="link"
      onClick={() => {
        dismissBanner(storage(), downloads.version);
        setDismissed(true);
      }}
    >
      {BANNER_WORDS.dismiss}
    </button>
  );

  if (platform === "phone") {
    return (
      <section className="banner app-banner" role="note" aria-label="The Troupe app">
        <p>{BANNER_WORDS.phone}</p>
        <button
          type="button"
          className="link"
          onClick={() => {
            void globalThis.navigator?.clipboard?.writeText(globalThis.location.href).then(
              () => setCopied(true),
              () => setCopied(false),
            );
          }}
        >
          {copied ? BANNER_WORDS.copied : BANNER_WORDS.copyLink}
        </button>
        {dismiss}
      </section>
    );
  }

  const open = (): void => {
    setStage("opening");
    void followAppLink(link, pageWatch(globalThis as unknown as Window)).then((how) => setStage(how === "opened" ? "offer" : "nothing"));
  };

  if (stage === "install" || stage === "nothing") {
    const { here, file, others } = installOffer(platform, downloads);
    return (
      <section className="banner app-banner" role="note" aria-label="The Troupe app">
        <p>
          {`${stage === "nothing" ? BANNER_WORDS.nothingOpened : BANNER_WORDS.lead} `}
          {here && file ? (
            <a href={file} rel="noopener">
              {BANNER_WORDS.installFor(PLATFORM_NAME[here], downloads.version)}
            </a>
          ) : (
            <a href={downloads.page} target="_blank" rel="noopener noreferrer">
              {BANNER_WORDS.installAny}
            </a>
          )}
          {others.length > 0 && (
            <span className="also">
              {" "}
              · also for{" "}
              {others.map((p, i) => (
                <span key={p}>
                  {i > 0 ? ", " : ""}
                  <a href={downloads[p]!} rel="noopener">
                    {PLATFORM_NAME[p]}
                  </a>
                </span>
              ))}
            </span>
          )}
        </p>
        <a href={link} className="open-app" onClick={(e) => (e.preventDefault(), open())}>
          {BANNER_WORDS.open}
        </a>
        {dismiss}
      </section>
    );
  }

  return (
    <section className="banner app-banner" role="note" aria-label="The Troupe app">
      <p>{BANNER_WORDS.lead}</p>
      <a href={link} className="open-app" aria-busy={stage === "opening"} onClick={(e) => (e.preventDefault(), open())}>
        {stage === "opening" ? "Opening…" : BANNER_WORDS.open}
      </a>
      <button type="button" className="link" onClick={() => setStage("install")}>
        {BANNER_WORDS.install}
      </button>
      {dismiss}
    </section>
  );
}
