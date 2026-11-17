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

  A glob that is matched rather than walked (a push rule, a permission, a `.gitignore`
  line, an instruction file's `globs`) is turned into a regular expression by `regex/2`,
  for the same reason.
  """

  @doc """
  The regular expression a glob means, without anchors or options, which the caller adds:
  a rule that names a file anywhere puts `(?:.*/)?` before it, a case-blind one compiles
  with `i`.

  `**/` is any number of directories, none included; `**` is anything; `*` is anything
  within one name and `?` one character of it; everything else is itself. Options:

    * `slash: false`: the subject has no directories (an MCP tool's name), so `*` and `?`
      cross a `/` as well
    * `braces: true`: `{a,b}` is either, nested as deep as it is written
    * `brackets: true`: `[a-z]` is one of those characters, as `.gitignore` writes it; a
      `[` with no `]` after it is itself
  """
  @spec regex(String.t(), keyword()) :: String.t()
  def regex(glob, opts \\ []) when is_binary(glob) do
    opts = %{
      slash: Keyword.get(opts, :slash, true),
      braces: Keyword.get(opts, :braces, false),
      brackets: Keyword.get(opts, :brackets, false)
    }

    translate(glob, 0, opts)
  end

  defp translate("", _depth, _opts), do: ""
  defp translate("**/" <> rest, depth, opts), do: "(?:.*/)?" <> translate(rest, depth, opts)
  defp translate("**" <> rest, depth, opts), do: ".*" <> translate(rest, depth, opts)

  defp translate("*" <> rest, depth, opts),
    do: if(opts.slash, do: "[^/]*", else: ".*") <> translate(rest, depth, opts)

  defp translate("?" <> rest, depth, opts),
    do: if(opts.slash, do: "[^/]", else: ".") <> translate(rest, depth, opts)

  defp translate("{" <> rest, depth, %{braces: true} = opts),
    do: "(?:" <> translate(rest, depth + 1, opts)

  defp translate("}" <> rest, depth, opts) when depth > 0, do: ")" <> translate(rest, depth - 1, opts)
  defp translate("," <> rest, depth, opts) when depth > 0, do: "|" <> translate(rest, depth, opts)

  defp translate("[" <> rest, depth, %{brackets: true} = opts) do
    case String.split(rest, "]", parts: 2) do
      [class, after_class] when class != "" ->
        "[" <> String.replace(class, "\\", "\\\\") <> "]" <> translate(after_class, depth, opts)

      _no_class ->
        "\\[" <> translate(rest, depth, opts)
    end
  end

  defp translate(<<char::utf8, rest::binary>>, depth, opts),
    do: Regex.escape(<<char::utf8>>) <> translate(rest, depth, opts)

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
