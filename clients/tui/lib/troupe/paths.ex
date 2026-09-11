defmodule Troupe.Paths do
  @moduledoc """
  Platform directories. `TROUPE_STATE_DIR` and `TROUPE_CONFIG_DIR` override the
  platform defaults (Decision 15).
  """

  @spec state_dir() :: String.t()
  def state_dir do
    System.get_env("TROUPE_STATE_DIR") ||
      case :os.type() do
        {:win32, _} ->
          Path.join(System.get_env("LOCALAPPDATA") || Path.expand("~"), "troupe")

        _ ->
          base = System.get_env("XDG_STATE_HOME") || Path.expand("~/.local/state")
          Path.join(base, "troupe")
      end
  end

  @spec config_dir() :: String.t()
  def config_dir do
    System.get_env("TROUPE_CONFIG_DIR") ||
      case :os.type() do
        {:win32, _} ->
          Path.join(System.get_env("APPDATA") || Path.expand("~"), "troupe")

        _ ->
          base = System.get_env("XDG_CONFIG_HOME") || Path.expand("~/.config")
          Path.join(base, "troupe")
      end
  end

  @spec workspace_hash(String.t()) :: String.t()
  def workspace_hash(workspace) do
    :crypto.hash(:sha256, Path.expand(workspace))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  @spec session_dir(String.t(), String.t()) :: String.t()
  def session_dir(workspace, session_id) do
    Path.join([state_dir(), "sessions", workspace_hash(workspace), session_id])
  end

  @spec sessions_root(String.t()) :: String.t()
  def sessions_root(workspace) do
    Path.join([state_dir(), "sessions", workspace_hash(workspace)])
  end

  @spec new_session_id() :: String.t()
  def new_session_id do
    ts = System.system_time(:millisecond) |> Integer.to_string(36)
    rand = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "#{ts}-#{rand}"
  end
end
