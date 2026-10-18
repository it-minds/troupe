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
