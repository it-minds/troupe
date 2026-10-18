defmodule Troupe.Agent.Local do
  @moduledoc """
  The agents a person keeps, as files a client reads, checks, writes and takes away
  (#503, Decision 841): their own in `<config>/agents/` (scope `:user`) and a workspace's
  in `.troupe/agents/` (scope `:project`, committed and shared), which
  `Troupe.Agent.Definitions` layers over the built-ins, as #60 layers MCP servers and
  skills (Decision 700). Both clients manage one set through the daemon's `agents.*`
  methods and never write the directories themselves, so the checks and the choice of
  layer happen in one place.

  - **Checked before it is written.** `put/5` runs `Troupe.Agent.Validate.check/2` and
    writes nothing while it finds an error; its warnings go back with what was written.
  - **One edge.** The file is written through onboarding's writer
    (`Troupe.Onboard.put_file/5`): judged where it really is, a project file under the
    workspace's real `.troupe/`, which is Decision 829's edge for the reader held by the
    writer too; a temporary file renamed over it.
  - **What is not a person's to change here.** A built-in is Troupe's: a copy of it in
    either scope, under its name or another, is how it is changed, and is the common case;
    deleting one is refused. A bundle's agent is its profile's, changed in the console,
    and on a pod every agent is the bundle's (`not_editable/2`); the daemon's gateway
    refuses every write there.
  """

  alias Troupe.Agent.{Definition, Definitions, Validate}
  alias Troupe.Onboard
  alias Troupe.Paths
  alias Troupe.Protocol.AgentDefinition

  @type scope :: :user | :project

  # The three a read-only agent cannot reach: writing a file, editing one and running a
  # command, as the built-in `plan` and `explore` deny them.
  @writers ~w(write_file edit_file shell)

  @on_a_pod "On a pod the agents come from the profile's bundle and are read-only here: " <>
              "change them in the console"

  @doc "Why nothing is written on a pod (Decision 841)."
  @spec on_a_pod() :: String.t()
  def on_a_pod, do: @on_a_pod

  @doc """
  The layer a definition answers from, as a client shows it: `builtin`, `bundle`, `user`
  (the source `:global`) or `project`, the last two the `scope` a person writes.
  """
  @spec layer(Definition.t()) :: String.t()
  def layer(%Definition{source: :global}), do: "user"
  def layer(%Definition{source: source}), do: Atom.to_string(source)

  @doc """
  Where a definition comes from, in the words a person uses, the same in both clients'
  pickers (#594): `Shipped` (Troupe's own), `Your organisation's` (the profile's bundle),
  `Yours` (`<config>/agents/`, in every workspace) and `This repository's`
  (`.troupe/agents/`, committed). The person's and the repository's stay two: an `auto` in
  the person's applies in every workspace, trusted or not, and a repository's only once
  the workspace is trusted. Takes a definition or a layer's name.
  """
  @spec origin(Definition.t() | String.t()) :: String.t()
  def origin(%Definition{} = definition), do: definition |> layer() |> origin()
  def origin("builtin"), do: "Shipped"
  def origin("bundle"), do: "Your organisation's"
  def origin("user"), do: "Yours"
  def origin("project"), do: "This repository's"
  def origin(other) when is_binary(other), do: other

  @doc "Whether the definition denies writing a file, editing one and running a command."
  @spec read_only?(Definition.t()) :: boolean()
  def read_only?(%Definition{} = definition),
    do: Enum.all?(@writers, &(Definition.permission(definition, &1, :ask) == :deny))

  @doc """
  Why a definition is not one a person may change here, in a sentence, or `nil` when it
  is. `pod: true` says the question is asked on a pod.
  """
  @spec not_editable(Definition.t(), keyword()) :: String.t() | nil
  def not_editable(%Definition{} = definition, opts \\ []) do
    cond do
      definition.source == :bundle ->
        "#{definition.name} comes from the profile's bundle; change it in the console"

      opts[:pod] ->
        @on_a_pod

      definition.source == :builtin ->
        "#{definition.name} is built in: a copy of it in your agents or the repository's " <>
          "(agents.put with a scope) replaces it"

      true ->
        nil
    end
  end

  @doc """
  The other files of the same name a lower layer has, which this definition hides, the
  nearest first: what answers to the name once this one is taken away.
  """
  @spec hidden(Definition.t(), Path.t() | nil) :: [%{layer: String.t(), path: Path.t()}]
  def hidden(%Definition{name: name} = definition, workspace) do
    own = layer(definition)
    below = workspace |> files(name) |> Enum.take_while(fn {layer, _file} -> layer != own end)
    for {layer, file} <- Enum.reverse(below), File.regular?(file), do: %{layer: layer, path: file}
  end

  # The files a name could have on this machine, lowest layer first.
  defp files(workspace, name) do
    [
      {"builtin", Path.join(Definitions.builtin_dir(), name <> ".md")},
      {"user", Path.join([Paths.config_dir(), "agents", name <> ".md"])}
    ] ++
      if(workspace,
        do: [{"project", Path.join([Paths.project_dir(workspace), "agents", name <> ".md"])}],
        else: []
      )
  end

  @doc """
  What a client compares to know a file is the one it read: `"sha256:<hex>"` of its text,
  as `fs.read` and `fs_changed` write a file's hash; `nil` for no text.
  """
  @spec hash(String.t() | nil) :: String.t() | nil
  def hash(nil), do: nil
  def hash(text), do: "sha256:" <> (:sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower))

  @doc """
  The person's or the repository's file of `name` that was found and does not parse, the
  nearest to winning first, for a manager to open and mend (Decision 852): its `scope`
  (where `put/5` writes it back), `layer`, `path`, `text`, `hash` and the `reason` it is
  not read; `nil` when there is none. A file that was never read (one linked out of the
  workspace, a main checkout's draft, one a bundle's name beats) is not one: its `scope` is
  the place `put/5` writes, so only a file at that very place counts.
  """
  @spec broken(Definitions.t(), String.t(), Path.t() | nil) :: map() | nil
  def broken(%Definitions{} = definitions, name, workspace) do
    places = [
      {:project, workspace && Path.join([Paths.project_dir(workspace), "agents", name <> ".md"])},
      {:user, Path.join([Paths.config_dir(), "agents", name <> ".md"])}
    ]

    definitions
    |> Definitions.skipped()
    |> Enum.filter(&(&1.name == name and Map.has_key?(&1, :source)))
    |> Enum.reverse()
    |> Enum.find_value(&mendable(&1, places))
  end

  defp mendable(skipped, places) do
    with {scope, _place} <- Enum.find(places, &at?(&1, skipped.path)),
         {:ok, text} <- File.read(skipped.path) do
      %{
        scope: scope,
        layer: Atom.to_string(scope),
        path: skipped.path,
        text: text,
        hash: hash(text),
        reason: skipped.reason
      }
    else
      _not_a_place -> nil
    end
  end

  defp at?({_scope, nil}, _path), do: false

  defp at?({_scope, place}, path),
    do: Troupe.Workspace.compare_key(place) == Troupe.Workspace.compare_key(path)

  @doc """
  Check a definition and write it as `<name>.md` in the scope's directory: `{:ok,
  written}` with the file, how a person sees its path, whether it was `:created` or
  `:replaced`, and the check's warnings (and one when a project file of the name hides a
  user one); `{:error, {:invalid, result}}` with every error, nothing written; `{:error,
  {:changed, %{shown, hash}}}` when `if_hash:` is given and the file there is not that one
  any more (Decision 852); or `{:error, sentence}` when the writer refuses the place.
  `config:` is what the model is checked against; `config_dir:` for a test.
  """
  @spec put(scope(), Path.t() | nil, String.t(), String.t(), keyword()) ::
          {:ok,
           %{
             file: Path.t(),
             shown: String.t(),
             action: :created | :replaced,
             warnings: [Validate.finding()]
           }}
          | {:error,
             {:invalid, Validate.result()}
             | {:bad_name, String.t()}
             | {:changed, %{shown: String.t(), hash: String.t() | nil}}
             | String.t()}
  def put(scope, workspace, name, source, opts \\ []) do
    with :ok <- name_ok(name),
         :ok <- placed(scope, workspace) do
      checked = Validate.check(source, name: name, config: opts[:config])

      if checked.ok do
        write(scope, workspace, name, source, checked.warnings, opts)
      else
        {:error, {:invalid, checked}}
      end
    end
  end

  defp write(scope, workspace, name, source, warnings, opts) do
    case Onboard.put_file(
           target(scope),
           file(name),
           source,
           workspace,
           Keyword.take(opts, [:config_dir, :if_hash])
         ) do
      {:ok, written} ->
        {:ok, Map.put(written, :warnings, warnings ++ shadowed(scope, workspace, name))}

      {:error, _sentence_or_changed} = refused ->
        refused
    end
  end

  # A person's own agent that the repository has a file of the same name for: written, and
  # said, since in this workspace the repository's is the one that runs.
  defp shadowed(:user, workspace, name) when is_binary(workspace) do
    if File.regular?(Path.join([Paths.project_dir(workspace), "agents", name <> ".md"])),
      do: [
        %{
          field: "name",
          message:
            "the repository's .troupe/agents/#{name}.md has this name too, and is the one " <>
              "that runs in this workspace"
        }
      ],
      else: []
  end

  defp shadowed(_scope, _workspace, _name), do: []

  @doc """
  Take away `<name>.md` in the scope's directory: `{:ok, removed}`, `{:error, :not_found}`
  when there is no such file, `{:error, {:read_only, sentence}}` for a built-in's name
  with no copy there to take away, or `{:error, sentence}` when the writer refuses the
  place.
  """
  @spec delete(scope(), Path.t() | nil, String.t(), keyword()) ::
          {:ok, %{file: Path.t(), shown: String.t()}}
          | {:error, :not_found | {:read_only, String.t()} | {:bad_name, String.t()} | String.t()}
  def delete(scope, workspace, name, opts \\ []) do
    with :ok <- name_ok(name),
         :ok <- placed(scope, workspace) do
      case Onboard.remove_file(
             target(scope),
             file(name),
             workspace,
             Keyword.take(opts, [:config_dir])
           ) do
        {:error, :enoent} -> missing(scope, name)
        other -> other
      end
    end
  end

  defp missing(scope, name) do
    if File.regular?(Path.join(Definitions.builtin_dir(), name <> ".md")),
      do:
        {:error,
         {:read_only,
          "#{name} is built in and is not deleted; only a copy of it is, and #{where(scope)} " <>
            "has none"}},
      else: {:error, :not_found}
  end

  defp where(:user), do: "your agents directory"
  defp where(:project), do: "the repository's .troupe/agents"

  defp name_ok(name) do
    if AgentDefinition.valid_name?(name),
      do: :ok,
      else:
        {:error,
         {:bad_name,
          "#{inspect(name)} is not a name an agent may have: lowercase letters, digits and " <>
            "dashes, starting with a letter or digit, at most 64"}}
  end

  defp placed(:project, workspace) when not is_binary(workspace),
    do: {:error, "a project agent is a workspace's: name the workspace"}

  defp placed(_scope, _workspace), do: :ok

  defp target(:user), do: :user
  defp target(:project), do: :repo

  defp file(name), do: "agents/#{name}.md"
end
