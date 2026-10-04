defmodule Troupe.Bench.Scenario do
  @moduledoc """
  One scenario of `troupe bench` (Decision 772): what a person asks for, in a workspace
  that starts as the scenario says, and what the run has to show.

    * `name` — the key the report and `priv/bench/budgets.json` know it by
    * `title` — one line saying what it shows
    * `prompt` — what is typed, once, as a person's input
    * `files` — the workspace before the run, `%{relative_path => content}`
    * `config` — settings the scenario needs beside the bench's own, as config overrides
    * `script` — the offline model's steps (`Troupe.Bench.Model`); a run against a real
      model has none, the model decides
    * `outcome` — what a script can check afterwards whoever answered, or `nil`:
      `{:file, path, content}` (the file holds exactly that) or `{:command, argv}` (the
      command, run in the workspace, exits 0: a test passing)
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

  def outcome(%__MODULE__{outcome: {:file, relative, content}}, workspace) do
    case File.read(Path.join(workspace, relative)) do
      {:ok, ^content} -> true
      _other -> false
    end
  end

  def outcome(%__MODULE__{outcome: {:command, [program | args]}}, workspace) do
    case System.find_executable(program) do
      nil -> false
      path -> match?({_output, 0}, System.cmd(path, args, cd: workspace, stderr_to_stdout: true))
    end
  end

  @doc "The outcome in words, for the report."
  @spec describe_outcome(t()) :: String.t() | nil
  def describe_outcome(%__MODULE__{outcome: nil}), do: nil

  def describe_outcome(%__MODULE__{outcome: {:file, path, _content}}),
    do: "#{path} holds what was asked for"

  def describe_outcome(%__MODULE__{outcome: {:command, argv}}),
    do: "`#{Enum.join(argv, " ")}` exits 0"
end
