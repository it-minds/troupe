defmodule Troupe.Protocol.PermissionRule do
  @moduledoc """
  One per-tool permission rule as `config.yaml` writes it (#658): a tool's name, alone or
  with a pattern in brackets, under `permissions.allow`, `permissions.ask` or
  `permissions.deny`.

      permissions:
        deny: ["shell(git push)", "read_file(secrets/**)"]
        ask: ["mcp(github.create_*)"]
        allow: ["shell(mix test)", "write_file(lib/**)"]

  What a pattern is depends on the tool:

    * `shell`: a command prefix. `shell(git push)` matches `git push` and `git push
      origin main`, not `git pushx`, and so does `shell(git push *)`; `shell(git push*)`
      matches the characters, `git pushx` too. A `*` may only end the pattern.
    * the file tools (`read_file`, `write_file`, `edit_file`, `list_files`, `grep`,
      `glob`, `git_read`): a path glob, relative to the workspace unless it is absolute.
      `*` is any name, `**` any number of directories, `?` one character; a pattern with
      neither is that path and everything under it.
    * `mcp`: `server.tool` for an MCP server's tool, `*` a wildcard, or the server's name
      alone for every tool it has. `mcp` alone is every MCP server's tool, a person's
      client's own servers' included.

  No other tool takes a pattern: a rule for it names it alone.

  Here rather than in the core because the plane checks an organisation's rules when an
  administrator sets them and does not depend on the core; the core reads a file's rules
  with `parse/1` and applies them. Which rule wins is the core's (`Troupe.Config.Permissions`).
  """

  # Strictest first: the order a tie between two rules is broken in.
  @actions ~w(deny ask allow)

  @path_tools ~w(read_file write_file edit_file list_files grep glob git_read)

  # The names other tools give theirs, which a rule copied from one would carry.
  @elsewhere %{
    "bash" => "shell",
    "read" => "read_file",
    "write" => "write_file",
    "edit" => "edit_file",
    "multiedit" => "edit_file",
    "ls" => "list_files",
    "webfetch" => "web_fetch"
  }

  @type action :: :deny | :ask | :allow
  @type kind :: :command | :path | :mcp | nil

  @typedoc "A rule as read: its tool, its pattern (`nil` for every call), and how it is written."
  @type t :: %{tool: String.t(), pattern: String.t() | nil, text: String.t()}

  @doc "The three actions, strictest first."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc "The file tools, whose pattern is a path glob."
  @spec path_tools() :: [String.t()]
  def path_tools, do: @path_tools

  @doc "What a pattern means for a tool: `:command`, `:path`, `:mcp`, or `nil` where it takes none."
  @spec kind(String.t()) :: kind()
  def kind("shell"), do: :command
  def kind("mcp"), do: :mcp
  def kind(tool) when tool in @path_tools, do: :path
  def kind(_tool), do: nil

  @doc """
  Read one rule, or say what is wrong with it and what to write instead. A pattern of `*`
  alone is the tool alone.
  """
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    trimmed = String.trim(text)

    case Regex.run(~r/\A([^()\s]+)(?:\((.*)\))?\z/s, trimmed) do
      [_, tool] -> with :ok <- tool_name(tool), do: {:ok, rule(tool, nil)}
      [_, tool, pattern] -> with :ok <- tool_name(tool), do: pattern(tool, String.trim(pattern))
      nil -> {:error, shape(trimmed)}
    end
  end

  def parse(other),
    do: {:error, "a rule is a string, such as shell(git push), not #{inspect(other)}"}

  defp shape(""), do: "a rule names a tool, such as shell or shell(git push)"

  defp shape(text) do
    if String.contains?(text, "(") and not String.ends_with?(text, ")"),
      do: "#{inspect(text)} opens a bracket it does not close; a rule is a tool or tool(pattern)",
      else:
        "#{inspect(text)} is not a rule; a rule is a tool, or a tool with a pattern in brackets: shell(git push)"
  end

  defp tool_name("mcp." <> rest) do
    {:error, "an MCP server's tool is written mcp(#{rest}), not mcp.#{rest}"}
  end

  defp tool_name("client." <> rest) do
    {:error, "an MCP server's tool is written mcp(#{rest}), not client.#{rest}, whoever hosts it"}
  end

  defp tool_name(tool) do
    cond do
      Map.has_key?(@elsewhere, String.downcase(tool)) ->
        name = @elsewhere[String.downcase(tool)]
        {:error, "#{tool} is another tool's name for it; Troupe's is #{name}, as in #{name}(...)"}

      tool =~ ~r/\A[a-z][a-z0-9_]*\z/ ->
        :ok

      tool =~ ~r/\A[A-Za-z][A-Za-z0-9_]*\z/ ->
        {:error, "a tool's name is lower case: #{String.downcase(tool)}, not #{tool}"}

      true ->
        {:error,
         "#{inspect(tool)} is not a tool's name; a name is lower-case letters, digits and _"}
    end
  end

  defp pattern(tool, ""),
    do:
      {:error,
       "#{tool}() has an empty pattern, which matches nothing; write #{tool} for every call, or a pattern in the brackets"}

  defp pattern(tool, "*"), do: {:ok, rule(tool, nil)}

  defp pattern(tool, pattern), do: pattern(kind(tool), tool, pattern)

  defp pattern(nil, tool, _pattern) do
    {:error,
     "#{tool} takes no pattern; only shell (a command prefix), the file tools (#{Enum.join(@path_tools, ", ")}: " <>
       "a path) and mcp (server.tool) do. Write #{tool} alone"}
  end

  defp pattern(:command, tool, pattern) do
    words = pattern |> String.split() |> Enum.join(" ")
    body = String.trim_trailing(words, "*")

    cond do
      String.ends_with?(words, ":*") ->
        {:error,
         "#{tool}(#{pattern}): drop the :*, since #{tool}(#{String.trim_trailing(words, ":*")}) " <>
           "already matches every command that starts with it"}

      String.contains?(body, "*") ->
        {:error,
         "#{tool}(#{pattern}): a shell rule is a command prefix, which * may only end, as in git push*"}

      true ->
        {:ok, rule(tool, words)}
    end
  end

  defp pattern(:mcp, tool, pattern) do
    if pattern =~ ~r/\A[^\s.]+(\.\S+)?\z/,
      do: {:ok, rule(tool, pattern)},
      else:
        {:error,
         "#{tool}(#{pattern}): an MCP rule names server.tool, or a server alone, such as mcp(github.create_*)"}
  end

  defp pattern(:path, tool, pattern) do
    path = pattern |> String.replace("\\", "/") |> String.replace(~r{\A\./}, "")

    if path in ["", "."],
      do: {:ok, rule(tool, nil)},
      else: {:ok, rule(tool, path)}
  end

  defp rule(tool, nil), do: %{tool: tool, pattern: nil, text: tool}
  defp rule(tool, pattern), do: %{tool: tool, pattern: pattern, text: "#{tool}(#{pattern})"}

  @doc """
  How specific a rule is: a pattern over none, then the longer pattern, counting what it
  says outright rather than its wildcards. Inside one scope the more specific of two rules
  that match a call decides it.
  """
  @spec specificity(t()) :: {0 | 1, non_neg_integer()}
  def specificity(%{pattern: nil}), do: {0, 0}

  def specificity(%{pattern: pattern}),
    do: {1, pattern |> String.replace(["*", "?"], "") |> String.length()}

  @doc """
  Check a set of rules as an organisation's `permissions` holds it: `allow`, `ask` and
  `deny`, each a list of rules. Answers the set with each rule as written, or every reason
  it is refused.
  """
  @spec check_set(term()) :: {:ok, map()} | {:error, [String.t()]}
  def check_set(set) when is_map(set) do
    reasons =
      set
      |> Enum.sort()
      |> Enum.flat_map(fn {action, rules} -> reasons(to_string(action), rules) end)

    if reasons == [],
      do: {:ok, Map.new(set, fn {k, v} -> {to_string(k), v} end)},
      else: {:error, reasons}
  end

  def check_set(_set),
    do:
      {:error,
       [
         "permissions is a map of allow, ask and deny, each a list of rules such as shell(git push)"
       ]}

  defp reasons(action, rules) do
    cond do
      action not in @actions ->
        ["permissions takes allow, ask and deny, not #{action}"]

      is_nil(rules) ->
        []

      not is_list(rules) ->
        ["permissions.#{action} is a list of rules, such as [\"shell(git push)\"]"]

      true ->
        for text <- rules, {:error, why} <- [parse(text)], do: "permissions.#{action}: #{why}"
    end
  end
end
