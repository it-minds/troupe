# Memory

Memory is what an agent starts from before you say anything: what your organisation wrote
for every agent, what you keep for yourself, and what earlier agents learned about the
repository. Each is read into every session it applies to, at its next turn after a change.

## The levels

Signed in to a Troupe plane, a session reads these, in this order. Where two disagree the
later one wins, so the narrower comes later:

1. **The organisation's**, every session's.
2. **A team's**, that team's sessions and its members' machines.
3. **A worker profile's**, the sessions on that profile's pods, the profiles it extends first.
4. **Your own**, every session you run, on every machine and on the plane's pods.
5. **The repository's**: its instruction files and the project brief
   ([Instruction files and onboarding](instructions.md)), and your own `<config>/AGENTS.md`
   just before them.

The first three are your organisation's word. An administrator writes them in the console
(*Company memory*, or the profile's page), and a session reads them as instructions that
apply as written. Your own comes after them: it is how you like to work, and the
organisation's instructions still come first.

Each document on the plane holds at most 8192 bytes, about two thousand tokens. Each save is
a new version, kept with who saved it; the audit records each save's version, size and hash,
never its text.

## Your own memory

Your own memory is one document on the plane that follows you between machines. Nobody else
reads it: no administrator's page lists it, and a team admin or a platform admin cannot open
it. It is kept under your account, so it stays yours when the identity provider renames you,
and it is deleted, every version, when you are removed.

You change it in three places, each saving over the version you started from, so a save
made elsewhere meanwhile is said rather than overwritten:

- **`troupe memory`** prints it; `troupe memory --edit` opens it in your editor (`VISUAL`,
  then `EDITOR`) and saves what you leave there; `troupe memory --clear` empties it.
- **The desktop app**: a session's *Instructions* pane lists it as *Your memory* and edits it
  in place, through this computer's daemon.
- **The console**, under *Mine*: a change is previewed line by line before it is saved.

A save reaches the sessions running on the machine that saved it, and on the plane's pods,
at their next turn, with a line saying your memory changed; your other machines read it
within five minutes.

## What an agent may write

An agent may add to your own memory and to the repository's, and to nothing else:

- **`remember`** writes a fact about the repository by default, as it always has.
- **`remember` with `level: "me"`** adds one entry to your own memory: a sentence or two,
  folded onto one line, under a heading of the day, below what is there. It never changes or
  removes a word you wrote; only you do. The session's transcript shows the call and what it
  wrote. Ask an agent to remember something about how you work, and it may use it.
- **The organisation's, a team's and a profile's memory are read-only to every agent.**
  `remember` has no level for them, and the plane refuses a write to any of them from a pod.

When your own memory is full, `remember` says so and names `troupe memory --edit`: make room
there and ask again. With no plane signed in on this machine, `remember` to your own memory
is refused with a sentence, and the agent can keep the fact in the repository instead. The
desktop app in *Local only* does not reach the plane, and so does not edit it either.
