defmodule Troupe.Onboard.AgentsAndCommands.Shared do
  @moduledoc """
  What reading Claude Code's and opencode's agents and commands has in common
  (Decision 824): a file read only where it really is in the workspace, frontmatter read
  the way those tools read it, a name Troupe can give, a model that is not an alias, and a
  rule for some uses of a tool turned into what Troupe can say of the whole tool.

  Every note is one sentence naming the key it is about, for a person deciding whether to
  accept a proposal.
  """

  alias Troupe.Agent.Definition
  alias Troupe.Protocol.AgentDefinition
  alias Troupe.Workspace

  @typedoc "One agent another tool defined, as Troupe's, and where it came from."
  @type agent :: %{
          definition: Definition.t(),
          notes: [String.t()],
          source: String.t(),
          source_hash: String.t(),
          label: String.t(),
          rank: non_neg_integer()
        }

  @typedoc "One command another tool defined, as Troupe's file would hold it."
  @type command :: %{
          name: String.t(),
          description: String.t() | nil,
          hint: String.t() | nil,
          body: String.t(),
          notes: [String.t()],
          source: String.t(),
          source_hash: String.t(),
          label: String.t(),
          rank: non_neg_integer()
        }

  @typedoc "What was not turned into a proposal, and why, in words."
  @type skip :: %{source: String.t(), name: String.t() | nil, reason: String.t()}

  @outside "not proposed: outside the workspace"

  @strictness %{auto: 0, ask: 1, deny: 2}

  # Claude Code's names for a model it picks itself; `inherit` is the session's.
  @claude_aliases ~r/\A(default|sonnet|opus|haiku|fable|opusplan|inherit)(\[1m\])?\z/i

  @doc """
  A file's bytes, when it really is inside `root`, links followed, as the instruction
  files are judged (Decision 798); otherwise why not.
  """
  @spec read(Path.t(), Path.t()) :: {:ok, binary()} | {:skip, String.t()}
  def read(root, path) do
    if inside?(path, root) do
      case File.read(path) do
        {:ok, bytes} -> {:ok, bytes}
        {:error, reason} -> {:skip, "not proposed: #{:file.format_error(reason)}"}
      end
    else
      {:skip, @outside}
    end
  end

  @doc "Whether a path really is inside `root`, links followed."
  @spec inside?(Path.t(), Path.t()) :: boolean()
  def inside?(path, root) do
    with {:ok, real} <- Workspace.real_path(path),
         {:ok, real_root} <- Workspace.real_path(root) do
      String.starts_with?(Workspace.compare_key(real), Workspace.compare_key(real_root) <> "/")
    else
      _error -> false
    end
  end

  @doc "A path under `root` as a proposal names its source: relative, forward slashes."
  @spec relative(Path.t(), Path.t()) :: String.t()
  def relative(root, path),
    do: path |> Path.expand() |> Path.relative_to(Path.expand(root)) |> String.replace("\\", "/")

  @doc "The lowercase hex sha256 of a source's bytes."
  @spec hash(binary()) :: String.t()
  def hash(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  @doc """
  Frontmatter as Claude Code and opencode write it: YAML, and failing that a line per key,
  which is how a description with a colon in it is still read (`description: Use when:
  ...`). The notes say when it was the second.
  """
  @spec frontmatter(binary()) :: {map(), String.t(), [String.t()]}
  def frontmatter(contents) do
    case AgentDefinition.split_frontmatter(contents) do
      {"", body} ->
        {%{}, body, []}

      {yaml, body} ->
        case YamlElixir.read_from_string(yaml) do
          {:ok, meta} when is_map(meta) ->
            {meta, body, []}

          _not_a_map ->
            {line_keys(yaml), body,
             ["The frontmatter is not YAML, so each of its lines is read as a key and its value."]}
        end
    end
  end

  defp line_keys(yaml) do
    yaml
    |> String.split(~r/\r?\n/)
    |> Enum.reduce({%{}, nil}, &line_key/2)
    |> elem(0)
  end

  defp line_key(line, {meta, last}) do
    case {Regex.run(~r/\A([A-Za-z][\w-]*):\s*(.*?)\s*\z/, line),
          Regex.run(~r/\A\s+-\s+(.*?)\s*\z/, line)} do
      {[_line, key, value], _item} ->
        {Map.put(meta, key, unquote_value(value)), key}

      {nil, [_line, item]} when is_binary(last) ->
        {Map.update!(meta, last, &append(&1, unquote_value(item))), last}

      _other ->
        {meta, last}
    end
  end

  defp append("", item), do: [item]
  defp append(list, item) when is_list(list), do: list ++ [item]
  defp append(other, _item), do: other

  defp unquote_value(<<q, rest::binary>> = value) when q in [?", ?'] do
    if String.ends_with?(rest, <<q>>), do: String.slice(rest, 0..-2//1), else: value
  end

  defp unquote_value(value), do: value

  @doc """
  The name a file or an entry gives, else `fallback`, as a name Troupe can give an agent
  or a command: as it is when it is one, else lower-cased with each run of other
  characters a dash, which the note says, else not proposed.
  """
  @spec name(term(), String.t() | nil) ::
          {:ok, String.t(), [String.t()]} | {:skip, String.t() | nil, String.t()}
  def name(given, fallback) do
    raw =
      case given do
        given when is_binary(given) ->
          if String.trim(given) == "", do: fallback, else: String.trim(given)

        _absent ->
          fallback
      end

    slug = slug(raw)

    cond do
      AgentDefinition.valid_name?(raw) ->
        {:ok, raw, []}

      AgentDefinition.valid_name?(slug) ->
        {:ok, slug,
         [
           "The name #{inspect(raw)} is #{slug} here: Troupe's names are lower-case letters, digits and dashes."
         ]}

      true ->
        {:skip, raw,
         "not proposed: #{inspect(raw)} is not a name Troupe can give (lower-case letters, digits and dashes, at most 64)"}
    end
  end

  defp slug(raw) when is_binary(raw) do
    raw
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 64)
    |> String.trim_trailing("-")
  end

  defp slug(_none), do: ""

  @doc """
  The model to write, or none, and why not. A model that names one is written as it is
  (`provider/model` reaches the provider of that name in `config.yaml`); Claude Code's
  aliases are not, since which model `sonnet` is depends on a live session's provider,
  which an import cannot ask, so the agent runs on the session's model (Decision 824).
  """
  @spec model(term(), :claude_code | :opencode) :: {String.t() | nil, [String.t()]}
  def model(nil, _tool), do: {nil, []}

  def model(model, tool) when is_binary(model) do
    model = String.trim(model)

    cond do
      model == "" ->
        {nil, []}

      tool == :claude_code and String.downcase(model) == "inherit" ->
        {nil,
         [
           "The model inherit is left out: an agent without a model runs on the session's, which is what inherit asks for."
         ]}

      tool == :claude_code and Regex.match?(@claude_aliases, model) ->
        {nil,
         [
           "The model #{model} is left out: it is Claude Code's name for a model it picks itself, " <>
             "which onboarding cannot ask a session for, so the agent runs on the session's model."
         ]}

      true ->
        {model, []}
    end
  end

  def model(other, _tool),
    do:
      {nil,
       [
         "The model #{inspect(other)} is left out: it is not a model's name, so the agent runs on the session's model."
       ]}

  @doc "A positive number of turns, or none and why."
  @spec max_turns(String.t(), term()) :: {pos_integer() | nil, [String.t()]}
  def max_turns(_key, nil), do: {nil, []}
  def max_turns(_key, n) when is_integer(n) and n > 0, do: {n, []}

  def max_turns(key, n) when is_binary(n) do
    case Integer.parse(String.trim(n)) do
      {int, ""} when int > 0 -> {int, []}
      _other -> {nil, [bad_turns(key, n)]}
    end
  end

  def max_turns(key, other), do: {nil, [bad_turns(key, other)]}

  defp bad_turns(key, value),
    do:
      "#{key} #{inspect(value)} is left out: it is not a positive number, so the agent has the session's limit."

  @doc """
  A list of tools with what Troupe's harness needs to honour it: `finish`, for a subagent
  to report, and `read_output`, the rest of a cut `shell` or `grep` result (Decision 650).
  """
  @spec list_for([String.t()]) :: [String.t()]
  def list_for(names) do
    companions = if Enum.any?(names, &(&1 in ["shell", "grep"])), do: ["read_output"], else: []
    Enum.uniq(names ++ companions ++ ["finish"])
  end

  @doc "Of two permissions, the one that asks more."
  @spec stricter(Definition.permission(), Definition.permission()) :: Definition.permission()
  def stricter(a, b), do: if(@strictness[a] >= @strictness[b], do: a, else: b)

  @doc "Two maps of permissions, the stricter of each tool both name."
  @spec merge_stricter(map(), map()) :: map()
  def merge_stricter(a, b), do: Map.merge(a, b, fn _tool, x, y -> stricter(x, y) end)

  @doc """
  What a set of rules for one tool comes to, Troupe allowing a tool whole or not at all:
  `{action, whole?}` pairs, `action` one of `:auto`, `:ask`, `:deny`. A rule for all of it
  that denies or asks stands; a rule that stops some of its uses makes the whole tool ask,
  so nothing the source asked about or refused runs without asking; one that allows all of
  it stands after those; a rule that allows only some uses says nothing, and the tool keeps
  Troupe's own approval (`nil`).
  """
  @spec resolve([{Definition.permission(), boolean()}]) :: Definition.permission() | nil
  def resolve(rules) do
    cond do
      {:deny, true} in rules -> :deny
      {:ask, true} in rules -> :ask
      {:deny, false} in rules or {:ask, false} in rules -> :ask
      {:auto, true} in rules -> :auto
      true -> nil
    end
  end

  @doc "`Read, Grep` or a YAML list, as entries; commas inside a rule's parentheses are the rule's."
  @spec entries(term()) :: [String.t()]
  def entries(value) when is_binary(value) do
    value
    |> String.split(~r/,(?![^(]*\))/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def entries(value) when is_list(value),
    do: value |> Enum.map(&(&1 |> to_string() |> String.trim())) |> Enum.reject(&(&1 == ""))

  def entries(_other), do: []

  @doc """
  One note per key `meta` has that is neither read nor in `reasons`' map of why not, in
  key order: `reasons` gives the why for the keys it knows, and anything else is a key the
  target does not read.
  """
  @spec other_keys(map(), [String.t()], %{optional(String.t()) => String.t()}, String.t()) ::
          [String.t()]
  def other_keys(meta, read, reasons, unknown) do
    meta
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 in read))
    |> Enum.sort()
    |> Enum.map(&"#{&1} is left out: #{Map.get(reasons, &1, unknown)}.")
  end

  @doc """
  What a command's body holds that Troupe will not fill or run, said once each: argument
  placeholders other than `$ARGUMENTS`, and shell lines the other tool runs before it
  sends the prompt.
  """
  @spec body_notes(String.t()) :: [String.t()]
  def body_notes(body) do
    placeholders =
      ~r/\$(?:ARGUMENTS\[\d+\]|\d+)/
      |> Regex.scan(body)
      |> List.flatten()
      |> Enum.uniq()

    positional =
      if placeholders == [],
        do: [],
        else: [
          "The body's #{Enum.join(placeholders, ", ")} stay as written: Troupe fills $ARGUMENTS alone, " <>
            "with everything typed after the command's name."
        ]

    shell =
      if Regex.match?(~r/!`[^`]+`|^\s*```!/m, body),
        do: [
          "The body's !`...` shell lines stay as written: Troupe does not run a command's shell lines before " <>
            "sending it, so the model reads the command rather than its output."
        ],
        else: []

    positional ++ shell
  end

  @doc """
  Each `.md` file directly in `root`'s `dir` through `fun`, which answers `{:ok, item}` or
  `{:skip, skip}`. A directory that is a link out of the workspace is skipped whole, and
  each subdirectory is said, since neither tool's files there have a name of their own
  among Troupe's, whose agents and commands are the files of one directory.
  """
  @spec each_markdown(Path.t(), String.t(), (Path.t() -> {:ok, item} | {:skip, skip()})) ::
          {[item], [skip()]}
        when item: term()
  def each_markdown(root, dir, fun) do
    path = Path.join(root, dir)

    cond do
      not File.dir?(path) ->
        {[], []}

      not inside?(path, root) ->
        {[], [skip(dir, nil, @outside)]}

      true ->
        {files, dirs} = markdown(path)
        results = Enum.map(files, &fun.(Path.join(path, &1)))

        nested =
          Enum.map(
            dirs,
            &skip(
              "#{dir}/#{&1}",
              nil,
              "not proposed: a file in a subdirectory has no name of its own among Troupe's, whose agents and commands are the files of one directory"
            )
          )

        {for({:ok, item} <- results, do: item), for({:skip, skip} <- results, do: skip) ++ nested}
    end
  end

  # The `.md` files directly in `dir`, sorted, and the subdirectories beside them.
  defp markdown(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries = Enum.sort(entries)

        files =
          Enum.filter(
            entries,
            &(String.ends_with?(&1, ".md") and File.regular?(Path.join(dir, &1)))
          )

        {files, Enum.filter(entries, &File.dir?(Path.join(dir, &1)))}

      {:error, _reason} ->
        {[], []}
    end
  end

  @command_read ~w(description argument-hint)

  @doc """
  A command file another tool wrote, as Troupe's (Decision 763): its name the file's,
  `description` and `argument-hint` carried, the body the prompt, every other key left out
  with `reasons`' why (`unknown` for a key it does not know), and what the body holds that
  Troupe will not fill or run said.
  """
  @spec command(Path.t(), Path.t(), non_neg_integer(), map(), String.t()) ::
          {:ok, command()} | {:skip, skip()}
  def command(root, path, rank, reasons, unknown) do
    source = relative(root, path)

    with {:ok, bytes} <- read(root, path),
         {meta, body, read_notes} = frontmatter(bytes),
         {:ok, name, name_notes} <- name(nil, Path.basename(path, ".md")),
         body = String.trim(body),
         :ok <-
           if(body == "", do: {:skip, name, "not proposed: it has no prompt to send"}, else: :ok) do
      {:ok,
       %{
         name: name,
         description: text(meta["description"]),
         hint: hint(meta["argument-hint"]),
         body: body,
         notes:
           read_notes ++
             name_notes ++ other_keys(meta, @command_read, reasons, unknown) ++ body_notes(body),
         source: source,
         source_hash: hash(bytes),
         label: source,
         rank: rank
       }}
    else
      {:skip, reason} -> {:skip, skip(source, nil, reason)}
      {:skip, name, reason} -> {:skip, skip(source, name, reason)}
    end
  end

  # `argument-hint: [message]` is a YAML list of one, as both tools' examples write it.
  defp hint(list) when is_list(list), do: "[" <> Enum.map_join(list, ", ", &to_string/1) <> "]"
  defp hint(value), do: text(value)

  @doc "Text, or nil for none."
  @spec text(term()) :: String.t() | nil
  def text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  def text(value) when is_number(value), do: to_string(value)
  def text(_value), do: nil

  @doc "A skipped file or entry."
  @spec skip(String.t(), String.t() | nil, String.t()) :: skip()
  def skip(source, name, reason), do: %{source: source, name: name, reason: reason}
end
