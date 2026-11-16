// Highlighting a code frame (issue #659, docs/design/frames.md §6): the language from the
// fence's first word, the grammars from a built-in set (`grammars.ts`), and the colours
// from the palette's roles in the stylesheet, never a highlighter theme's own. A frame is
// drawn as written first and highlighted once the grammars have loaded, so a reply's first
// paint never waits for them; a fence with no language, or one the set does not have,
// stays as written.

import { useEffect, useState } from "react";

/** A run of text and what kind of token it is, as the grammar names it; none for plain text. */
export interface Segment {
  text: string;
  kind?: string;
}

/** A block of code as lines of segments. */
export type Lines = Segment[][];

/**
 * Past this many lines a block is drawn as written: highlighting it would cost more than a
 * frame that shows twenty lines until it is opened is worth.
 */
export const HIGHLIGHT_CAP = 2000;

type Highlighter = (code: string, language: string) => Lines | null;

let loading: Promise<Highlighter> | null = null;

/** The highlighter, loaded once, the first time a frame needs it. */
export function loadHighlighter(): Promise<Highlighter> {
  loading ??= import("./grammars").then((m) => m.highlight);
  return loading;
}

/**
 * `code` highlighted in `language`, or null while the grammars load, and for good when
 * there is no language, the set has no grammar for it, or the block is past the cap.
 */
export function useHighlight(code: string, language: string | undefined): Lines | null {
  const [done, setDone] = useState<{ code: string; language: string; lines: Lines | null } | null>(null);
  useEffect(() => {
    if (!language || code.split("\n").length > HIGHLIGHT_CAP) return;
    let live = true;
    loadHighlighter()
      .then((highlight) => {
        if (live) setDone({ code, language, lines: highlight(code, language) });
      })
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [code, language]);
  return done && done.code === code && done.language === language ? done.lines : null;
}
