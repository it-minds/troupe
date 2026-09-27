// Choosing a theme: once on first sign-in, and afterwards whenever you like.
//
// One screen, four cards, a light/dark control, and a sentence saying it can be
// changed later. Four rules from docs/design/themes/THEMES.md are what make it a
// ten-second screen rather than a puzzle, and each one is visible in the markup:
//
//   1. The default is preselected. Someone who presses Continue without reading gets
//      Afterglow and loses nothing. Skipping is allowed and means the same thing.
//   2. The previews are real. Each card shows the session row that needs you, an
//      approval and the cast — the three things a person looks at all day. Swatches
//      tell you nothing about whether you can work in a theme.
//   3. Light and dark is a separate control, not eight cards. Theme and mode are
//      different questions, and the mode control defaults to "follow my system".
//   4. The copy says it is changeable, which removes all the weight from the decision.
//
// Both screens here are the same two controls. The onboarding one adds a heading and a
// way out; the settings one applies as you click and has no buttons at all, because
// there is nothing to confirm.

import type { JSX } from "react";
import { useNotificationSetting } from "../notify";
import type { Permission } from "../notify";
import { DEFAULT_MODE, DEFAULT_THEME, MODES, THEMES } from "../theme";
import type { Mode, ThemeId } from "../theme";
import { Mask } from "./brand";
import { Pill } from "./bits";
import { useOpensOnLauncher } from "./Launcher";

export interface Appearance {
  theme: ThemeId;
  mode: Mode;
  resolved: "light" | "dark";
  setTheme: (t: ThemeId) => void;
  setMode: (m: Mode) => void;
}

/**
 * A theme, shown as the product rather than as a palette.
 *
 * The subtree carries its own `data-theme` *and* `data-mode`: a preview cannot inherit
 * "follow the system", so it is told in so many words what the rest of the screen
 * currently resolves to. Nothing inside is focusable — the card is the control.
 */
function Preview({ id, mode }: { id: ThemeId; mode: "light" | "dark" }): JSX.Element {
  return (
    <div className="preview" data-theme={id} data-mode={mode} aria-hidden="true">
      <ul className="rows">
        <li className="row is-waiting">
          <span className="subject">Rewrite the billing importer</span>
          <Pill status="waiting" />
        </li>
        <li className="row is-running">
          <span className="subject">Nightly dependency sweep</span>
          <Pill status="running" />
        </li>
      </ul>

      <div className="approval">
        <span className="question">Delete 14 rows from `invoices`?</span>
        <span className="answers">
          <span className="allow">Allow once</span>
          <span className="deny">Deny</span>
        </span>
      </div>

      <div className="cast">
        <Mask size={20} />
        <span className="ring" style={{ color: "var(--p2)" }}>
          JB
        </span>
        <span className="ring" style={{ color: "var(--p1)" }}>
          MS
        </span>
        <span className="micro">2 agents · 3 people</span>
      </div>
    </div>
  );
}

/** The three, as cards. Pressed is the one in use; there is no "apply". */
export function ThemeCards({ theme, resolved, setTheme }: Pick<Appearance, "theme" | "resolved" | "setTheme">): JSX.Element {
  return (
    <div className="themes">
      {THEMES.map((t) => (
        <button
          key={t.id}
          type="button"
          className="theme"
          aria-pressed={theme === t.id}
          onClick={() => setTheme(t.id)}
          title={`${t.name}: the colour reserved for "waiting for you" is ${t.reserved}`}
        >
          <Preview id={t.id} mode={resolved} />
          <span className="label">
            {t.name}
            {t.id === THEMES[0]!.id && <span className="micro"> · default</span>}
          </span>
          <span className="consequence">{t.blurb}</span>
        </button>
      ))}
    </div>
  );
}

/** Light or dark, or neither — which is the answer most people should keep. */
export function ModeChoice({ mode, setMode }: Pick<Appearance, "mode" | "setMode">): JSX.Element {
  return (
    <div className="options">
      {MODES.map((m) => (
        <button key={m.id} type="button" className="option" aria-pressed={mode === m.id} onClick={() => setMode(m.id)}>
          <span className="label">{m.label}</span>
          <span className="consequence">{m.consequence}</span>
        </button>
      ))}
    </div>
  );
}

/**
 * First sign-in.
 *
 * Skippable and pre-answered: a first-run screen that blocks on an aesthetic choice
 * teaches people that this product will waste their time. Whatever is selected has
 * already been applied — Continue only closes the screen — and Skip puts the default
 * back, for the person who pressed three cards to look at them and meant none of it.
 */
