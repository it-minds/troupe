// The phone's sheet: one surface over the whole window, opened from a button, with its
// head one line (a name on the left, the way out on the right) and its body below. The
// rail's destinations open in it from the top bar's menu, and the sessions list's filters
// from its Filter button; it is one component so a phone has one pattern for "more than
// fits here".

import { useEffect, useRef } from "react";
import type { JSX, ReactNode } from "react";
import { Wordmark } from "./views/brand";

/**
 * A sheet over the whole window. The focus goes to its way out when it opens and back to
 * whatever opened it when it shuts, Tab stays inside it, and Escape shuts it. `title` names it in the head
 * where the wordmark would stand (the rail's sheet carries the wordmark, as the rail does).
 */
export function NavSheet({
  onClose,
  children,
  label = "Menu",
  title,
  closeLabel = "Close",
}: {
  onClose: () => void;
  children: ReactNode;
  /** What a screen reader calls the dialog. */
  label?: string;
  /** The words in the head; without them, the wordmark. */
  title?: string;
  /** The words on the way out. */
  closeLabel?: string;
}): JSX.Element {
  const close = useRef<HTMLButtonElement>(null);
  const sheet = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    close.current?.focus();
    const keys = (e: KeyboardEvent): void => {
      if (e.key === "Escape") onClose();
      // The window behind is covered, so Tab goes round the sheet rather than into it.
      if (e.key === "Tab" && sheet.current) {
        const stops = [...sheet.current.querySelectorAll<HTMLElement>("button, select, input, textarea, a[href], [tabindex]")].filter(
          (el) => !(el as HTMLButtonElement).disabled && el.tabIndex >= 0,
        );
        const first = stops[0];
        const last = stops[stops.length - 1];
        if (!first || !last) return;
        const inside = sheet.current.contains(document.activeElement);
        if (e.shiftKey && (document.activeElement === first || !inside)) {
          e.preventDefault();
          last.focus();
        } else if (!e.shiftKey && (document.activeElement === last || !inside)) {
          e.preventDefault();
          first.focus();
        }
      }
    };
    document.addEventListener("keydown", keys);
    return () => {
      document.removeEventListener("keydown", keys);
      opener?.focus();
    };
  }, [onClose]);
  return (
    <div ref={sheet} className="nav-sheet" role="dialog" aria-modal="true" aria-label={label}>
      <div className="nav-sheet-head">
        {title ? <span className="nav-sheet-title">{title}</span> : <Wordmark size={24} />}
        <button ref={close} type="button" className="link" onClick={onClose}>
          {closeLabel}
        </button>
      </div>
      {children}
    </div>
  );
}
