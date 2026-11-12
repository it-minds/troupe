# Recipes: MCP servers, an agent, a skill

Three files a person keeps beside `config.yaml`, each in the shape other agent tools
use, and each loaded by a test through the reader Troupe uses for it. They go in
`<config>` ([where that is](files.md)); a repository's own go in its `.troupe/` the same
way, and run only once you trust the workspace where they would run something without
asking.

## MCP servers

`<config>/mcp.json`: your servers, on every workspace. The same file Claude Code, Cursor
or VS Code keep, so `/mcp import` copies one in and `/mcp link` reads one in place.

<!-- recipe: mcp -->
```json title="mcp.json"
{
  "mcpServers": {
    "files": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "~/notes"]
    },
    "tracker": {
      "url": "https://mcp.example.com/mcp",
      "headers": {"Authorization": "Bearer {env:TRACKER_TOKEN}"}
    }
  }
}
```

`files` runs on this machine, a program on the `PATH` with its arguments. `tracker` is
spoken to over HTTP, with a token read from the environment each time it starts and never
written back; an unset variable keeps it from starting, and `/mcp` says which. A server
that signs you in rather than taking a key is in
[MCP servers and skills](../mcp.md#a-server-that-wants-you-to-sign-in), with how every
file here is read.

## A custom agent

`<config>/agents/reviewer.md`: an agent of your own, in every workspace. The front
matter says what it is and what it may do; the body is its instruction.

<!-- recipe: agent -->
```markdown title="agents/reviewer.md"
---
description: Reviews a change for correctness and says what to fix, without editing anything.
mode: subagent
# The cheap model is enough to read and judge.
model: cheap
budget_share: 0.3
tools:
  - read_file
  - list_files
  - grep
  - glob
  - git_read
  - finish
permissions:
  write_file: deny
  edit_file: deny
  shell: deny
---
You review one change. Read the diff and the code around it, and say what is wrong:
a bug, a missed case, a test that does not test what it says. Name the file and the
line. Say nothing about style the code around it does not already follow.

Finish with the findings, the most serious first, or with "nothing to fix".
```

A parent agent hands it work with `delegate`, by name. The desktop app's **Agents** and
`agents.put` check a new one as it is saved: a tool that does not exist, or a model your
provider does not serve, is refused with the reason.

## A skill

`<config>/skills/release-notes/SKILL.md`: instructions an agent loads when its task calls
for them. The directory's name is the skill's, in lower-case letters, digits and dashes,
and the description is what an agent reads to decide whether it applies.

<!-- recipe: skill -->
```markdown title="skills/release-notes/SKILL.md"
---
name: release-notes
description: Write release notes from the merged pull requests since the last tag, in the project's own voice.
---
# Release notes

1. Find the last tag: `git describe --tags --abbrev=0`.
2. List what was merged since: `git log <tag>..HEAD --merges --oneline`.
3. Group the changes by what a user notices first: what is new, what changed, what was
   fixed. Leave out changes nobody outside the project sees.
4. Write one line a change, saying what is now true, and link its pull request.
```

`~/.agents/skills/` is read too, the directory other tools share for skills; Troupe never
writes there.

### A skill with a script

A skill may carry a script beside its `SKILL.md`, which the agent runs with `shell` (a
profile that denies `shell` runs none). On your machine a script has whatever your machine
has. On a worker pod it has what the worker image has, and nothing more can be installed
from inside a session, because a pod reaches only the hosts its profile names. What a
skill's script may rely on there:

| Program | For |
|---|---|
| `bash`, `sh` | the script itself |
| `python3`, the standard library only (no `pip`, no packages) | `zipfile`, `json`, `csv`, `xml.etree`, and so the zip-based office files (`.docx`, `.xlsx`, `.pptx`, `.odt`) |
| `zip`, `unzip`, `tar`, `gzip` | archives |
| `perl`, `git` | text, and the repository |

A skill that needs anything else says so in its frontmatter, as a list of program names:

```markdown title="skills/deck/SKILL.md"
---
name: deck
description: Build a slide deck (.pptx) from an outline, with the template beside this file.
requires: [python3, zip]
---
Run `python3 build.py outline.md` and attach the `.pptx` it writes.
```

Each name is looked for on the `PATH` of the machine the skill is loaded on, when a turn
begins. A skill missing one is kept, and marked: the agent's prompt lists it as "cannot
run here: needs node" rather than offering it, so the agent says so instead of finding
out halfway through, and the `skill` tool answers the same if asked for it. The daemon's
`skills.list` gives each of your own skills `available` and `missing`. On a pod, the
profile's page (`profile.get`) lists the skills its grant leaves without this check, since
the plane cannot see what a pod's image holds: the pod's session is where it is known, in
the agent's prompt and in the turn's `llm_request` (`turn_hold`, each skill that lacks a
program with its `missing`). An admin
closes the gap with an image of the profile's own
([profiles-and-policy.md](../../admin/profiles-and-policy.md#a-worker-image-of-the-profiles-own)).

A name is lower-case letters, digits, `+`, `.`, `_` and `-`, as a program's is (`python3`,
`node`, `g++`). A `requires:` that is not a list of such names is refused when a bundle is
published, and on your own machine is a warning in the daemon's log, the skill loaded with
the names that are.
