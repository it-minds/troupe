# Setting up and checking a machine

What the first run asks, what `troupe config` does on a machine with no settings, how
`troupe doctor` checks the setup, and signing in to a plane. The files it writes, and
every key in them, are on [configuration](configuration.md).

## troupe setup

`troupe setup` sets up a model, one question to a screen: where the work runs, the
provider (a key in the environment, an opencode setup or a working `config.yaml` is
offered first), the key, the models with their context and price, a first project and
what the agent may do there without asking, and whether the daemon starts when you log
in. A summary comes last, and nothing is written before it: Enter writes it and opens
the first session in that project, Esc leaves with nothing written, Shift-Tab goes back
a step. Run it again whenever you like. Without a terminal (standard input or output
redirected) it says which and prints the ways on instead.

The settings are one file, `config.yaml` in `~/.config/troupe/` (`%APPDATA%\troupe\` on
Windows, with every other file of your own; [where your files
are](configuration/files.md)), and `troupe config` shows what is in force. The
[cookbook](configuration/cookbook.md) has a complete file for each provider and more;
the smallest is [Anthropic's](configuration/providers.md#anthropic), the key read from
the environment. Your
organisation may set defaults below it and limits above it; `troupe config --explain`
says which ([configuration](configuration-layers.md#your-organisations-defaults-and-limits)).
`troupe config validate` checks that file after you edit it by hand.

With no settings and no key, plain `troupe` opens `troupe setup`'s screen before the
session. `troupe config`, on a machine with no `config.yaml`, offers in a terminal to copy
an opencode setup's providers (keys as opencode has them written), and otherwise three
choices: set up a provider here, line by line (Anthropic first, then OpenAI or a gateway:
provider, URL, key and a model from what the provider lists; Enter at every question is
Anthropic with `api_key: "{env:ANTHROPIC_API_KEY}"`); take your organisation's settings
from a plane (`troupe login`, then `troupe config pull`); or not now. Without a terminal it
prints the choices and asks nothing. A `config.yaml` through which no model can be asked
gets the report and then the same choices, and the installers end with the same check.
Whatever finds no key says so with one next step, `troupe config`: the report's last line,
a headless run's model error, the first turn in the TUI. A first run finished in the
desktop app is recorded by the daemon, and plain `troupe` asks nothing then.

## In the desktop app

**The desktop app** asks the same questions on its first run, as screens, then opens a
first session with a suggested prompt. It writes the same `config.yaml`, and once it is
done the terminal client does not ask again. **Setup** in the app's rail runs it again at
any time, and a session whose key the provider refuses offers it too. Without either, the
app's **This computer** screen, under **Models**, sets up the same file, or you write it
yourself.

## troupe doctor

`troupe doctor` checks the setup, one line each: the config files load, the default
model's provider has a key, the key is accepted (a real request, the provider's model
list), the model answers (the smallest request a turn makes, one token, through the same
code a session uses, with the sentence a turn would end with when nothing comes), what
the requests tell the provider about Troupe (`identify`), where the key is kept, that the
helper every command runs under starts, whether a daemon is running, `troupe-daemon` and
`troupe` on the `PATH`, every plane you are signed in to, and whether `local_only` is on. A line that says `FAIL` makes it exit 1; `warn` does not. `troupe-daemon
doctor` prints the same lines. `troupe doctor --bench` then says whether a session gets
through the harness on this machine: a turn of thirty tool calls, a tool output too long
to send whole, a compaction, a cancel, a replay of the session's log, thinking made before
the prompt changed, Claude Code's, opencode's, Cursor's and Copilot's files onboarded, and a
remembered command whose file changed since, eleven scenarios run in `troupe`
itself against a scripted model, so in a few seconds and with no provider, key or network,
a line each saying it passed or what did not hold (`--json` prints it as one object).
`troupe bench --live` goes further: four small tasks against your model, under a cap it
prints and asks about first, saying whether they got done and what each cost
([what a task costs](bench.md)).

## Signing in to a plane

`troupe login <plane URL>` signs you in with a code you type in
your browser; you sign in where you always do, and Troupe never has a password of its own.
That sign-in is the machine's: the installer's `troupe config` runs it, the desktop app
opens signed in with it and starts at that plane, and the daemon is linked to you at it
there and then, so a private session and its artifacts are yours from either client. A
sign-in made in the desktop app is `troupe`'s the same way, and signing out in one is
signing out in both.
