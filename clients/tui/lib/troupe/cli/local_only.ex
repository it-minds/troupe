defmodule Troupe.CLI.LocalOnly do
  @moduledoc """
  *Local only* in the terminal: `local_only: true` in the person's own config, which only
  their user file may set, so a repository cannot turn it off for them.

  On, this program makes no call to a plane of its own (signing in, `whoami`, `config pull`,
  HQ, the update's question about the plane's policy), and every connection it makes to the
  daemon says so in `initialize`'s `client_info.local_only`, so the daemon makes none for the
  sessions it runs. `troupe doctor` says whether it is on and asks no plane.

  Read once, as the command starts (`load/1`), and held for the run.
  """

  @key {:troupe, :local_only}

  @doc "Read the setting for `workspace`'s config and hold it for the run; answers it."
  @spec load(Path.t()) :: boolean()
  def load(workspace) do
    on? =
      case Troupe.Config.resolve(workspace) do
        {:ok, config, _layers} -> config.local_only == true
        # A file this VM refuses is the daemon's to say; nothing is promised by it.
        {:error, _error} -> false
      end

    Application.put_env(elem(@key, 0), elem(@key, 1), on?)
    on?
  end

  @doc "Whether this run is in Local only, as `load/1` read it."
  @spec on?() :: boolean()
  def on?, do: Application.get_env(elem(@key, 0), elem(@key, 1), false) == true

  @doc "What a command that would call a plane says instead, while Local only is on."
  @spec refusal(String.t()) :: String.t()
  def refusal(what) do
    "troupe: #{what} calls a plane, and Local only is on (local_only in your config); " <>
      "set local_only: false in your user config to use it"
  end
end
