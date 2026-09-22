# Notes for coding agents

This file is read by agent harnesses that follow the `AGENTS.md` convention. What a
person needs is in [README.md](README.md) and [docs/developer/](docs/developer/README.md);
this adds only what an agent working in the repository must not miss.

- **Fixing GitHub issues.** Follow [docs/developer/fixing-issues.md](docs/developer/fixing-issues.md):
  one issue at a time, each reproduced, fixed, installed with `scripts/install-local.ps1`,
  checked with `scripts/verify-local.ps1`, and put up as a pull request. It has a
  coordinator role (triage and the queue) and a fixer role (one issue).
- **Defects found in passing** go in [docs/developer/defects.md](docs/developer/defects.md)
  (where, what, severity, who found it). Read it before touching code it names.
- **No attribution** in commits or pull requests: no `Co-Authored-By:` trailer, no
  "Generated with ..." line.
- **PowerShell scripts are ASCII only**; Windows PowerShell 5.1 misreads UTF-8 without a BOM.
- The gate is `mix check` ([conventions.md](docs/developer/conventions.md)); the CI job
  on a machine is `scripts/ci`.
