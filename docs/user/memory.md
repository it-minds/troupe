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
apply as written. Your own comes after them: it is how you like to work. The organisation's
instructions still come first, except on a topic you wrote about yourself (below).

## Entries and topics

Each document is Markdown, and each `## Topic` section of it is one **entry**: the heading
is its topic, the lines under it are what it says. Text before the first heading is the
entry called *General*. Topics are compared by their words, so `## Tone`, `## tone` and
`##  TONE` are one topic.

**On a topic, the closest level wins.** Where two levels both have an entry on a topic, a
session reads only the closer one's, which says in one line what it replaces: your own over
a worker profile's, a profile's over a team's, a team's over your organisation's. So if your
organisation's memory has `## Tone` and so does yours, your sessions follow yours on tone,
and your organisation's tone section is not in their prompt at all. Topics only one level
has are read as they are, the organisation's first. *General* is no topic: it is never
replaced. Two teams of yours on the same topic both stay, on your own machine, which reads
all of your teams'.

`instructions_loaded` says which sections a turn left out and whose replaced them (each
document's `replaced`), and the desktop app's *In effect for you* lists, for one of your
teams, the winner on each topic with what it replaces struck through.

**Forgetting an entry** removes its section and saves the document as a new version: new
sessions stop starting with it, and the sessions already running keep it until they next
sleep and wake, or until their next turn reads the new version. Nothing is soft-deleted:
the old version keeps the text, as every version does, and a rollback brings it back.

**Used in *n* sessions**, beside an entry, counts the sessions whose last turn read a version
of the document that held it since it came in. It is approximate: the plane keeps one row per
session, the version its last turn read (and a week of a machine's), so a session whose turns
all came before the entry, or one silent for a week, is not counted.

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
- **The desktop app**: *Memory* in the rail, through this computer's daemon (below). A
  session's *Instructions* pane lists it as *Your memory* and opens *Memory* for it.
- **The console**, under *Mine*: a change is previewed line by line before it is saved.

A save reaches the sessions running on the machine that saved it, and on the plane's pods,
at their next turn, with a line saying your memory changed; your other machines read it
within five minutes.

**In the desktop app**, *Memory* reads each level as entries, as the plane answers them
(above), each with who last changed it, when, and in how many sessions it was used. *In
effect for you* shows what a new session in one of your teams starts knowing, as the plane
works it out (`memory.in_effect`): on each topic the closest level's entry, with what it
replaces struck through. *Only you* is yours to add to, edit and forget, saved as entries
over the version you read; the other levels are marked *READ* there and are changed in the
console by those who keep them. A team admin's or a platform admin's client may also change
the levels they keep through this computer's daemon, which sends `admin.memory.*` to the
plane as them; the plane refuses anybody else. Its *Versions* drawer
lists every version, sets any two side by side, rolls back to one, shows who wrote each line,
and says whether this computer's copy is current and what each session running here read.
An entry an agent adds while it is open appears in it. Under *Local only* it asks the plane
nothing and says what this computer holds.

## Which version a session ran under

A session's log says, as each turn's instructions are read, which version of each document
the turn ran under (the `instructions_loaded` event's `memory`, each document's level, name,
version and hash), and `memory_changed` says when a later turn read a newer one.

A session on the plane's pods asks the plane, as each turn begins, whether it holds the
versions in force, and reads the new ones first if it does not. A session on your machine
reads the copy your daemon keeps, which it asks the plane for every five minutes. Each of
those asks tells the plane which version each session's last turn ran under, by version and
hash and never the text, so your organisation's administrators can see on *Company memory*
which running sessions are behind a save. Your own memory is not shown there.

`troupe memory --status` prints which versions this machine holds, whether the plane has the
same in force (it asks, and keeps the answer), and which each session running here read at
its last turn: the place to start when a session seems not to follow what was saved.

## What an agent may write

An agent may add to your own memory and to the repository's, and to nothing else:

- **`remember`** writes a fact about the repository by default, as it always has.
- **`remember` with `level: "me"`** adds one entry to your own memory: a sentence or two,
  folded onto one line, as `- <entry>` at the end of the section on the `topic` it names
  (`## Notes` where it names none), making the section where you have none. It never changes
  or removes a word you wrote; only you do. Sections under a date, from agents before topics,
  stay as they were. The session's transcript shows the call and what it
  wrote. Ask an agent to remember something about how you work, and it may use it.
- **The organisation's, a team's and a profile's memory are read-only to every agent.**
  `remember` has no level for them, and the plane refuses a write to any of them from a pod.

When your own memory is full, `remember` says so and names `troupe memory --edit`: make room
there and ask again. With no plane signed in on this machine, `remember` to your own memory
is refused with a sentence, and the agent can keep the fact in the repository instead. So is
it in a session a client in *Local only* runs (the desktop app's switch, or `local_only:
true` for `troupe`): the daemon sends nothing of that session to the plane. The desktop app
in Local only does not edit your memory either.

## Who wrote each line

`troupe memory --blame` prints your own memory a line at a time with who wrote each: the
version it came in and who saved it, or, for an agent's entry, the agent and the session it
came from. In the console, *Who wrote each line* under a document does the same for the
organisation's, a team's and a profile's, beside each line. It is worked out from the
versions and the audit, which keep nothing more for it: blame, not history, and the versions
list is the history.
