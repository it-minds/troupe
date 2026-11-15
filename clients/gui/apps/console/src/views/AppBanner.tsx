// The desktop app, offered from the console (troupe #959): one line at the top of every
// screen, above an artifact's sandboxed frame and outside it, that opens the app at the page
// the person is on, or installs it where it is not.
//
// "Open in the app" follows the page's `troupe://` link and watches whether the page loses
// sight of itself (`followAppLink`, whose comment says where that guess is wrong); when
// nothing opened, the line becomes the install for this platform, the plane's recommended
// version from where the plane says releases are, with the other two platforms beside it.
// Dismissed, it stays away in this browser until the plane recommends another version. On a
// phone it says the app is for a computer and offers the link to send yourself. Never inside
// the desktop app, which this bundle is not, but a page could be opened in it.
//
// The same rules hold on the docs site, in a plain script in its theme (docs/overrides/main.html).

import { useEffect, useState } from "react";
import type { JSX } from "react";
import { BANNER_WORDS, PLATFORM_NAME, bannerDismissed, dismissBanner, followAppLink, inDesktopApp, pageWatch, platformOf } from "@troupe/client";
import type { AppDownloads } from "@troupe/client";

/** Asked for by an "Open in the app" elsewhere on the screen that opened nothing: show the install. */
const INSTALL_ASKED = "troupe:app-install";

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
  const [stage, setStage] = useState<Stage>("offer");
  const [copied, setCopied] = useState(false);
  const platform = platformOf(globalThis.navigator?.userAgent ?? "", globalThis.navigator?.maxTouchPoints ?? 0);

  useEffect(() => {
    const asked = (): void => {
      setDismissed(false);
      setStage("nothing");
    };
    globalThis.addEventListener(INSTALL_ASKED, asked);
    return () => globalThis.removeEventListener(INSTALL_ASKED, asked);
  }, []);

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
        <div className="banner-actions">
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
        </div>
      </section>
    );
  }

  const open = (): void => {
    setStage("opening");
    void followAppLink(link, pageWatch(globalThis as unknown as Window)).then((how) => setStage(how === "opened" ? "offer" : "nothing"));
  };

  if (stage === "install" || stage === "nothing") {
    const here = platform === "other" ? null : platform;
    const file = here ? downloads[here] : null;
    const others = (["windows", "macos", "linux"] as const).filter((p) => p !== here && downloads[p]);
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
          {here && file && others.length > 0 && (
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
        <div className="banner-actions">
          <a href={link} className="link-like" onClick={(e) => (e.preventDefault(), open())}>
            {BANNER_WORDS.open}
          </a>
          {dismiss}
        </div>
      </section>
    );
  }

  return (
    <section className="banner app-banner" role="note" aria-label="The Troupe app">
      <p>{BANNER_WORDS.lead}</p>
      <div className="banner-actions">
        <a href={link} className="link-like" aria-busy={stage === "opening"} onClick={(e) => (e.preventDefault(), open())}>
          {stage === "opening" ? "Opening…" : BANNER_WORDS.open}
        </a>
        <span aria-hidden="true">·</span>
        <button type="button" className="link" onClick={() => setStage("install")}>
          {BANNER_WORDS.install}
        </button>
        {dismiss}
      </div>
    </section>
  );
}

/**
 * "Open in the app" on a row or a page: the link for that session or artifact, followed as
 * the banner follows it; when nothing opened, the banner shows the install, dismissed or not.
 */
export function OpenInApp({ link, label = BANNER_WORDS.open }: { link: string; label?: string }): JSX.Element | null {
  if (inDesktopApp(globalThis)) return null;
  return (
    <a
      href={link}
      className="open-in-app"
      onClick={(e) => {
        e.preventDefault();
        void followAppLink(link, pageWatch(globalThis as unknown as Window)).then((how) => {
          if (how === "nothing") globalThis.dispatchEvent(new Event(INSTALL_ASKED));
        });
      }}
    >
      {label}
    </a>
  );
}
