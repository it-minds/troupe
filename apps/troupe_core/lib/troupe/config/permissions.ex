defmodule Troupe.Config.Permissions do
  @moduledoc """
  The per-tool rules in force for a session (#658), where each came from, and what they
  say about one call.

  A rule (`Troupe.Protocol.PermissionRule`) names a tool, optionally with a pattern, under
  `permissions.allow`, `permissions.ask` or `permissions.deny` of any file of the
  configuration: an organisation's defaults and what it enforces, the user's
  `config.yaml`, a project's `.troupe/config.yaml` and its `config.local.yaml`. Unlike
  every other key they are not replaced by a higher file: every scope's rules are kept,
  each with its layer and file, and `decide/4` asks all of them.

    * **Inside one file** the most specific rule that matches decides (a pattern over
      none, then the longer pattern); of two as specific, the stricter.
    * **Across files** the strictest verdict holds: `deny` beats `ask` beats `allow`,
      whatever the scope, so no file loosens another's rule, the organisation's included.
    * **A `shell` command** is read as the commands it runs: `a && b`, `a; b`, `a | b`.
      A `deny` or an `ask` holds when it matches any of them; an `allow` only when every
      one is allowed, and never for a command that substitutes another's output
      (`$(...)`, backticks), whose inner command cannot be read in advance.

  Two things keep an `allow` from applying, each marked on the rule with why: a project's
  file in a workspace that is not trusted, or on a pod, as for every key that loosens
  what runs; and `managed_permission_rules_only`, under which only the
  organisation's `allow` rules apply. An `ask` or a `deny` narrows what runs, which any
  file may.
  """

  alias Troupe.Protocol.PermissionRule

  @type action :: :deny | :ask | :allow

  @typedoc """
  One rule as the configuration holds it: what it does, its tool and pattern, how it is
  written, the layer (`org`, `enforced`, `user`, `project`, `local`) and file or URL it
  came from (`profile` for a worker profile's, its name the source), and why it is not
  applied, or `nil`.
  """
  @type rule :: %{
          action: action(),
          tool: String.t(),
          pattern: String.t() | nil,
          text: String.t(),
          layer: atom(),
          source: String.t() | nil,
          ignored: String.t() | nil
        }

  # Which file's rule is named when several of one kind hold: the platform's first, the
  # worker profile's on a pod and the organisation's elsewhere.
  @priority %{profile: 6, enforced: 5, org: 4, user: 3, project: 2, local: 1}

  # The layers whose `allow` stands under `managed_permission_rules_only`: what a platform
  # set, not anything a session's own files say.
  @managed [:org, :enforced, :profile]
  @strictness %{deny: 2, ask: 1, allow: 0}

  @doc """
  The rules one file's `permissions` gives, in `deny`, `ask`, `allow` order, each with
  its layer and source. `ignored` is the reason an `allow` from it does not apply, or
  `nil`.
  """
  @spec from(map() | nil, atom(), String.t() | nil, String.t() | nil) :: [rule()]
  def from(permissions, layer, source, allow_ignored \\ nil)

  def from(permissions, layer, source, allow_ignored) when is_map(permissions) do
    for action <- PermissionRule.actions(),
        text <- List.wrap(permissions[action]),
        {:ok, rule} <- [PermissionRule.parse(text)] do
      action = String.to_existing_atom(action)

      Map.merge(rule, %{
        action: action,
        layer: layer,
        source: source,
        ignored: if(action == :allow, do: allow_ignored)
      })
    end
  end

  def from(_permissions, _layer, _source, _allow_ignored), do: []

  @doc """
  Mark what the resolved configuration says of the rules: with
  `managed_permission_rules_only` on, an `allow` that is not the organisation's is not
  applied.
  """
  @spec hold([rule()], Troupe.Config.t()) :: [rule()]
  def hold(rules, %{managed_permission_rules_only: true}) do
    Enum.map(rules, fn rule ->
      if rule.action == :allow and rule.layer not in @managed and is_nil(rule.ignored),
        do: %{
          rule
          | ignored:
              "managed_permission_rules_only is on, so only the organisation's allow rules apply"
        },
        else: rule
    end)
  end

  def hold(rules, _config), do: rules

  @doc "The rules that apply: those not marked."
  @spec in_force([rule()]) :: [rule()]
  def in_force(rules), do: Enum.reject(rules, & &1.ignored)

  @doc """
  The rules less every `allow`: a branch a saved comment started, where nothing runs
  unasked that would ask: any process that writes a file can write a comment, so a
  branch holds an `allow` as it holds an agent's own `auto`.
  """
  @spec without_allow([rule()]) :: [rule()]
  def without_allow(rules), do: Enum.reject(rules, &(&1.action == :allow))

  @doc """
  What the rules say about one call to `tool` with `args`, in a workspace at `root`:
  `{action, rule}`, the rule named being the one that decided, or `nil` where no rule
  matches and the call goes the way it would without any.
  """
  @spec decide([rule()], String.t(), map(), Path.t() | nil) :: {action(), rule()} | nil
  def decide(rules, tool, args, root)
  def decide([], _tool, _args, _root), do: nil

  def decide(rules, tool, args, root) do
    case Enum.filter(rules, &for_tool?(&1, tool)) do
      [] ->
        nil

      relevant ->
        {subjects, complex?} = subjects(tool, args || %{}, root)

        relevant
        |> Enum.group_by(&{&1.layer, &1.source})
        |> Enum.map(fn {_file, rules} -> verdict(rules, subjects, complex?, root) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.max_by(&{@strictness[&1.action], Map.get(@priority, &1.layer, 0)}, fn -> nil end)
        |> case do
          nil -> nil
          rule -> {rule.action, rule}
        end
    end
  end

  defp for_tool?(%{tool: "mcp"}, "mcp." <> _name), do: true
  # A person's client's own MCP servers' tools are MCP tools too.
  defp for_tool?(%{tool: "mcp"}, "client." <> _name), do: true
  defp for_tool?(%{tool: tool}, tool), do: true
  defp for_tool?(_rule, _tool), do: false

  # One file's word on a call: for each thing the call does (each command of a shell
  # line), the most specific rule that matches it, the stricter of two as specific; then
  # a `deny` for any, an `ask` for any, or an `allow` only for all.
  defp verdict(rules, subjects, complex?, root) do
    picks =
      Enum.map(subjects, fn subject ->
        rules
        |> Enum.filter(&matches?(&1, subject, root))
        |> Enum.max_by(&{PermissionRule.specificity(&1), @strictness[&1.action]}, fn -> nil end)
      end)

    cond do
      deny = Enum.find(picks, &match?(%{action: :deny}, &1)) -> deny
      ask = Enum.find(picks, &match?(%{action: :ask}, &1)) -> ask
      not complex? and Enum.all?(picks, &match?(%{action: :allow}, &1)) -> hd(picks)
      true -> nil
    end
  end

  # -- what a call is about ---------------------------------------------------------

  defp subjects("shell", args, _root) do
    command = if is_binary(args["command"]), do: args["command"], else: ""
    {commands, complex?} = commands(command)
    {if(commands == [], do: [""], else: commands), complex?}
  end

  defp subjects("mcp." <> name, _args, _root), do: {[name], false}
  defp subjects("client." <> name, _args, _root), do: {[name], false}

  defp subjects(tool, args, root) do
    if tool in PermissionRule.path_tools(),
      do: {[path_subject(args["path"], root)], false},
      else: {[nil], false}
  end

  @doc """
  The commands a shell line runs, as rules read them, and whether it substitutes one
  command's output into another, which no `allow` covers. Split at `&&`, `||`, `;`, `|`,
  `&` and new lines outside quotes; each command's leading `NAME=value` assignments
  dropped and its spaces made single. A line that substitutes adds the commands inside
  the substitution too, so a `deny` reaches them.
  """
  @spec commands(String.t()) :: {[String.t()], boolean()}
  def commands(line) do
    {parts, complex?} = split(line, "", [], nil, false)

    inner =
      if complex?,
        do:
          line
          |> String.split(["$(", "`", "<(", ">(", "(", ")"])
          |> Enum.flat_map(&elem(split(&1, "", [], nil, false), 0)),
        else: []

    {(parts ++ inner) |> Enum.map(&tidy/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq(), complex?}
  end

  defp split(<<>>, current, acc, _quote, complex?), do: {Enum.reverse([current | acc]), complex?}

  # An escaped character is itself, outside single quotes.
  defp split(<<"\\", c::utf8, rest::binary>>, current, acc, quote, complex?) when quote != ?',
    do: split(rest, current <> <<?\\, c::utf8>>, acc, quote, complex?)

  defp split(<<"'", rest::binary>>, current, acc, nil, complex?),
    do: split(rest, current <> "'", acc, ?', complex?)

  defp split(<<"'", rest::binary>>, current, acc, ?', complex?),
    do: split(rest, current <> "'", acc, nil, complex?)

  defp split(<<"\"", rest::binary>>, current, acc, nil, complex?),
    do: split(rest, current <> "\"", acc, ?", complex?)

  defp split(<<"\"", rest::binary>>, current, acc, ?", complex?),
    do: split(rest, current <> "\"", acc, nil, complex?)

  # A command's output put into another's, which a double quote does not stop.
  defp split(<<"$(", rest::binary>>, current, acc, quote, _complex?) when quote != ?',
    do: split(rest, current <> "$(", acc, quote, true)

  defp split(<<"`", rest::binary>>, current, acc, quote, _complex?) when quote != ?',
    do: split(rest, current <> "`", acc, quote, true)

  defp split(<<op::binary-size(2), rest::binary>>, current, acc, nil, _complex?)
       when op in ["<(", ">("],
       do: split(rest, current <> op, acc, nil, true)

  # A redirection, not a separator: `2>&1`, `&>`.
  defp split(<<op::binary-size(2), rest::binary>>, current, acc, nil, complex?)
       when op in [">&", "<&", "&>"],
       do: split(rest, current <> op, acc, nil, complex?)

  defp split(<<op::binary-size(2), rest::binary>>, current, acc, nil, complex?)
       when op in ["&&", "||"],
       do: split(rest, "", [current | acc], nil, complex?)

  defp split(<<c, rest::binary>>, current, acc, nil, complex?) when c in [?;, ?|, ?&, ?\n],
    do: split(rest, "", [current | acc], nil, complex?)

  # A subshell's commands are read like a substitution's.
  defp split(<<"(", rest::binary>>, current, acc, nil, _complex?),
    do: split(rest, current <> "(", acc, nil, true)

  defp split(<<c::utf8, rest::binary>>, current, acc, quote, complex?),
    do: split(rest, current <> <<c::utf8>>, acc, quote, complex?)

  # A stray byte that is not UTF-8 is kept as it is.
  defp split(<<c, rest::binary>>, current, acc, quote, complex?),
    do: split(rest, current <> <<c>>, acc, quote, complex?)

  defp tidy(command) do
    command
    |> String.split()
    |> Enum.drop_while(&(&1 =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*=/))
    |> Enum.join(" ")
  end

  # A path as the file tools read it: `session:/` is the workspace, and another mount
  # (`team:x/`, `org:/`, `skills:/`, `scratch:/`) is matched as written. Otherwise both
  # forms, relative to the workspace (`nil` outside it) and absolute, `..` resolved.
  defp path_subject(path, root) do
    path =
      case path do
        p when is_binary(p) and p != "" ->
          p |> String.replace("\\", "/") |> String.replace_prefix("session:/", "")

        _none ->
          "."
      end

    cond do
      path =~ ~r/\A(team|org|skills|scratch):/ -> {:mount, path}
      is_nil(root) -> {path, path}
      true -> relative_and_absolute(path, root)
    end
  end

  defp relative_and_absolute(path, root) do
    root = String.replace(root, "\\", "/")
    absolute = path |> Path.expand(root) |> String.replace("\\", "/")

    relative =
      cond do
        same?(absolute, root) ->
          "."

        under?(absolute, root) ->
          String.slice(absolute, (String.length(String.trim_trailing(root, "/")) + 1)..-1//1)

        true ->
          nil
      end

    {relative, absolute}
  end

  defp same?(a, b), do: fold(String.trim_trailing(a, "/")) == fold(String.trim_trailing(b, "/"))

  defp under?(path, root),
    do: String.starts_with?(fold(path), fold(String.trim_trailing(root, "/")) <> "/")

  # -- matching ---------------------------------------------------------------------

  defp matches?(%{pattern: nil}, _subject, _root), do: true

  defp matches?(%{tool: "shell", pattern: pattern}, command, _root) when is_binary(command) do
    cond do
      # `git push *`: the words, with or without more after them.
      String.ends_with?(pattern, " *") ->
        words?(command, String.trim_trailing(pattern, " *"))

      # `git push*`: the characters, whatever follows them.
      String.ends_with?(pattern, "*") ->
        String.starts_with?(command, String.trim_trailing(pattern, "*"))

      true ->
        words?(command, pattern)
    end
  end

  defp matches?(%{tool: "mcp", pattern: pattern}, name, _root) when is_binary(name) do
    regex = glob_regex(pattern, ".*")
    whole = if String.contains?(pattern, "."), do: regex, else: regex <> "\\..+"
    Regex.match?(~r/\A#{whole}\z/s, name)
  end

  defp matches?(%{pattern: pattern}, {:mount, path}, _root), do: path_match?(pattern, path)

  defp matches?(%{pattern: pattern}, {relative, absolute}, _root) do
    pattern = expand_home(pattern)

    if absolute?(pattern),
      do: path_match?(pattern, absolute),
      else: relative != nil and path_match?(pattern, relative)
  end

  defp matches?(_rule, _subject, _root), do: false

  defp words?(command, prefix),
    do: command == prefix or String.starts_with?(command, prefix <> " ")

  defp expand_home("~/" <> rest),
    do: Path.join(System.user_home!(), rest) |> String.replace("\\", "/")

  defp expand_home(pattern), do: pattern

  defp absolute?(pattern), do: String.starts_with?(pattern, "/") or pattern =~ ~r/\A[A-Za-z]:\//

  # A pattern with no wildcard is that path and everything under it.
  defp path_match?(pattern, path) do
    pattern = String.trim_trailing(pattern, "/")

    if String.contains?(pattern, ["*", "?"]) do
      Regex.match?(
        Regex.compile!("\\A" <> glob_regex(fold(pattern), "[^/]*") <> "\\z", "s"),
        fold(path)
      )
    else
      fold(path) == fold(pattern) or String.starts_with?(fold(path), fold(pattern) <> "/")
    end
  end

  # `**/` any number of directories, `**` anything, `*` what `star` says, `?` one
  # character; the rest as written.
  defp glob_regex(pattern, star) do
    Regex.scan(~r/\*\*\/|\*\*|\*|\?|[^*?]+/, pattern)
    |> Enum.map_join(fn
      ["**/"] -> "(?:.*/)?"
      ["**"] -> ".*"
      ["*"] -> star
      ["?"] -> if star == ".*", do: ".", else: "[^/]"
      [text] -> Regex.escape(text)
    end)
  end

  # Windows' file names are one whatever their case, so a rule is too.
  defp fold(text) do
    case :os.type() do
      {:win32, _} -> String.downcase(text)
      _unix -> text
    end
  end

  # -- saying so --------------------------------------------------------------------

  @doc """
  Where a rule came from, in words: "your organisation (managed.yaml)", "your config.yaml",
  "this project's .troupe/config.yaml", and on a pod "the worker profile fixing".
  """
  @spec scope(rule()) :: String.t()
  # A worker profile's rules are its name's, not a file's.
  def scope(%{layer: :profile, source: profile}), do: "the worker profile #{profile}"

  def scope(%{layer: layer, source: source}) do
    shown = if source, do: " (#{Troupe.Paths.display(source)})", else: ""

    case layer do
      :enforced -> "what your organisation enforces" <> shown
      :org -> "your organisation's defaults" <> shown
      :user -> "your own config.yaml" <> shown
      :project -> "this project's .troupe/config.yaml" <> shown
      :local -> "this project's .troupe/config.local.yaml" <> shown
      other -> "#{other}" <> shown
    end
  end

  @doc "A rule as a sentence names it: `deny shell(git push), from what your organisation enforces (...)`."
  @spec describe(rule()) :: String.t()
  def describe(rule), do: "#{rule.action} #{rule.text}, from #{scope(rule)}"

  @doc "A rule as a client is sent it."
  @spec to_json(rule()) :: map()
  def to_json(rule) do
    %{
      "action" => Atom.to_string(rule.action),
      "rule" => rule.text,
      "tool" => rule.tool,
      "pattern" => rule.pattern,
      "scope" => Atom.to_string(rule.layer),
      "source" => source(rule),
      "ignored" => rule.ignored
    }
  end

  defp source(%{layer: :profile, source: profile}), do: profile
  defp source(%{source: nil}), do: nil
  defp source(%{source: path}), do: Troupe.Paths.display(path)
end
