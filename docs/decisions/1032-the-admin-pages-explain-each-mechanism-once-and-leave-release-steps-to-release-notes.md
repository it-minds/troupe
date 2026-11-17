---
number: 1032
title: The admin pages explain each mechanism once, a moved section leaves no stub behind, and a step only one release needs is in that release's notes
date: 2026-11-17
status: accepted
issue: 1014
supersedes: [940]
paths:
  - docs/admin/
gist: One page per mechanism, others link; no heading kept only to link elsewhere; release-specific upgrade steps go in release notes, not task pages
---

**The decision.** On the pages under `docs/admin/`:

- **Each mechanism is explained on one page**, the one an administrator would look for it
  on, and every other page links there in a sentence. Upgrading is `upgrading.md`; the
  plane's OpenBao grants are the generated `openbao.md`, and `roles-and-permissions.md`
  keeps only the workers' and people's policies, which the plane cannot check; the
  sandbox on the nodes (user namespaces, seccomp, AppArmor, what each allows) is
  `worker-sandbox.md`, and `security.md` keeps the reviewer's list and links to it.
- **No stub section.** A heading followed only by a link to another page is not kept; the
  link goes into the parent's prose, and the links to it are moved to the page that has
  the content. This replaces, for these pages, Decision 940's remedy of leaving a stub
  under each moved heading. The 400-line rule and the split along headings stay as 940
  has them. Where a link outside these pages cannot be moved in the same change, an
  `<a id>` keeps its anchor until it is.
- **A step one release needs is in that release's notes**, under *Before you upgrade a
  plane*, and nowhere in a task page: a task page says what to do today. A line that
  only says when something changed is deleted; one that tells today's reader what to do
  keeps its sentence without the version. This takes the pre-upgrade check Decision 906
  put in `routine-tasks.md` out of it; it is in the 0.20.0 release notes.

**Not chosen.** Keeping the stubs: they carried 940's anchors, but they doubled the
reading of every split page, and a reader landing on one is sent elsewhere anyway.
Keeping the version runbooks on the task page: each was right for one upgrade and then
read by everyone after it.

**What breaks if this is undone.** The same mechanism drifts on two pages until they
disagree (the SCIM page once said `/ResourceTypes` was not served while the integrations
page listed it), and the task pages fill again with history.
