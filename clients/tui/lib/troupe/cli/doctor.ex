defmodule Troupe.CLI.Doctor do
  @moduledoc """
  `troupe doctor`: one line per check, and exit 1 when one fails.

  The checks are the harness's (`Troupe.Doctor`), the same lines `troupe-daemon doctor`
  prints, so a person reads one report whichever program they have. What this adds is
  what only this client knows: the planes it is logged in to, each of which is asked
  for its discovery document, and whether this terminal is in Local only, in which case no
  plane is asked. Nothing here needs a daemon; the daemon line says whether one is running.

  Signed in to a plane that recommends a version while a newer release says it supports
  that plane, a line says so and names `troupe update --latest` (`Troupe.Update`). It is
  never a failure: the recommended version is the one the plane's administrators chose,
  and a person on it is where they should be.

  `--bench` then runs the offline bench's scenarios in this program, against a scripted
  model, and adds a line for each and one for the whole (root Decision 821): whether a
  session here gets through a turn of tool calls, a cut tool output, a compaction, a
  cancel and a replay, with no provider, key or network. `--json` prints the same as one
  object instead.
  """

  alias Troupe.CLI.LocalOnly
  alias Troupe.Remote.Credentials

  @doc """
  Print the report for the command line's workspace; returns the exit status.

  `opts`: `:bench`, options for `Troupe.Doctor.bench/1`, which tests use to run fewer
  scenarios or other budgets; `:update`, what finds the line on a newer supported release
  (a check or `nil`).
  """
  @spec run(Troupe.CLI.args(), keyword()) :: non_neg_integer()
  def run(args, opts \\ []) do
    planes = Enum.map(Credentials.list(), & &1.plane_url)
    local_only? = LocalOnly.on?()

    checks =
      Troupe.Doctor.run(
        workspace: args.workspace,
        planes: planes,
        command: "troupe",
        local_only: local_only?
      ) ++
        [local_only_check(local_only?)] ++
        update_checks(local_only?, Keyword.get(opts, :update, &update_check/0))

    # The checks are on the screen while the bench runs.
    unless args.json, do: IO.write(Troupe.Doctor.format(checks))

    {lines, bench} =
      if args.bench, do: Troupe.Doctor.bench(Keyword.get(opts, :bench, [])), else: {[], nil}

    if args.json,
      do: IO.write(Troupe.Doctor.json(checks ++ lines, bench)),
      else: IO.write(Troupe.Doctor.format(lines))

    Troupe.Doctor.exit_status(checks ++ lines)
  end

  defp update_checks(true, _update), do: []
  defp update_checks(false, update), do: List.wrap(update.())

  # The plane signed in to, as `troupe update` asks it, with nothing said on the way.
  defp update_check do
    case Troupe.CLI.Remote.client_versions(say: fn _line -> :ok end) do
      nil ->
        nil

      plane ->
        Troupe.Update.doctor_check(
          plane: plane,
          installed: to_string(Application.spec(:troupe, :vsn))
        )
    end
  end

  # Whether this terminal is in Local only, from the person's own config: a line either way,
  # so the report says what it promises.
  defp local_only_check(true) do
    %{
      name: "local only",
      state: :ok,
      detail:
        "on (local_only in your config): troupe calls no plane, and the daemon calls none for its sessions"
    }
  end

  defp local_only_check(false),
    do: %{
      name: "local only",
      state: :ok,
      detail: "off; local_only: true in your config turns it on"
    }
end
