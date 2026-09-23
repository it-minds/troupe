defmodule Troupe.Paths do
  @moduledoc """
  Platform locations for configuration and state.

  Config lives in `$XDG_CONFIG_HOME/troupe` (Linux, macOS) or `%APPDATA%\\troupe`
  (Windows); state — session logs — in `$XDG_STATE_HOME/troupe` or
  `%LOCALAPPDATA%\\troupe`. Nothing Troupe writes ever lands in the user's repository,
  which is why every caller goes through here instead of joining paths itself.
  """

  @app "troupe"

  @doc "Directory holding `config.yaml` and the global `agents/` definitions."
  @spec config_dir() :: Path.t()
  def config_dir do
    case override("TROUPE_CONFIG_HOME") do
      nil -> Path.join(default_config_home(), @app)
      dir -> dir
    end
  end

  @doc """
  Directory holding `sessions/`.

  An explicit override wins over the environment, which wins over the platform
  default. The explicit form exists so an embedding caller — or a test — can isolate
  its state without setting a process-global environment variable.
  """
  @spec state_dir(Path.t() | nil) :: Path.t()
  def state_dir(explicit \\ nil)
  def state_dir(explicit) when is_binary(explicit) and explicit != "", do: explicit

  def state_dir(_) do
    case override("TROUPE_STATE_HOME") do
      nil -> Path.join(default_state_home(), @app)
      dir -> dir
    end
  end

  @doc """
  Where one session's event log lives:
  `<state>/sessions/<workspace-hash>/<session-id>/`.
  """
  @spec session_dir(Path.t(), String.t(), Path.t() | nil) :: Path.t()
  def session_dir(workspace_root, session_id, state_dir \\ nil) do
    Path.join([state_dir(state_dir), "sessions", workspace_hash(workspace_root), session_id])
  end

  @doc "Directory holding every session recorded for one workspace."
  @spec workspace_sessions_dir(Path.t(), Path.t() | nil) :: Path.t()
  def workspace_sessions_dir(workspace_root, state_dir \\ nil) do
    Path.join([state_dir(state_dir), "sessions", workspace_hash(workspace_root)])
  end

  @doc """
  A short, stable, filesystem-safe digest of a workspace path.

  16 characters of url-safe base64 over a SHA-256: readable in a path listing, and
  wide enough that a collision is not a practical concern.
  """
  @spec workspace_hash(Path.t()) :: String.t()
  def workspace_hash(workspace_root) do
    :sha256
    |> :crypto.hash(normalize_for_hash(workspace_root))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end

  @doc "Per-project overrides: `<workspace>/.troupe/`."
  @spec project_dir(Path.t()) :: Path.t()
  def project_dir(workspace_root), do: Path.join(workspace_root, ".troupe")

  @doc """
  A directory written so that a glob built on it matches that directory and no other.

  `Path.wildcard/2` reads `\\` as an escape and `*`, `?`, `[` and `{` as wildcards, so a
  runtime path cannot start a pattern as it is. The state directory on Windows is
  `C:\\Users\\me\\AppData\\Local\\troupe`, which matched nothing at all, so every dormant
  session vanished from the listing when the daemon restarted; a workspace at
  `C:/src/app[1]` is read as `C:/src/app1`. So `\\` becomes `/`, the separator a glob
  expects, and the wildcard characters are escaped: only what is joined on after this is
  a pattern. A backslash is a separator on every host here, as it is in
  `Troupe.Workspace`; a glob could not match one inside a name anyway.
  """
  @spec glob_escape(Path.t()) :: String.t()
  def glob_escape(path) do
    path
    |> String.replace("\\", "/")
    |> String.replace(["*", "?", "[", "{"], &("\\" <> &1))
  end

  defp override(var) do
    case System.get_env(var) do
      nil -> nil
      "" -> nil
      dir -> dir
    end
  end

  defp default_config_home do
    case :os.type() do
      {:win32, _} -> System.get_env("APPDATA") || fallback_home(".config")
      _ -> System.get_env("XDG_CONFIG_HOME") || fallback_home(".config")
    end
  end

  defp default_state_home do
    case :os.type() do
      {:win32, _} -> System.get_env("LOCALAPPDATA") || fallback_home(".local/state")
      _ -> System.get_env("XDG_STATE_HOME") || fallback_home(".local/state")
    end
  end

  defp fallback_home(suffix) do
    Path.join(System.user_home!(), suffix)
  end

  # Windows paths are compared case-insensitively, so hash them that way too:
  # otherwise `C:\Repo` and `c:\repo` would get separate session histories.
  defp normalize_for_hash(path) do
    normalized = String.replace(path, "\\", "/")

    case :os.type() do
      {:win32, _} -> String.downcase(normalized)
      _ -> normalized
    end
  end
end
