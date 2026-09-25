defmodule Troupe.Protocol.Glob do
  @moduledoc """
  Globbing under a directory that is only known at run time.

  `Path.wildcard/2` reads `\\` as an escape and `*`, `?`, `[` and `{` as wildcards, so a
  runtime path cannot start a pattern as it is. The state directory on Windows is
  `C:\\Users\\me\\AppData\\Local\\troupe`, which matched nothing at all, so every dormant
  session vanished from the listing when the daemon restarted; a workspace at
  `C:/src/app[1]` is read as `C:/src/app1`.

  It lives in the protocol because that is the one app everything else can call. The
  core escapes its state directory and its workspaces with it, through
  `Troupe.Paths.glob_escape/1`; a bundle's skills are found with it here; and the TUI
  completes `@file` paths with it. One function, so the three cannot drift apart.
  """

  @doc """
  A directory written so that a glob built on it matches that directory and no other.

  `\\` becomes `/`, the separator a glob expects, and the wildcard characters are
  escaped: only what is joined on after this is a pattern. A backslash is a separator on
  every host here, as it is in `Troupe.Workspace`; a glob could not match one inside a
  name anyway.
  """
  @spec escape(Path.t()) :: String.t()
  def escape(path) do
    path
    |> String.replace("\\", "/")
    |> String.replace(["*", "?", "[", "{"], &("\\" <> &1))
  end
end
