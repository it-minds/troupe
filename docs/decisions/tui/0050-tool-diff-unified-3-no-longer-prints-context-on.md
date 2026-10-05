---
number: 50
title: "`Tool.Diff.unified/3` no longer prints context on the far side of the file"
date: 2026-09-11
status: accepted
paths:
  - clients/tui
gist: "`Tool.Diff.unified/3` no longer prints context on the far side of the file"
---

An unchanged run at the top of the file has nothing before the change worth showing and one at the bottom nothing after it, so an edit near the top used to be followed by `@@ 363 unchanged lines @@` and the file's last three lines — five to seven rows of noise that pushed the change itself off a short screen. Runs of six lines or fewer are still printed whole.
