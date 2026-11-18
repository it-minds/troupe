// The desktop app's folder chooser, as a button and the sentence under it. Where the
// system's dialog could not be opened, or failed, the sentence says so rather than the
// button doing nothing: a typed path still works, and the sentence says that too. A
// dialog the person closed is no failure and says nothing.

import { useState } from "react";
import type { JSX } from "react";
import { shell } from "../shell";
import { errorText } from "@troupe/client";

/** The button, where this host has a chooser, and what became of the last press, where it failed. */
export function useChooseFolder(onPick: (path: string) => void): { button: JSX.Element | null; failed: JSX.Element | null } {
  const chooser = shell()?.pickDirectory;
  const [failed, setFailed] = useState<string | null>(null);
  if (!chooser) return { button: null, failed: null };
  const choose = (): void => {
    setFailed(null);
    chooser()
      .then((path) => path && onPick(path))
      .catch((e: unknown) => {
        const why = (errorText(e)).replace(/\.$/, "");
        setFailed(`The folder chooser did not open: ${why}. Type the path instead.`);
      });
  };
  return {
    button: (
      <button type="button" onClick={choose}>
        Choose…
      </button>
    ),
    failed: failed ? (
      <p className="note error" role="alert">
        {failed}
      </p>
    ) : null,
  };
}
