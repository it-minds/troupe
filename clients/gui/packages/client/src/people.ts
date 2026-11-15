// People by name (troupe #931). An event's actor and a row's owner name a person by
// subject, which is often an opaque id or an email, and carry their name beside it where
// the server knew one. A client shows the name and the initials drawn from it, and falls
// back to the subject only where there is no name, as a server from before sends none.

/** The name worth showing: a non-empty one that is not only the subject again; undefined otherwise. */
export function named(name: unknown, subject?: string | null): string | undefined {
  if (typeof name !== "string") return undefined;
  const trimmed = name.trim();
  return trimmed !== "" && trimmed !== subject ? trimmed : undefined;
}

/** A person as a client writes them: their name, else their subject, else `fallback`. */
export function nameOrSubject(subject: string | null | undefined, name?: unknown, fallback = "somebody"): string {
  return named(name, subject) ?? (subject || fallback);
}

/**
 * Two letters for a person's ring: the first letters of the name's first two words, or
 * the first two of a name of one word. A subject stands in where there is no name, by its
 * local part, so `bob@example.com` is BO and `idp|7f3a` is 7F rather than ID.
 */
export function initials(name: string): string {
  const local = name.replace(/@.*$/, "").replace(/^.*[|:]/, "");
  const words = local.split(/[.\s_-]+/).filter(Boolean);
  const letters = words.length >= 2 ? (words[0]?.[0] ?? "") + (words[1]?.[0] ?? "") : (words[0] ?? local).slice(0, 2);
  return (letters || name.slice(0, 2)).toUpperCase();
}
