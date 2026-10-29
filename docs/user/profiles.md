# What a profile gives a session

A session on your team's pods runs on a **worker profile**: a kind of machine your
platform administrator set up, with a model, a set of agents and tools, the hosts it may
reach and the limits it runs under. Before you start a session you can read what a profile
you may use will give it. What you read is what the plane enforces and what it hands the
pod when the session starts, composed by the plane itself rather than read off the
profile's bundle, so it is never a promise the session then fails to keep. Inside a running
session, `/settings` shows the same things as that session has them.

You read it in three places, each asking the plane the same question (`profile.get`):

- the terminal's `/profiles`, and `troupe profiles` on the command line;
- the desktop app's **Profiles** view.

Only profiles you may use are shown: one granted to a team you are in. Any other is not
found, as if it did not exist.

## The team

A session belongs to one team, which pays for it and whose grant decides what it may use.
When one team of yours may use the profile, that is the session's team. When several may,
the view lists them all and names none until you choose one, as starting a session would
ask you to; until then what it shows is what any of them would give you.

## Agents

The agents a session may start as (the primaries) and the ones those may hand work to (the
subagents), each with where it comes from: the profile's bundle, or Troupe itself.

Beside them, the agents that exist and that your session will **not** have, each with why:

- **profile**: the profile says that agent does not exist on its pods, for anybody;
- **grant**: your team's grant on the profile leaves it out.

Shown so that an agent you expected and do not find is explained, rather than left for you
to guess whether it was ever there.

A third list, **What the harness may run here**, is the function agents: the ones Troupe
starts by itself for one job, each with its line, such as `answer` for an `AI?` comment or
the librarian that writes the project brief ([agents](agents.md#agents)). No session
starts as one, and no team's grant takes one away; one the profile's rule takes away is in
the not-here list with **profile** as the reason, and its job is not done there.

Agents and skills a repository brings with it are not listed: they arrive with the clone,
and the profile decides whether they may replace its own ([agents](agents.md)).

## Skills

The bundle's skills your team's grant leaves the session, by name.

## Tools

**Per-tool rules.** The rules the profile puts on every session on its pods, and those of
every profile it builds on, each as a tool, a pattern where it has one, and what it does:
`deny` refuses the call, `ask` asks you every time, `allow` runs it without asking. They
are an enforced layer: nothing in a repository or in your own files loosens them
([permission rules](configuration/permissions.md)). Your organisation's enforced rules hold
your own machine, not a pod, and your repository's and your own rules are yours, so none of
those is listed here.

**MCP servers.** Each server the bundle gives the profile, its host, and whose access a call
goes out with:

- **yours**: you connect it yourself, and the server sees you ([MCP](mcp.md));
- **profile**: a credential your administrator gave the profile;
- **system**: the profile's own identity at the server.

Each says whether its tools run without asking (`auto`) or ask (`ask`), and which of its
tools the session has (`all`, or a list). A server your team's grant leaves out is listed
too, marked not offered, with the grant as the reason.

## Model

The model and the smaller model the profile's pods use, the provider, the host requests go
to, and whose key they go out with (the profile's). Where the profile names no model
endpoint, the pods use the model settings their image has, which the plane does not know,
and the view says nothing rather than guess.

## Reach

The hosts outside the cluster the profile's pods may reach: the names your administrator
allowed, the git hosts, the model's endpoint, each MCP server's host and the host each of
the profile's identities gets its tokens from. Sorted, each once. A host not on the list is
one the session cannot reach, whatever an agent tries.

## Limits

- **Sessions per pod**, and the most sessions the profile runs at once, where it has a
  ceiling.
- **Room now**: how many sessions its pods can take and how many are running.
- **Budgets**: the profile's, your team's and your own, each a ceiling a session's
  spending counts against; none shown is none set. A session asked to spend more than the
  tightest of them has left starts on what is left.

A profile carries no terms of its own: the limits a session runs under beyond these (turns,
time, approvals) are the ones it is started with.
