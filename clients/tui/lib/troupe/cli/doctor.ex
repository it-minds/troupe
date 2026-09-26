defmodule Troupe.CLI.Doctor do
  @moduledoc """
  `troupe doctor`: one line per check, and exit 1 when one fails (TUI Decision 123).

  The checks are the harness's (`Troupe.Doctor`), the same lines `troupe-daemon doctor`
  prints, so a person reads one report whichever program they have. What this adds is
  what only this client knows: the planes it is logged in to, each of which is asked
  for its discovery document. Nothing here needs a daemon; the daemon line says whether
  one is running.
  """

  alias Troupe.Remote.Credentials

  @doc "Print the report for a workspace; returns the exit status."
  @spec run(Path.t()) :: non_neg_integer()
  def run(workspace) do
    planes = Enum.map(Credentials.list(), & &1.plane_url)
    checks = Troupe.Doctor.run(workspace: workspace, planes: planes, command: "troupe")
    IO.write(Troupe.Doctor.format(checks))
    Troupe.Doctor.exit_status(checks)
  end
end
