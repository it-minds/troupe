// How long an artifact is kept, in the words both apps use (#981). An administrator may set
// two periods: old versions are removed some days after they were published, and an
// artifact nobody opens is removed some days after it was last opened, published or
// changed. The plane says on each row when it goes (`goes_at`); this only words it. With
// neither period set there is no `goes_at`, and every one of these answers null: nothing
// new is shown.

import type { Artifact, ArtifactDetail, ArtifactVersion } from "./artifacts.js";

function days(n: number): string {
  return n === 1 ? "1 day" : `${n} days`;
}

/** A day as a person reads it, in UTC as the plane counts: "3 Dec", with the year when it is not this one. */
export function goesDate(iso: string, now: Date = new Date()): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  const sameYear = d.getUTCFullYear() === now.getUTCFullYear();
  return d.toLocaleDateString("en-GB", { day: "numeric", month: "short", ...(sameYear ? {} : { year: "numeric" }), timeZone: "UTC" });
}

/** A card's line: when it goes unless somebody opens it, or null while no period says it will. */
export function goesLine(a: Pick<Artifact, "goes_at">, now: Date = new Date()): string | null {
  return a.goes_at ? `Goes ${goesDate(a.goes_at, now)} unless opened` : null;
}

/** The artifact's page: when it goes, and that opening it keeps it. Null while no period says it will. */
export function goesSentence(a: Pick<ArtifactDetail, "goes_at" | "retention">, now: Date = new Date()): string | null {
  if (!a.goes_at) return null;
  const n = a.retention?.unopened_days;
  const period = n ? ` Artifacts nobody opens for ${days(n)} are removed, and opening it starts the ${days(n)} again.` : " Opening it keeps it longer.";
  return `It goes on ${goesDate(a.goes_at, now)}, every version with it, unless somebody opens it.${period}`;
}

/** The versions list: which go, and when. Null while old versions are kept. */
export function versionsSentence(a: Pick<ArtifactDetail, "retention" | "versions">): string | null {
  const n = a.retention?.versions_days;
  if (!n) return null;
  const going = a.versions.filter((v) => v.goes_at).length;
  const which = going === 0 ? "None of these is old enough to go yet." : going === 1 ? "One of these goes on the day it shows." : `${going} of these go on the days they show.`;
  return `Versions older than the newest are removed ${days(n)} after they were published; the newest, and a pinned one, are kept. ${which}`;
}

/** A version's own note: when it goes, or null for one that is kept. */
export function versionGoes(v: Pick<ArtifactVersion, "goes_at">, now: Date = new Date()): string | null {
  return v.goes_at ? `goes ${goesDate(v.goes_at, now)}` : null;
}
