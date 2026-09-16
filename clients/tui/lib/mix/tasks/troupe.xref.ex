defmodule Mix.Tasks.Troupe.Xref do
  @moduledoc """
  Fails when the UI reaches past `Troupe.Client`.

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
      Troupe.LLM.Message  content blocks, for the text of an assistant message
      Troupe.Codec     decoding events the client hands over

  Run it with `mix troupe.xref`; CI runs it alongside `mix test`.
  """

  use Mix.Task

  @shortdoc "Fails if the TUI or HQ call anything but Troupe.Client"

  @allowed [
    Troupe.Client,
    Troupe.Config,
    Troupe.Settings,
    Troupe.Event,
    Troupe.LLM.Message,
    Troupe.Codec
  ]

  @impl true
  def run(_args) do
    Mix.Task.run("compile")

    offenders =
      ui_modules()
      |> Enum.flat_map(&offending_calls/1)
      |> Enum.sort()
      |> Enum.uniq()

    if offenders == [] do
      Mix.shell().info("troupe.xref: the UI only calls #{inspect(Troupe.Client)} ✓")
      :ok
    else
      Mix.shell().error("troupe.xref: the UI must only call Troupe.Client\n")

      for {caller, {module, function, arity}} <- offenders do
        Mix.shell().error("  #{inspect(caller)} calls #{inspect(module)}.#{function}/#{arity}")
      end

      Mix.raise("#{length(offenders)} call(s) from the UI reach past Troupe.Client")
    end
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
