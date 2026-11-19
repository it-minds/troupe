// A session's link, from the console (troupe #1099): "Copy link" on a session's own view and
// on the page of an artifact it published, which puts what the desktop app's Copy link puts
// on the clipboard (`sessionLinkText`); and beside it on an artifact's page "Open in the
// app", since the console does not open a session an artifact names itself.
//
// Nothing is granted by either. The link is an address: whoever can see the artifact sees
// it, and the plane opens the session only for the people it is shared with.

import { useState } from "react";
import type { JSX } from "react";
import { appLink, sessionLinkText } from "@troupe/client";
import { useConsole } from "../console";
import { OpenInApp } from "./OpenInApp";

/** This console's own address, for the line under a private session's link. */
function consoleHere(): string | null {
  const here = globalThis.location;
  return here ? `${here.origin}${here.pathname}` : null;
}

/** "Copy link" for a session; where the browser will not copy, the link is shown to copy by hand. */
export function CopySessionLink({ id, privateSession = false }: { id: string; privateSession?: boolean }): JSX.Element {
  const { plane } = useConsole();
  const [copied, setCopied] = useState<"yes" | "no" | null>(null);
  const text = sessionLinkText(id, plane.url, { app: plane.app, console: consoleHere(), privateSession });
  const copy = async (): Promise<void> => {
    try {
      const clipboard = globalThis.navigator?.clipboard;
      if (!clipboard) throw new Error("no clipboard");
      await clipboard.writeText(text);
      setCopied("yes");
    } catch {
      setCopied("no");
    }
  };
  return (
    <>
      <button type="button" className="link" title="The session's link in the app" onClick={() => void copy()}>
        {copied === "yes" ? "Link copied" : "Copy link"}
      </button>
      {copied === "no" && (
        <span className="hint" role="status">
          {" "}
          This browser would not copy it; select it and copy it by hand: <code className="mono">{text}</code>
        </span>
      )}
    </>
  );
}

/** On an artifact's page: the session that published it, its link, and the app to open it in. */
export function FromSession({ id }: { id: string }): JSX.Element {
  const { plane } = useConsole();
  return (
    <p className="from-session">
      Published from a session. <CopySessionLink id={id} /> <OpenInApp link={appLink({ kind: "session", id, plane: plane.url })} />
    </p>
  );
}
