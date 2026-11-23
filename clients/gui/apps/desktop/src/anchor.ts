// Keeping the reader's place while something is drawn above it (troupe #1182): a page of a
// session's history goes in at the top of the transcript, and what was on screen before it
// stays where it was, not pushed down by everything the page drew.

/**
 * Note where the first of `container`'s children still on screen is, and give back what puts
 * it there again once more has been drawn above it: the container scrolled by however far
 * that child moved. Children matching `ignore` (the control that asked for the page, which
 * stays first) hold no place. Nothing on screen, or a child gone by then, moves nothing.
 */
export function holdPlace(container: HTMLElement | null, ignore = ".earlier-more"): () => void {
  if (!container) return () => undefined;
  const top = container.getBoundingClientRect().top;
  const first = [...container.children].find((c) => !c.matches(ignore) && c.getBoundingClientRect().bottom > top);
  if (!first) return () => undefined;
  const was = first.getBoundingClientRect().top - top;
  return () => {
    if (!first.isConnected) return;
    const moved = first.getBoundingClientRect().top - container.getBoundingClientRect().top - was;
    if (moved !== 0) container.scrollTop += moved;
  };
}
