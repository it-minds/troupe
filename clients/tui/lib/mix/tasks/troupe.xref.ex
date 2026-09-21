defmodule Mix.Tasks.Troupe.Xref do
  @moduledoc """
  Fails when the UI reaches past `Troupe.Client`, or the TUI past the harness's doors.

  Local and remote sessions look the same on screen only if the UI cannot tell
  them apart, and it cannot tell them apart only if every call it makes goes
  through the client. That is an architectural rule, so it is checked
  mechanically rather than by review: every compiled module under `Troupe.UI`
  has its BEAM import table read, and a call to any `Troupe.*` module outside
  the allowlist fails the build.

  The allowlist is `Troupe.Client`, the UI's own modules, and the handful of
  pure data and formatting modules a renderer needs — they hold no processes,
  no files and no sockets, so routing them through the client would buy nothing:

      Troupe.Config    the settings page renders a config struct
      Troupe.Settings  field definitions, parsing and formatting
      Troupe.Event     the struct the model folds
      Troupe.Client.Message  content blocks, for the text of an assistant message
      Troupe.Codec     decoding events the client hands over

  The second rule is about the whole TUI and the harness under it. `troupe_core`,
  `troupe_gateway` and `troupe_protocol` are path dependencies on the umbrella beside this
  project (Decision 109), so every public function in them is one `alias` away — and the
  TUI is only an ordinary client of the daemon if it does not use that. It may call the
  harness through these and nothing else, which is what it calls today:

      Troupe.Protocol.Client, .Daemon, .Endpoint   finding, starting and talking to a daemon
      Troupe.Config                                 the configuration the daemon reads too
      Troupe.Paths                                  where state and config live
      Troupe.Reaper                                 the helper every OS process runs under
      Troupe.LLM.Catalog.Store                      refreshing the model catalog on request

  A new call into, say, the agent tree or the session log fails here, and the way to add
  one is to put it in the protocol. What the import table cannot see is a module named as
  an atom — `Troupe.Gateway.Daemon` in the child spec that embeds a daemon when none is
  running — which is the one place the TUI hosts the harness rather than calling it.

  Run it with `mix troupe.xref`; CI runs it alongside `mix test`.
  """

  use Mix.Task

  @shortdoc "Fails if the UI calls anything but Troupe.Client, or the TUI reaches into the harness"

  @allowed [
    Troupe.Client,
    Troupe.Config,
    Troupe.Settings,
    Troupe.Event,
    Troupe.Client.Message,
    Troupe.Codec
  ]

  @harness_apps [:troupe_core, :troupe_gateway, :troupe_protocol]

  @harness_allowed [
    Troupe.Protocol.Client,
    Troupe.Protocol.Daemon,
    Troupe.Protocol.Endpoint,
    Troupe.Config,
    Troupe.Paths,
    Troupe.Reaper,
    Troupe.LLM.Catalog.Store
  ]

  @impl true
  def run(_args) do
    Mix.Task.run("compile")

    offenders =
      ui_modules()
      |> Enum.flat_map(&offending_calls/1)
      |> Enum.sort()
      |> Enum.uniq()

    harness = harness_modules()

    reaching =
      own_modules()
      |> Enum.flat_map(&harness_calls(&1, harness))
      |> Enum.sort()
      |> Enum.uniq()

    report(offenders, "the UI must only call Troupe.Client", "from the UI reach past Troupe.Client")

    report(
      reaching,
      "the TUI may reach the harness only through #{Enum.map_join(@harness_allowed, ", ", &inspect/1)}",
      "from the TUI reach into the harness"
    )

    Mix.shell().info("troupe.xref: the UI only calls #{inspect(Troupe.Client)} ✓")
    Mix.shell().info("troupe.xref: the TUI reaches the harness only through its doors ✓")
    :ok
  end

  defp report([], _rule, _summary), do: :ok

  defp report(calls, rule, summary) do
    Mix.shell().error("troupe.xref: #{rule}\n")

    for {caller, {module, function, arity}} <- calls do
      Mix.shell().error("  #{inspect(caller)} calls #{inspect(module)}.#{function}/#{arity}")
    end

    Mix.raise("#{length(calls)} call(s) #{summary}")
  end

  @doc "This project's own compiled modules."
  @spec own_modules() :: [module()]
  def own_modules do
    Mix.Project.compile_path()
    |> Path.join("Elixir.*.beam")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename(".beam") |> String.to_atom()))
  end

  @doc "Every module of the three harness applications, from their `.app` files."
  @spec harness_modules() :: MapSet.t(module())
  def harness_modules do
    for app <- @harness_apps,
        _ = Application.load(app),
        module <- Application.spec(app, :modules) || [],
        into: MapSet.new(),
        do: module
  end

  @doc "The calls one module makes into the harness past its allowed doors, as `{caller, mfa}`."
  @spec harness_calls(module(), MapSet.t(module())) :: [{module(), mfa()}]
  def harness_calls(caller, harness) do
    caller
    |> imports()
    |> Enum.filter(fn {module, _f, _a} ->
      MapSet.member?(harness, module) and module not in @harness_allowed
    end)
    |> Enum.map(&{caller, &1})
  end

  @doc "The compiled modules under `Troupe.UI`."
  @spec ui_modules() :: [module()]
  def ui_modules do
    Mix.Project.compile_path()
    |> Path.join("Elixir.Troupe.UI.*.beam")
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename(".beam") |> String.to_atom()))
  end

  @doc "The calls one module makes that the rule forbids, as `{caller, mfa}`."
  @spec offending_calls(module()) :: [{module(), mfa()}]
  def offending_calls(caller) do
    caller
    |> imports()
    |> Enum.filter(&forbidden?/1)
    |> Enum.map(&{caller, &1})
  end

  # The BEAM's import table is every external call the module can make, which is
  # exactly the question being asked — and it needs no compiler internals.
  defp imports(module) do
    case :code.which(module) do
      path when is_list(path) ->
        case :beam_lib.chunks(path, [:imports]) do
          {:ok, {^module, [imports: imports]}} -> imports
          _ -> []
        end

      _ ->
        []
    end
  end

  defp forbidden?({module, _function, _arity}) do
    name = Atom.to_string(module)

    String.starts_with?(name, "Elixir.Troupe.") and
      not String.starts_with?(name, "Elixir.Troupe.UI.") and
      module not in @allowed
  end
end
