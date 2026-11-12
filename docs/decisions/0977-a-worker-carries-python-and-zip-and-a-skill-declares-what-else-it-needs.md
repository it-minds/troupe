---
number: 977
title: "The worker image carries Python's standard library, zip and unzip as what a skill's script may rely on on a pod; a skill names any other program it needs in its frontmatter's `requires:`, and where it is loaded one missing a program is kept and marked as unable to run here, never hidden"
date: 2026-11-12
status: accepted
issue: 873
paths:
  - docker/Dockerfile
  - apps/troupe_core/lib/troupe/skills.ex
  - apps/troupe_core/lib/troupe/agent/hold.ex
  - apps/troupe_core/lib/troupe/tool.ex
  - apps/troupe_protocol/lib/troupe/protocol/bundle.ex
  - apps/troupe_gateway/lib/troupe/gateway/local_sources.ex
  - protocol/schema/v1/commands/skills.list.json
  - PROTOCOL.md
  - docs/user/configuration/mcp-agents-skills.md
  - docs/admin/profiles-and-policy.md
symbols:
  - Troupe.Skills.check/2
  - Troupe.Skills.runnable?/1
  - Troupe.Protocol.Bundle.skill_requires/1
gist: "Worker image has python3 stdlib + zip/unzip; a skill's requires: is checked on PATH where it loads; one missing a program is listed as unable to run, not hidden"
---

Issue #873. A skill in a bundle can carry a script beside its `SKILL.md`, and on a worker
pod the agent could not run one: `troupe-worker:0.35.0-beta` had `bash`, `git`, `perl`,
`tar` and `gzip`, and no `python3`, `zip` or `unzip`. A pod reaches only the hosts its
profile names, so nothing could be installed from inside a session either. A skill that
builds an office file from a template with Python's standard library built on a laptop and
on a pod produced only the outline. Nothing said so beforehand: the skill was offered on
both, and the agent learned it mid-task.

**What the image carries.** The worker image installs Debian's `python3-minimal` and
`libpython3-stdlib` (Python 3.11's standard library, no `pip`) and `zip` and `unzip`, in
the worker image alone and pinned as its other packages are, by the image's Debian
snapshot. That covers the zip-based office formats (`zipfile`, `xml.etree`), JSON and CSV,
and a small checker. The unpacked filesystem grows by about 30 MiB (the package layer from
132 MB to 164 MB). With `bash`, `perl`, `git`, `tar` and `gzip`, it is the set the user
docs name as what a skill's script may rely on on a pod. They run as the worker user inside
the sandbox `Troupe.Sandbox` builds, under the chart's seccomp profile; the AppArmor profile
allows every file and exec (`file,`) and mediates only mounts, signals and sockets.

Not chosen: `pip` or a fuller Python, which would invite packages a pod cannot fetch;
`node`, which is several times the size and the skill that needs it can say so. A profile
that needs more builds an image `FROM` the release's worker, and the admin docs say what
must not change in it (the entrypoint, uid 1000, the release and its reaper, tools under
`/usr` where the sandbox sees them) and that a profile on a literal image no longer follows
the release.

**What a skill declares.** A `SKILL.md` may carry `requires: [python3, zip, node]`, a list
of program names (`[a-z0-9][a-z0-9+._-]*`, at most 64 characters, as Debian names a
package's programs). `Troupe.Protocol.Bundle.skill_requires/1` reads it, one reader for the
plane and the harness. A publish refuses a `requires:` that is not such a list, since an
admin is there to mend it; a skill on a disk with one is loaded with a warning in the log
and the names that are, as an agent file's fault is a warning and not a failed session.

**What a pod or a laptop does with it.** `Troupe.Skills.found/3`, which a turn's first
call takes and holds to its end, checks each name with `Troupe.Executable.find/2`, the
`PATH`-only lookup, on the bundle's skills and the person's own alike, and gives every
skill `missing`. A skill missing a program is **kept and marked, not hidden**: the system
prompt lists it apart as `cannot run here: needs python3`, the `skill` tool does not offer
it and answers `skill_cannot_run` if asked, the daemon's `skills.list` gives each offered
skill `available` and `missing`, and the turn's `llm_request.turn_hold` writes `missing`
for a skill that lacks something (only then, so a hold of skills that can all run hashes
as it did). Hiding it would make the gap something nobody sees until a task needs it;
marking it lets the agent say so at once and an admin see what to add.

`profile.get`'s `skills` are left as the names the grant leaves: the plane never sees
inside a pod's image, and a profile's image may be its own, so it cannot know what a pod
has. The pod's session is where it is known. The checks are done when a turn begins, so a
program added to a running machine is seen at the next turn, as a skill file is.

No schema changes: `skills.list`'s parameters are as they were and its result has no
schema of its own; `turn_hold` is an open object. Both additions are additive in v1.

**Open question, not settled here.** Several profiles deny `shell` on purpose, and a
skill's script needs it. Whether a bundle's own scripts could run through something
narrower than `shell`, a tool that runs only a file the bundle carries, with the workspace
as its only writable place, is a separate decision the same skill meets next.

**Proof.** `apps/troupe_core/test/troupe/skills_test.exs` ("a skill's requirements"): with
a `PATH` the test lays out, a skill that names a missing program is listed with it, the
prompt says it cannot run here, the tool does not offer it and answers why, a hold round
trips it, and an invalid `requires:` is a warning; it failed on the tip with `key :missing
not found`. `bundle_test.exs` reads and refuses `requires:` at publish; the gateway's
`local_sources_test.exs` lists `available` and `missing`. The worker image built locally
runs `python3 -c "import zipfile, json, csv, xml.etree.ElementTree"`, `zip -v` and
`unzip -v` as uid 1000, and again inside a bubblewrap sandbox built with the worker's flags
under `charts/troupe/files/worker-seccomp.json` with every capability dropped.
