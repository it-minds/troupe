// "Open in the app" on a session row or an artifact card of the console (troupe #959): an
// administrator may have the desktop app, so each place offers it. The line that offers the
// app on every screen is the desktop app's browser build's, not the console's (#1118): the
// console has no twin in the app.
//
// The link is followed as the desktop app's browser build follows its own (`followAppLink`,
// whose comment says where its guess is wrong); where nothing opened, the link says so beside
// itself with the install for this platform, the plane's recommended version.

import { useState } from "react";
import type { JSX } from "react";
import { BANNER_WORDS, PLATFORM_NAME, followAppLink, inDesktopApp, installOffer, pageWatch, platformOf } from "@troupe/client";
import { useConsole } from "../console";

export function OpenInApp({ link, label = BANNER_WORDS.open }: { link: string; label?: string }): JSX.Element | null {
  const { plane } = useConsole();
  const [nothing, setNothing] = useState(false);
  if (inDesktopApp(globalThis)) return null;
  const platform = platformOf(globalThis.navigator?.userAgent ?? "", globalThis.navigator?.maxTouchPoints ?? 0);
  const { here, file } = installOffer(platform, plane.downloads);
  return (
    <>
      <a
        href={link}
        className="open-in-app"
        onClick={(e) => {
          e.preventDefault();
          setNothing(false);
          void followAppLink(link, pageWatch(globalThis as unknown as Window)).then((how) => setNothing(how === "nothing"));
        }}
      >
        {label}
      </a>
      {nothing && (
        <span className="hint" role="status">
          {" "}
          {BANNER_WORDS.nothingOpened}{" "}
          {here && file ? (
            <a href={file} rel="noopener">
              {BANNER_WORDS.installFor(PLATFORM_NAME[here], plane.downloads.version)}
            </a>
          ) : (
            <a href={plane.downloads.page} target="_blank" rel="noopener noreferrer">
              {BANNER_WORDS.installAny}
            </a>
          )}
        </span>
      )}
    </>
  );
}
