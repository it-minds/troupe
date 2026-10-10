defmodule Troupe.Onboard.Source do
  @moduledoc """
  Where `troupe onboard` gets what it proposes: one module per kind of thing another tool
  keeps (its agents and commands, say), reading that tool's files and saying what Troupe's
  own file would hold instead (issue #516, Decision 823).

  A source only proposes. It writes nothing and asks nothing: `Troupe.Onboard` checks each
  proposal against the two roots, shows it as a diff, writes what the person accepts and
  records where it came from. So a source is tested on its proposals alone.

  A proposal is a plain map:

    * `target` - `:repo` for the workspace's `.troupe/`, `:user` for the person's config
      directory
    * `path` - the file to write, relative to that root, with `/` between its parts
      (`agents/reviewer.md`)
    * `content` - the whole file as Troupe should read it, without provenance: the writer
      adds `imported_from`, `imported_hash` and `imported_at`
    * `source` - the other tool's file it was made from: relative to the workspace for
      `:repo`, starting `~/` for `:user`
    * `source_hash` - the lowercase hex sha256 of that file's bytes
    * `notes` - one sentence per key left out or changed, for the person to read
    * `also_from` (optional) - the other files the content was made from, each
      `%{source, source_hash}` named as `source` is: a Claude Code agent's permissions from
      `.claude/settings.json`, an inlined `{file:}`. Each is recorded beside the source,
      and a change to any of them is drift and a new proposal.

  `skipped/2`, optional, names the other tool's files the source found and proposed
  nothing for, each with its reason in a sentence (linked outside the workspace, disabled,
  a name Troupe cannot take); `troupe onboard` lists them.

  `found?/1`, optional, is a cheap look at the workspace's root for the files the source
  reads: a session's start asks it before it asks for proposals, to say what `troupe
  onboard` would bring in (Decision 827), and a source without it is always asked.

  `target` may also be `:workspace` for an `AGENTS.md`, `path` then relative to the
  workspace itself (Decision 827).

  `opts` carries `home`, the directory `~` stands for, and `config_dir`, the person's
  config directory, so a test can give a source scratch ones; and `targets`, when only
  some targets are wanted (a session's start asks for `[:workspace, :repo]`): a source
  reads nothing for a target not in it, the person's own files for `:user` above all. A
  source is registered in `Troupe.Onboard`'s `@sources`, one line.
  """

  @type also :: %{source: String.t(), source_hash: String.t()}

  @type proposal :: %{
          required(:target) => :repo | :user | :workspace,
          required(:path) => String.t(),
          required(:content) => binary(),
          required(:source) => String.t(),
          required(:source_hash) => String.t(),
          required(:notes) => [String.t()],
          optional(:also_from) => [also()]
        }

  @type skipped :: %{source: String.t(), reason: String.t()}

  @callback proposals(workspace :: Path.t(), opts :: keyword()) :: [proposal()]
  @callback skipped(workspace :: Path.t(), opts :: keyword()) :: [skipped()]
  @callback found?(workspace :: Path.t()) :: boolean()

  @optional_callbacks skipped: 2, found?: 1
end
