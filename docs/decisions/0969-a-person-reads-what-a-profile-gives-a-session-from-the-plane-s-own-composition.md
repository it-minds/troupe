---
number: 969
title: "A person reads what a profile gives a session before starting one, from the plane's own composition"
date: 2026-10-29
status: accepted
paths:
  - apps/troupe_plane/lib/troupe/plane/harness.ex
  - apps/troupe_plane/lib/troupe/plane/profile_view.ex
  - apps/troupe_gateway/lib/troupe/gateway/dispatch.ex
  - PROTOCOL.md
  - docs/user/profiles.md
symbols:
  - Troupe.Plane.ProfileView.get/3
  - Troupe.Plane.ProfileView.offering/2
gist: "profile.get is the plane's composition of what activation hands a pod, for the caller; it shows what is not here and why, and names no secret"
---

A person choosing where to start a session saw a profile's name, its room and the names
`profiles.list` gives: the primaries, the skills and the MCP servers. Not which agents the
profile's rule took away (Decision 968), whose access each server calls with, what the
per-tool rules refuse (Decision 913), which model, which hosts the pods may reach, which
budgets apply, nor which team the session would be charged to. They found out by starting
one, and an administrator answered the rest by hand.

## Decision

The plane answers `profile.get {name, team?}` (`observe`) for the caller, and the daemon
forwards it as its person: what a session of theirs on that profile would be given.

**The plane composes it, from what it enforces.** `Troupe.Plane.ProfileView` reads the
same pieces the harness hands a pod at `session.activate`: the profile row in effect, its
chain resolved; the channel's current bundle; the profile's agents rule; the team's
entitlement rows; `Extends.rules/1`, the rules sent in every activation; the hosts
`WorkerProfile.egress_destinations/1` gives the operator, filtered as the operator filters
them; and the three ceilings a session's slice is trimmed against. The offering helpers
moved there from the harness, which now calls them, so the listing, the create's refusal,
the activation and this view are one composition.

**The team is picked as `session.create` picks it.** One team of the caller's that may use
the profile is the team; several and none named is `null` with the union `profiles.list`
shows, since a create would ask; a team named narrows it to that team's grant. A platform
admin in no team that may use it sees the profile's own view, unnarrowed; anybody else is
`not_found`, as a session they cannot see is.

**What is not here is shown, with why.** `agents_not_here` lists every agent of the
bundle's or Troupe's that the caller will not get, `why` `profile` (its agents rule) or
`grant` (the team's entitlements); an MCP server the grant withholds is listed with
`offered: false`. A person who does not find the agent they expected is told whose word
took it away, rather than left to guess whether it ever existed. Troupe's own primaries
that no pod session starts as (the plane's set names `build` and `plan` and the bundle's)
are in neither list: nothing took them away, and a pod session never has them.

**Only what the plane knows.** Fields it cannot fill are `null`: a model on a profile with
no `llm.endpoint` (the pods use their image's settings), `terms` (a profile carries none).
The organisation's enforced rules are not listed, because a pod reads no organisation layer
and they hold people's own machines; a repository's or a person's own rules are not the
plane's to know. An identity at a server is its server and its token host; never its client
id or certificate thumbprint.

**The console reads it too.** The administrative console's profile page shows "What a
member sees" by calling `profile.get` as its administrator. This extends Decision 886 on
that one point: the console calls `admin.*` and `me`, the `artifact.*` methods, and now
`profile.get`. It is the same method a person's client calls, because an administrator
checking what a member gets should see the composition the member sees, not a second one
built for the console.

## Not chosen

- **The clients composing it from the bundle.** Every client would have to apply the
  agents rule, the grant, the chain's rules and the operator's egress the way the plane
  does, and three clients doing that is three ways for the view to say something the pod
  does not do. The bundle says what is offered, not what is enforced.
- **Naming identities' client ids.** A client id, a thumbprint or a transit key name is
  what an administrator needs, not what a person deciding where to work needs, and each is
  one more thing about the profile's identity at a server that leaves the console. The
  server and its token host say what a person can act on.
- **Listing only what works.** A view of what a session gets, with what it does not get
  left out, answers "is it here" and never "why not"; the person then asks an
  administrator, who reads the grant and the rule to tell them. Showing it with the reason
  is the same composition and saves that trip.

## Proof

`apps/troupe_plane/test/troupe/plane/profile_view_test.exs`: a member sees the offered
agents and the excluded ones with why, each MCP server's access by credential mode and one
the grant withholds, the profile's rules, the model, the reach composed and sorted, the
limits and three budgets, and the team picked as a create picks it; a non-member is
`not_found`; a platform admin sees the profile's own view. The primaries agree with
`profiles.list`. `apps/troupe_gateway/test/troupe/gateway/profile_get_test.exs`: the daemon
forwards it as its person with only its arguments, keeps the plane's refusal, says signed
out in a sentence and refuses it to a client in Local only.
