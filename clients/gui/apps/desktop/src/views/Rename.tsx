// A session's name as a field, in the list's row or in the session's head: Enter keeps what
// is typed, an empty one takes the name off, Esc or leaving the field keeps the name as it
// was. The name is the session's, for everyone who sees it, and its owner's to change.

import { useEffect, useRef, useState } from "react";
import type { JSX } from "react";

export function RenameField({
  title,
  onRename,
  onDone,
}: {
  /** The name it has now, which the field starts from. */
  title: string;
  /** Send the name; rejects with the server's refusal, which the caller says. */
  onRename: (title: string) => Promise<void>;
  /** Close the field, renamed or not. */
  onDone: () => void;
}): JSX.Element {
  const [value, setValue] = useState(title);
  const [busy, setBusy] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  useEffect(() => {
    input.current?.focus();
    input.current?.select();
  }, []);
  return (
    <input
      ref={input}
      className="rename"
      aria-label="Session name"
      title="Enter keeps the name; an empty one takes it off; Esc leaves it as it was"
      maxLength={200}
      value={value}
      disabled={busy}
      onChange={(e) => setValue(e.target.value)}
      onBlur={() => !busy && onDone()}
      onKeyDown={(e) => {
        if (e.key === "Escape") {
          e.preventDefault();
          e.stopPropagation();
          onDone();
        } else if (e.key === "Enter") {
          e.preventDefault();
          if (value.trim() === title) return onDone();
          setBusy(true);
          void onRename(value.trim()).finally(onDone);
        }
      }}
    />
  );
}
