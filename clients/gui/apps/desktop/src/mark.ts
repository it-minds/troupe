// Generated from docs/design/themes/signal.tokens.json by scripts/tokens.ts. Do not
// edit by hand: run `pnpm tokens`.
//
// The mask. One silhouette, split down the middle: the filled half is what the agent did alone, the hollow half is what still needs a person.
//
// The rules that go with it, from the design file:
//   - Fill the mask with the surface behind it, never a colour outside the token set.
//   - No mouth, ever.
//   - An eye on a filled half is cut out of it; an eye on a hollow half is solid.
//   - People never get a mask. A human is initials in a ring.

export const MARK = {
  viewBox: "0 0 48 48",
  path: "M9 15 Q9 7 24 7 Q39 7 39 15 L39 25 Q39 35 24 43 Q9 35 9 25 Z",
  eyeLeft: "M15.5 21 Q19 18.4 22.5 21 Q19 23.6 15.5 21 Z",
  eyeRight: "M25.5 21 Q29 18.4 32.5 21 Q29 23.6 25.5 21 Z",
  seam: "M24 8 L24 42",
  /** Drop the seam line below 32px and let the colour change be the seam. */
  seamMinSize: 32,
  stroke: { lg: "2.6", md: "3", sm: "3.4" },
  lightDirection: "right",
} as const;
