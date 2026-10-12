// The mask and the word, drawn from the design file's geometry (`mark.ts`, generated), by
// the design's rules: the lit half is the reserved colour, an eye on it is cut out, light
// falls from the right, and there is no mouth.

import { useId } from "react";
import type { JSX } from "react";
import { MARK } from "../mark";

export function Mask({ size = 24 }: { size?: number }): JSX.Element {
  const clip = useId();
  const stroke = size >= 40 ? MARK.stroke.lg : size >= 24 ? MARK.stroke.md : MARK.stroke.sm;
  return (
    <svg className="mask" width={size} height={size} viewBox={MARK.viewBox} aria-hidden="true">
      <defs>
        <clipPath id={clip}>
          <rect x="24" y="0" width="24" height="48" />
        </clipPath>
      </defs>
      <path d={MARK.path} fill="var(--waiting-solid)" clipPath={`url(#${clip})`} />
      <path d={MARK.path} fill="none" stroke="currentColor" strokeWidth={stroke} strokeLinejoin="round" />
      {size >= MARK.seamMinSize && <path d={MARK.seam} stroke="currentColor" strokeWidth="1.4" />}
      <path d={MARK.eyeLeft} fill="currentColor" />
      <path d={MARK.eyeRight} fill="var(--text-inverse)" />
    </svg>
  );
}

/** The lockup, and under it what this is: the console, not the app. */
export function Wordmark({ size = 26 }: { size?: number }): JSX.Element {
  return (
    <span className="wordmark">
      <Mask size={size} />
      <span className="words">
        <span className="word">troupe</span>
        <span className="sub">console</span>
      </span>
    </span>
  );
}
