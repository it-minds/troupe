defmodule Troupe.Bench.Scenario do
  @moduledoc """
  One scenario of `troupe bench` (Decision 772): what a person asks for, in a workspace
  that starts as the scenario says, and what the run has to show.

    * `name` — the key the report and `priv/bench/budgets.json` know it by
    * `title` — one line saying what it shows
    * `prompt` — what is typed, once, as a person's input
    * `follow_ups` — what is typed after it, each once the turn before has ended by
      itself; a live scenario's only (Decision 815)
    * `files` — the workspace before the run, `%{relative_path => content}`
    * `config` — settings the scenario needs beside the bench's own, as config overrides
    * `script` — the offline model's steps (`Troupe.Bench.Model`); a run against a real
      model has none, the model decides
    * `outcome` — what a script can check afterwards whoever answered, or `nil`:
      `{:file, path, content}` (the file holds that text, line endings and trailing
      whitespace aside) or `{:command, argv}` (the command, run in the workspace, exits
      0: a test passing)
    * `drive` — `nil` to type the prompt and wait for the turn to end, or a function
      of the run's context that does something else (cancel half way) and returns it
    * `measure` — a function of the run's context answering `{metrics, checks}`: each
      metric `{name, label, unit, value}`, held to its budget when the budgets file has
      one, and each check `{name, label, passed?}`, for what is not a number
  """

  @enforce_keys [:name, :title, :prompt, :measure]
  defstruct [
    :name,
    :title,
    :prompt,
    :measure,
    follow_ups: [],
    files: %{},
    config: [],
    script: [],
    outcome: nil,
    drive: nil
  ]

  @type metric :: {String.t(), String.t(), String.t(), number()}
  @type check :: {String.t(), String.t(), boolean()}
  @type outcome :: {:file, Path.t(), String.t()} | {:command, [String.t()]} | nil

  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t(),
          prompt: String.t(),
          measure: (map() -> {[metric()], [check()]}),
          follow_ups: [String.t()],
          files: %{String.t() => iodata()},
          config: keyword(),
          script: [Troupe.Bench.Model.step()],
          outcome: outcome(),
          drive: (map() -> map()) | nil
        }

  @doc "Write the scenario's files into a workspace."
  @spec seed(t(), Path.t()) :: :ok
  def seed(%__MODULE__{files: files}, workspace) do
    Enum.each(files, fn {relative, content} ->
      path = Path.join(workspace, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)
  end

  @doc """
  Whether the workspace shows the outcome: `nil` for a scenario that declares none, so a
  report can tell "nothing to check" from "checked and wrong".
  """
  @spec outcome(t(), Path.t()) :: boolean() | nil
  def outcome(%__MODULE__{outcome: nil}, _workspace), do: nil

  def outcome(%__MODULE__{outcome: {:file, relative, content}}, workspace),
    do: holds?(workspace, relative, content)

  def outcome(%__MODULE__{outcome: {:command, [program | args]}}, workspace) do
    case System.find_executable(program) do
      nil ->
        false

      path ->
        # The environment every command Troupe starts gets (Decision 776): in a release,
        # a PATH without the release's own runtime, whose `erl` has no boot file
        # (Decision 773).
        {_output, status} =
          System.cmd(path, args,
            cd: workspace,
            stderr_to_stdout: true,
            env: Troupe.Reaper.child_env()
          )

        status == 0
    end
  end

  @doc """
  The `PATH` a command outcome runs with: this VM's, less `erts_bin`
  (`Troupe.Reaper.path_without/2`, which every command started through reaper gets since
  Decision 776).
  """
  @spec command_path(String.t(), Path.t() | nil) :: String.t()
  def command_path(path, erts_bin), do: Troupe.Reaper.path_without(path, erts_bin)

  @doc """
  Whether a file of the workspace holds `content`, as a `{:file, ...}` outcome is judged:
  the text, line endings and trailing whitespace aside. A check beside an outcome asks it
  of another file (Decision 775).
  """
  @spec holds?(Path.t(), Path.t(), String.t()) :: boolean()
  def holds?(workspace, relative, content) do
    case File.read(Path.join(workspace, relative)) do
      {:ok, found} -> text(found) == text(content)
      _other -> false
    end
  end

  # What a file says, whatever it ends with: a model asked for one line may or may not
  # end it with a newline, and on Windows may write `\r\n` (Decision 773).
  defp text(content), do: content |> String.replace("\r\n", "\n") |> String.trim_trailing()

  @doc "The outcome in words, for the report."
  @spec describe_outcome(t()) :: String.t() | nil
  def describe_outcome(%__MODULE__{outcome: nil}), do: nil

  def describe_outcome(%__MODULE__{outcome: {:file, path, _content}}),
    do: "#{path} holds what was asked for"

  def describe_outcome(%__MODULE__{outcome: {:command, argv}}),
    do: "`#{Enum.join(argv, " ")}` exits 0"
end
