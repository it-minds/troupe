<!--
The title states the behaviour that is now true, in plain prose ("A session's listing says
what it has actually spent"), not "fix: ...". CONTRIBUTING.md has the rest.
-->

**What was wrong, or missing.** How to see it, if it is a bug.

**What changed.**

**Verified:** the commands you ran and what they showed.

Fixes #

- [ ] Every commit is signed off (`git commit -s`, the DCO); the `dco` check fails otherwise.
- [ ] The gate for what changed passes (`mix check`, the TUI's `mix check`, or the GUI's
      `pnpm build` and `pnpm test`), and generated files are regenerated.
- [ ] A dependency added or removed: `elixir scripts/licences.exs` has regenerated
      `docs/third-party-licences.md`.
