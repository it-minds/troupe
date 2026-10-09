defmodule Troupe.CLI.Doctor do
  @moduledoc """
  `troupe doctor`: one line per check, and exit 1 when one fails (TUI Decision 123).

  The checks are the harness's (`Troupe.Doctor`), the same lines `troupe-daemon doctor`
  prints, so a person reads one report whichever program they have. What this adds is
  what only this client knows: the planes it is logged in to, each of which is asked
  for its discovery document. Nothing here needs a daemon; the daemon line says whether
  one is running.

  `--bench` then runs the offline bench's scenarios in this program, against a scripted
  model, and adds a line for each and one for the whole (root Decision 821): whether a
  session here gets through a turn of tool calls, a cut tool output, a compaction, a
  cancel and a replay, with no provider, key or network. `--json` prints the same as one
  object instead.
  """

  alias Troupe.Remote.Credentials

  @doc """
  Print the report for the command line's workspace; returns the exit status.

  `opts`: `:bench`, options for `Troupe.Doctor.bench/1`, which tests use to run fewer
  scenarios or other budgets.
  """
  @spec run(Troupe.CLI.args(), keyword()) :: non_neg_integer()
  def run(args, opts \\ []) do
    planes = Enum.map(Credentials.list(), & &1.plane_url)
    checks = Troupe.Doctor.run(workspace: args.workspace, planes: planes, command: "troupe")
    # The checks are on the screen while the bench runs.
    unless args.json, do: IO.write(Troupe.Doctor.format(checks))

    {lines, bench} =
      if args.bench, do: Troupe.Doctor.bench(Keyword.get(opts, :bench, [])), else: {[], nil}

    if args.json,
      do: IO.write(Troupe.Doctor.json(checks ++ lines, bench)),
      else: IO.write(Troupe.Doctor.format(lines))

    Troupe.Doctor.exit_status(checks ++ lines)
  end
end
