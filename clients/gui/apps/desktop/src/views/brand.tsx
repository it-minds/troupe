// The mark, and the one glyph the whole product borrows from it.
//
// The brand is a mask, split down the middle: the filled half is the work the agent did
// on its own, the hollow half is the part still waiting on a person. That is the same
// sentence the product is about, which is why the mark is drawn from the design file's
// geometry (`mark.ts`, generated) rather than retyped into a `<path>` nobody would
// notice drifting.
//
// Four rules come with it and are enforced here rather than remembered:
//
//   1. The lit half is `--waiting-solid` — the theme's reserved colour. It is the only
//      place outside an approval that colour is allowed, and it means the same thing
//      here as it does there.
//   2. No mouth, ever.
//   3. An eye on a filled half is cut out of it; an eye on a hollow half is solid.
//   4. Light falls from the right. Never mirror it.
//
// People never get a mask — a person is initials in a ring — so nothing in here takes a
// name.

import { useId } from "react";
import type { JSX } from "react";
import { MARK } from "../mark";
import type { Status } from "./bits";

/**
 * The mask.
 *
 * `size` is in pixels and decides two things the design file specifies: the stroke
 * weight, which grows as the mark shrinks so the silhouette survives, and whether the
 * seam is drawn at all — below 32px the colour change is the seam.
 */
export function Mask({ size = 24, label }: { size?: number; label?: string }): JSX.Element {
  const clip = useId();
  const stroke = size >= 40 ? MARK.stroke.lg : size >= 24 ? MARK.stroke.md : MARK.stroke.sm;
  const seam = size >= MARK.seamMinSize;
  // Below 24px the eyes are drawn as bars: two curved slivers three pixels apart stop
  // being two shapes on a rail strip or a tab.
  const flat = size < 24;

  return (
    <svg
      className="mask"
      width={size}
      height={size}
      viewBox={MARK.viewBox}
      {...(label ? { role: "img", "aria-label": label } : { "aria-hidden": true })}
    >
      <defs>
        <clipPath id={clip}>
          <rect x="24" y="0" width="24" height="48" />
        </clipPath>
      </defs>
      <path d={MARK.path} fill="var(--waiting-solid)" clipPath={`url(#${clip})`} />
      <path d={MARK.path} fill="none" stroke="currentColor" strokeWidth={stroke} strokeLinejoin="round" />
      {seam && <path d={MARK.seam} stroke="currentColor" strokeWidth="1.4" />}
      {flat ? (
        <>
          <rect x="16" y="21" width="5.5" height="3.4" rx="1.7" fill="currentColor" />
          <rect x="26.5" y="21" width="5.5" height="3.4" rx="1.7" fill="var(--text-inverse)" />
        </>
      ) : (
        <>
          <path d={MARK.eyeLeft} fill="currentColor" />
          <path d={MARK.eyeRight} fill="var(--text-inverse)" />
        </>
      )}
    </svg>
  );
}

/**
 * The lockup: the mask and the word.
 *
 * The word is set in the interface face at its blackest weight, and lowercase, always:
 * `troupe`, not `Troupe`. The face and the weight are `.wordmark .word`'s, from the
 * design file's `wordmark` role.
 */
export function Wordmark({ size = 20 }: { size?: number }): JSX.Element {
  return (
    <span className="wordmark">
      <Mask size={size} label="Troupe" />
      <span className="word" style={{ fontSize: `${Math.round(size * 0.8)}px` }}>
        troupe
      </span>
    </span>
  );
}

/**
 * The mask's eye, as the status glyph.
 *
 * Status is glyph, then word, then colour — in that order, because the first survives a
 * greyscale screenshot and a person who cannot separate the hues, and the last does
 * not. Each reading is a different *outline*, never the same shape in another colour.
 *
 * Six of these are drawn in the design kits. The other four are decision records and
 * failures rather than live states, and are built from the same eye in the same idiom:
 * a mark added inside the lid, not a new shape.
 */
const EYES: Record<Status, JSX.Element> = {
  // Open, with a pupil: the agent is looking at the work.
  running: (
    <>
      <path d="M1.6 8 Q8 2.4 14.4 8 Q8 13.6 1.6 8 Z" fill="none" stroke="currentColor" strokeWidth="1.5" />
      <circle cx="8" cy="8" r="2.1" fill="currentColor" />
    </>
  ),
  // Lit: the only filled eye in the set, and the reserved colour carries it.
  waiting: (
    <>
      <path d="M1.6 8 Q8 2.4 14.4 8 Q8 13.6 1.6 8 Z" fill="currentColor" />
      <circle cx="8" cy="8" r="2.4" fill="var(--bg-panel)" />
    </>
  ),
  // Dashed: accepted, not started. The outline is provisional.
  queued: <path d="M1.6 8 Q8 2.4 14.4 8 Q8 13.6 1.6 8 Z" fill="none" stroke="currentColor" strokeWidth="1.5" strokeDasharray="2.4 2" />,
  // Closed: asleep is a healthy state, so the lid is a calm single curve, not a cross.
  dormant: <path d="M1.6 8 Q8 13.6 14.4 8" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />,
  // Crossed out: you may look, you may not act.
  readonly: (
    <>
      <path d="M1.6 8 Q8 2.4 14.4 8 Q8 13.6 1.6 8 Z" fill="none" stroke="currentColor" strokeWidth="1.5" />
      <path d="M3 12.4 L13 3.6" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
    </>
  ),
  // Cut: the outline itself is broken. Nothing is being seen from here.
  offline: (
    <path
      d="M1.6 8 Q4.6 5.4 7 4.5 M9.4 4.9 Q12.3 6 14.4 8 Q12.6 9.6 10.6 10.7 M8 11.6 Q4.8 11 1.6 8"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
    />
  ),
  // Allowed: a tick where the pupil goes. You looked, and you said yes.
  allowed: (
    <>
      <path d="M1.6 8 Q8 2.4 14.4 8 Q8 13.6 1.6 8 Z" fill="none" stroke="currentColor" strokeWidth="1.5" />
      <path d="M5.6 8.2 L7.4 10 L10.6 6.2" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
    </>
  ),
  // Denied: a bar, level and deliberate. Denying is you working correctly, so it is not
  // the error glyph and it is not a cross.
  denied: (
    <>
      <path d="M1.6 8 Q8 2.4 14.4 8 Q8 13.6 1.6 8 Z" fill="none" stroke="currentColor" strokeWidth="1.5" />
      <path d="M5 8 L11 8" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
    </>
  ),
  // Failed: the pupil has become a stroke standing up — the one glyph that interrupts
  // the horizontal reading of the row.
  error: (
    <>
      <path d="M1.6 8 Q8 2.4 14.4 8 Q8 13.6 1.6 8 Z" fill="none" stroke="currentColor" strokeWidth="1.5" />
      <path d="M8 5.4 L8 8.4" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" />
      <circle cx="8" cy="10.7" r="0.95" fill="currentColor" />
    </>
  ),
  // Private: the eye is shuttered to a slit. One person can see in; nobody else can.
  private: (
    <>
      <path d="M1.6 8 Q8 2.4 14.4 8 Q8 13.6 1.6 8 Z" fill="none" stroke="currentColor" strokeWidth="1.5" strokeOpacity="0.55" />
      <path d="M4.4 8 Q8 5.2 11.6 8 Q8 10.8 4.4 8 Z" fill="currentColor" />
    </>
  ),
};

/** One 16×16 eye. Decorative on its own: the word beside it is what is read. */
export function Eye({ status }: { status: Status }): JSX.Element {
  return (
    <svg className="eye" width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
      {EYES[status]}
    </svg>
  );
}
