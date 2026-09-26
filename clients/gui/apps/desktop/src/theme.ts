// Which theme a person reads in, and whether it is light or dark.
//
// Two questions, deliberately not one. Four themes times two modes is eight
// combinations, but a person is not choosing between "Signal light" and "Footlight
// dark" — they are choosing a palette, and separately saying whether their eyes want
// light or dark right now. Eight cards would make them compare things that are not
// alternatives; two controls take ten seconds.
//
// Both answers become attributes on `<html>` and nothing else:
//
//   data-theme="afterglow" | "signal" | "footlight" | "limelight"
//   data-mode="light" | "dark"        absent means follow the system
//
// `tokens.css` does the rest. There is no theme-specific component anywhere in this
// app and there must never be one: a component that needs a special case for one theme
// is telling you that theme's token values are wrong.
//
// The choice is per person and kept in this browser. Nothing about a theme carries
// meaning — two people in the same session see the same content — so it never leaves
// the machine and no server is asked about it. When the plane learns how to keep it on
// the user record, this is the one module that changes.

import { useCallback, useEffect, useState } from "react";
import { prefs } from "./shell";

export type ThemeId = "afterglow" | "signal" | "footlight" | "limelight";
export type Mode = "system" | "light" | "dark";

export interface Theme {
  id: ThemeId;
  /** How the theme names itself. */
  name: string;
  /** One line, in the person's terms: what it will feel like to read all day. */
  blurb: string;
  /** The one colour this theme reserves for "a person must decide". */
  reserved: string;
}

/**
 * The four, in the order they are offered.
 *
 * Afterglow leads because it is the app's design (Decision 702): the type, the spacing
 * and the square corners are its, in every theme. The other three are the palettes that
 * came before it, kept on the same contract until the appearance screen is redrawn.
 */
export const THEMES: readonly Theme[] = [
  {
    id: "afterglow",
    name: "Afterglow",
    blurb: "Void and pit under cream, and two lights on it: pink is you being asked, cyan is the machine working.",
    reserved: "pink",
  },
  {
    id: "signal",
    name: "Signal",
    blurb: "Neutral graphite, and a printer's duotone on top: cyan is the machine working, magenta is you being asked.",
    reserved: "magenta",
  },
  {
    id: "footlight",
    name: "Footlight",
    blurb: "Ink navy and drafting blue-grey, with one stage amber. Quiet infrastructure that disappears behind the work.",
    reserved: "amber",
  },
  {
    id: "limelight",
    name: "Limelight",
    blurb: "Warm ink — smoked oak and auditorium dark — lit by limelight, the first stage light there ever was.",
    reserved: "lime",
  },
];

export const DEFAULT_THEME: ThemeId = "afterglow";
export const DEFAULT_MODE: Mode = "system";

export const MODES: readonly { id: Mode; label: string; consequence: string }[] = [
  { id: "system", label: "Follow my system", consequence: "Light or dark, whichever this computer is set to." },
  { id: "light", label: "Light", consequence: "Always light, whatever the system says." },
  { id: "dark", label: "Dark", consequence: "Always dark, whatever the system says." },
];

const isTheme = (v: string): v is ThemeId => THEMES.some((t) => t.id === v);
const isMode = (v: string): v is Mode => v === "system" || v === "light" || v === "dark";

export function storedTheme(): ThemeId {
  const v = prefs.get("theme");
  return isTheme(v) ? v : DEFAULT_THEME;
}

export function storedMode(): Mode {
  // Before there were themes, `theme` held "dark" or "light" and meant the mode. A
  // person who set it then still means it now.
  const legacy = prefs.get("theme");
  const v = prefs.get("mode") || (legacy === "light" || legacy === "dark" ? legacy : "");
  return isMode(v) ? v : DEFAULT_MODE;
}

/** What `system` currently resolves to. Dark when nothing can be asked. */
export function systemMode(): "light" | "dark" {
  return globalThis.matchMedia?.("(prefers-color-scheme: light)").matches ? "light" : "dark";
}

/** The mode a subtree has to be told explicitly — a preview cannot inherit "system". */
export function resolveMode(mode: Mode): "light" | "dark" {
  return mode === "system" ? systemMode() : mode;
}

/**
 * Put the choice on the document.
 *
 * `data-mode` is removed rather than set to a value for `system`, because the media
 * query in `tokens.css` is what follows the system, and an attribute that says "dark"
 * would out-specify it at midnight.
 */
export function applyAppearance(theme: ThemeId, mode: Mode): void {
  const root = globalThis.document?.documentElement;
  if (!root) return;
  root.dataset["theme"] = theme;
  if (mode === "system") delete root.dataset["mode"];
  else root.dataset["mode"] = mode;
}

/**
 * Whether this person has been through the theme screen.
 *
 * Per person, not per machine: two people signing in on the same computer are two
 * first-time sign-ins, and the second one should not inherit the first one's answer as
 * though they had given it.
 */
export function hasChosen(subject: string | undefined): boolean {
  return prefs.get(`appearance.chosen.${subject ?? "anonymous"}`) === "yes";
}

export function markChosen(subject: string | undefined): void {
  prefs.set(`appearance.chosen.${subject ?? "anonymous"}`, "yes");
}

/**
 * The appearance, applied and kept.
 *
 * Changing either half applies immediately — no reload, no confirmation, no "are you
 * sure". It is an attribute on the document root and nothing more, and the only motion
 * is the colour transition the browser does for free.
 */
export function useAppearance(): {
  theme: ThemeId;
  mode: Mode;
  /** What `mode` resolves to right now, which is what a preview has to be told. */
  resolved: "light" | "dark";
  setTheme: (t: ThemeId) => void;
  setMode: (m: Mode) => void;
} {
  const [theme, setThemeState] = useState<ThemeId>(storedTheme);
  const [mode, setModeState] = useState<Mode>(storedMode);
  const [resolved, setResolved] = useState<"light" | "dark">(() => resolveMode(storedMode()));

  useEffect(() => {
    applyAppearance(theme, mode);
    setResolved(resolveMode(mode));
  }, [theme, mode]);

  // Someone who is following their system and whose system changes at sunset gets the
  // change here too, and so do the previews.
  useEffect(() => {
    const q = globalThis.matchMedia?.("(prefers-color-scheme: light)");
    if (!q) return;
    const onChange = (): void => setResolved(resolveMode(mode));
    q.addEventListener("change", onChange);
    return () => q.removeEventListener("change", onChange);
  }, [mode]);

  const setTheme = useCallback((t: ThemeId) => {
    setThemeState(t);
    prefs.set("theme", t);
  }, []);

  const setMode = useCallback((m: Mode) => {
    setModeState(m);
    prefs.set("mode", m);
  }, []);

  return { theme, mode, resolved, setTheme, setMode };
}
