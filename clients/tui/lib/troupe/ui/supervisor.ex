defmodule Troupe.UI.Supervisor do
  @moduledoc """
  Holds the UI processes. `Troupe.UI.Windows` starts empty; the CLI runner
  adds the TUI or the headless printer to it. Nothing here runs under
  `mix test` (`config :troupe, ui: :none`).
  """

  use Supervisor

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    children =
      [{DynamicSupervisor, name: Troupe.UI.Windows, strategy: :one_for_one}] ++
        if cli?(), do: [Troupe.CLI.Runner], else: []

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp cli? do
    Application.get_env(:troupe, :ui, :auto) != :none and
      (System.get_env("__BURRITO") != nil or System.get_env("TROUPE_CLI") == "1")
  end
end
