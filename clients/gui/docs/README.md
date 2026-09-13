# troupe-gui documentation

> Audited against troupe-gui commit `783e660` (branch `master`) plus the uncommitted working
> tree, 2026-09-13. The working tree is one large unpushed stage-1 change on top of that
> commit; [AUDIT.md](AUDIT.md) §0 lists what is modified and untracked, so a reader checking
> out `783e660` alone will not find most of what these documents describe.

Four tracks, one audit, one deep dive, the same shape as the server repository's
`../../troupe-remote/docs/README.md`. Server-side concepts (approvals, agents, profiles,
budgets, dormancy) are documented there and linked from here rather than restated.

| Document | One line |
|---|---|
| [developer/](developer/README.md) | The pnpm workspace, the client library and the desktop app module by module, local setup with the fake deployment, tests, the image build, the (untracked) CI workflow, deployment with the Helm chart, conventions. |
| [user/](user/README.md) | Using the GUI in a browser: signing in, the sessions list, a session, approvals and the inbox, files, workflows, troubleshooting. |
| [admin/](admin/README.md) | Operating the GUI: every Helm value, the base-path contract, what the identity provider must allow, what the plane must allow, health, upgrades, troubleshooting from the operator's side. |
| [whitepaper.md](whitepaper.md) | How the client is built and why: the sign-in flows, the poll-based fleet, attachment and cursor, the pure fold, build and delivery, with diagrams and the trade-offs. |
| [AUDIT.md](AUDIT.md) | The Phase 1 inventory: what exists in the working tree, where README, spec and design docs disagree with the code, caveats, open questions. |

Older documents remain the design record: `README.md`, `spec.md`, `DECISIONS.md`,
`REPORT.md`, [design/DESIGN.md](design/DESIGN.md), [bench.md](bench.md) and
[plans/](plans/). Where one of them disagrees with the code, [AUDIT.md](AUDIT.md) §2 says so.

## Self-check

- [developer/README.md](developer/README.md): every job and step in `.github/workflows/ci.yml`
  and every development and build variable, with the section that documents it.
- [admin/README.md](admin/README.md): every Helm value in `charts/troupe-gui/values.yaml`,
  every browser storage key, and every server-side setting the GUI depends on.
- [user/README.md](user/README.md): every screen and every user action, plus the list of what
  the GUI does not do yet.

There is no `.env`, `.env.example` or `VITE_*` variable in this repository; the only build-time
input is `TROUPE_GUI_BASE` and the container takes no environment variables
([AUDIT.md](AUDIT.md) §1.4). The consolidated result of the three checks is recorded at the
end of this file.

### Result (2026-09-13, after the documents were written)

A script checked the finished documents against the working tree:

| Check | Source of truth | Result |
|---|---|---|
| Every variable and storage key: `TROUPE_GUI_BASE`, `BASE_URL`, `ORIGINS`, `RUNS`, the 12 `BENCH_*` and `TRACE_SECONDS`, the 5 `scripts/deploy` inputs, the 4 CI registry secrets and `GUI_BASE`, `troupe.auth.refresh`, `troupe.pref.planeUrl`, `troupe.pref.theme`, `troupe.auth.pending`, `TROUPE_CORS_ORIGINS`; plus every `process.env.*` / `import.meta.env.*` read in source | `grep` over `packages`, `apps`, `scripts` | all present in `developer/` or `admin/` |
| Every job (`check`, `image`, `chart`) and every named, `run:` and `uses:` step of `.github/workflows/ci.yml` | the workflow file | all present in [developer/ci-cd.md](developer/ci-cd.md) |
| Every top-level and nested key of `charts/troupe-gui/values.yaml` | the values file | all present in [admin/configuration.md](admin/configuration.md) |
| Every screen and action label (Sign in, Sessions, Waiting for you, Everything else, Start a session, Allow, Deny, "for this session", Show all of it, Wake and send, Stop, Backstage, Tasks, Files, Sign out, Shift+Enter) and every protocol method the client calls | the views and `packages/client/src` | all present in [user/](user/README.md), [developer/architecture.md](developer/architecture.md) or [whitepaper.md](whitepaper.md) |

Nothing was found missing. The per-track tables in each `README.md` list the exact section
for each item.