export function Onboarding({ name, appearance, onDone }: { name: string | null; appearance: Appearance; onDone: () => void }): JSX.Element {
  return (
    <main className="onboarding">
      <header>
        <h1>{name ? `Welcome, ${name}.` : "Welcome."}</h1>
        <p>
          Pick how Troupe looks. Every theme says the same things in the same places — one colour is reserved, in each of them, for work that
          has stopped and needs you. You can change this any time in Settings.
        </p>
      </header>

      <Chooser {...appearance} />

      <footer>
        <button className="continue" onClick={onDone}>
          Continue
        </button>
        {/* Says what it does rather than only that it leaves: pressing it undoes
            anything pressed above, which is a surprise unless it is written down. */}
        <button
          className="link"
          onClick={() => {
            appearance.setTheme(DEFAULT_THEME);
            appearance.setMode(DEFAULT_MODE);
            onDone();
          }}
        >
          Skip — {THEMES[0]!.name}, following my system
        </button>
      </footer>
    </main>
  );
}

/**
 * The settings screen. Changing a theme applies immediately, with no reload and no
 * confirmation: it is an attribute on the document root and nothing more.
 */
export function AppearanceSettings(props: Appearance): JSX.Element {
  return (
    <>
      <header className="screen-head">
        <span className="count">Settings</span>
        <h1>Appearance</h1>
      </header>
      <div className="listing">
        <div className="appearance">
          <p>Yours alone. Other people in your sessions see them in their own theme, and nothing about a theme changes what anything means.</p>
          <Chooser {...props} />
          <Notifications />
          <Start />
        </div>
      </div>
    </>
  );
}

const PERMISSION_WORDS: Record<Permission, string | null> = {
  granted: null,
  default: "Troupe has not been allowed to show notifications yet. Choosing On asks.",
  denied: "Notifications are turned off for Troupe in this computer's or this browser's settings, and Troupe will not ask again. Turn them on there to have them here.",
  unsupported: "This browser cannot show notifications. The marker in the list and the line when you come back still say what happened.",
};

/**
 * Whether a session that finishes or asks while you are not looking says so with a
 * notification. Beside the appearance because it is the same kind of thing: yours, kept
 * on this computer, changing nothing about what anybody else sees.
 */
function Notifications(): JSX.Element {
  const { on, permission, setOn } = useNotificationSetting();
  const note = on ? PERMISSION_WORDS[permission] : null;
  return (
    <section className="notify">
      <h2 className="screen">Notifications</h2>
      <div className="options">
        <button type="button" className="option" aria-pressed={on} onClick={() => setOn(true)}>
          <span className="label">On</span>
          <span className="consequence">A notification when a session finishes a turn or asks you something while you are not looking at it.</span>
        </button>
        <button type="button" className="option" aria-pressed={!on} onClick={() => setOn(false)}>
          <span className="label">Off</span>
          <span className="consequence">Only the marker in the list, and the line at the top of a session when you come back to it.</span>
        </button>
      </div>
      {note && <p className="note">{note}</p>}
    </section>
  );
}

/**
 * What the app opens on: the launcher, or the list. The launcher's own checkbox sets the
 * same thing; this is where it is turned back, since a person who skipped the launcher
 * no longer starts on it.
 */
function Start(): JSX.Element {
  const { on, setOn } = useOpensOnLauncher();
  return (
    <section className="opening">
      <h2 className="screen">When Troupe starts</h2>
      <div className="options">
        <button type="button" className="option" aria-pressed={on} onClick={() => setOn(true)}>
          <span className="label">Home</span>
          <span className="consequence">Start something, go back to what was open last, or see what is waiting for you, from one screen. The troupe mark in the rail opens it any time.</span>
        </button>
        <button type="button" className="option" aria-pressed={!on} onClick={() => setOn(false)}>
          <span className="label">Sessions</span>
          <span className="consequence">Straight to the list of every session. Home is still one press away, on the troupe mark.</span>
        </button>
      </div>
    </section>
  );
}

function Chooser(props: Appearance): JSX.Element {
  return (
    <div className="chooser">
      <section>
        <h2 className="screen">Theme</h2>
        <ThemeCards theme={props.theme} resolved={props.resolved} setTheme={props.setTheme} />
      </section>
      <section className="mode">
        <h2 className="screen">Light or dark</h2>
        <ModeChoice mode={props.mode} setMode={props.setMode} />
      </section>
    </div>
  );
}
