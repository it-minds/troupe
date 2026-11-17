# The TUI's decisions

The terminal client's own deviations and resolved ambiguities, one file each, numbered on
their own from its first pass. The TUI's existing code cites them as `Decision N` and the
repository's as `root Decision N`, and new code cites neither (Decision 882); elsewhere
they are `TUI Decision N`. They are written
and checked as the repository's are ([decisions/](../README.md)), and
`mix troupe.decisions --for clients/tui/<path>` lists them with the repository's.

One is short, as the repository's are: what was decided, what was not chosen and why, and
what breaks if it is undone, in at most 40 lines that are not blank; no list of tests, no
history of the issue, no restatement of the code. Its `paths` are where it would be undone,
at most eight globs of code, never a test. The line below is
the first number not yet reserved, so a number stays taken after its file is deleted: a
chunk's coordinator moves it past the block reserved for the chunk on the chunk's branch,
and a fixer never edits it:

<!-- next: 190 -->

<!-- decisions:index -->
