defmodule Troupe.Remote.Branch do
  @moduledoc """
  How a branch — a session of its own, created with `parent` set to this one — is
  spelled on this session's screen.

  A branch runs as its own session in the daemon (decision 7.3 b of the daemon plan)
  and has its own transcript, with its one agent at `root`. Shown inside its parent's
  TUI it is a window, named the way a local branch always was — `build-1`, the first
  branch of the `build` profile — and everything its agent does arrives under that
  name: `root` becomes `build-1`, `root/explore#1` becomes `build-1/explore#1`. The
  branch's own journal keeps its own spelling; only what reaches a screen is renamed.
  """

  @doc "The agent path of a branch's event, as this session's screen spells it."
  @spec rewrite(String.t(), String.t()) :: String.t()
  def rewrite(path, window) when is_binary(path) and is_binary(window) do
    case String.split(path, "/", parts: 2) do
      [_root] -> window
      [_root, rest] -> window <> "/" <> rest
    end
  end

  @doc "The window an agent path belongs to: its root."
  @spec window_of(String.t()) :: String.t()
  def window_of(path) when is_binary(path), do: path |> String.split("/", parts: 2) |> hd()

  @doc """
  The next window name for a profile: `build-1`, then `build-2`, counting every window
  the profile ever had here so a dismissed one's name is never reused.
  """
  @spec next_name([String.t()], String.t()) :: String.t()
  def next_name(taken, profile) when is_list(taken) and is_binary(profile) do
    highest =
      taken
      |> Enum.flat_map(fn name ->
        case Regex.run(~r/^#{Regex.escape(profile)}-(\d+)$/, name) do
          [_, n] -> [String.to_integer(n)]
          _ -> []
        end
      end)
      |> Enum.max(fn -> 0 end)

    "#{profile}-#{highest + 1}"
  end
end
