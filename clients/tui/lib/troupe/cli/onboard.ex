defmodule Troupe.CLI.Onboard do
  @moduledoc """
  `troupe onboard [--workspace DIR] [--yes] [--json] [--all]` (root Decision 823): other
  tools' files brought into Troupe's own, each shown as a diff and written only when the
  person says yes to it.

  What is proposed, where it may go and how it is written are the harness's
  (`Troupe.Onboard`, a door `mix troupe.xref` lets the TUI call, as `troupe instructions
  check` calls `Troupe.Instructions.Check`). This reads and writes the files on this
  machine, as that does, with no daemon, and asks the questions: a file at a time, at a
  terminal only. `--yes` writes every proposal without asking; `--json` prints the
  proposals as one object and writes nothing unless `--yes` is given too. A no is
  remembered, so the next run asks only about what changed since; `--all` asks again.
  What a source found and proposed nothing for is listed first, each with its reason.

  Exits 0 when everything asked about was answered, 1 when a proposal was refused or a
  write failed, 2 when the workspace is not a directory here or there was nobody to ask.
  """

  alias Troupe.CLI.{Prompt, Terminal}
  alias Troupe.Paths

  @doc """
  Run it and print what happened; returns the exit status.

  `opts` stand in for the person and the machine in tests: `:ask`, a function of the
  question answering the line typed, `nil` at the end of input, or `:no_terminal`; and
  `:sources`, `:config_dir`, `:home` and `:state_dir`, which `Troupe.Onboard` takes.
  """
  @spec run(Troupe.CLI.args(), keyword()) :: non_neg_integer()
  def run(args, opts \\ []) do
    workspace = args.workspace
    onboard = Keyword.take(opts, [:sources, :config_dir, :home, :state_dir])

    if File.dir?(workspace) do
      plan = Troupe.Onboard.plan(workspace, [all: args.all] ++ onboard)

      if args.json,
        do: json(plan, args, onboard),
        else: text(plan, args, onboard, Keyword.get(opts, :ask, &ask/1))
    else
      IO.puts(
        :stderr,
        "troupe: cannot onboard #{Paths.display(workspace)}: it is not a directory on this machine"
      )

      2
    end
  end

  ## Text

  defp text(plan, args, onboard, ask) do
    Enum.each(plan.skipped, &IO.puts("skipped: #{&1.source}: #{&1.reason}"))
    Enum.each(plan.refused, &IO.puts("refused: #{refused(&1)}"))

    case plan.proposals do
      [] ->
        IO.puts(nothing(plan))
        status(plan, [])

      proposals ->
        IO.puts("#{count(proposals, "file")} to onboard in #{Paths.display(plan.workspace)}.")

        {results, _mode} =
          Enum.map_reduce(proposals, if(args.yes, do: :yes, else: :ask), fn item, mode ->
            show(item)
            answer(item, mode, plan.workspace, onboard, ask)
          end)

        IO.puts("\n" <> summary(plan, results))
        status(plan, results)
    end
  end

  defp show(item) do
    from = if item.was && item.was != item.proposal.source, do: ", was from #{item.was}", else: ""

    with_also =
      case item.proposal.also_from do
        [] -> ""
        also -> " with " <> Enum.map_join(also, ", ", & &1.source)
      end

    IO.puts("""

    #{item.shown}: #{status_word(item)}, from #{item.proposal.source}#{with_also}#{from}\
    """)

    Enum.each(item.proposal.notes, &IO.puts("  note: " <> &1))
    IO.puts(item.diff)
  end

  defp status_word(%{status: :new}), do: "new"
  defp status_word(%{status: :changed, was: nil}), do: "replaces a file onboarding did not write"
  defp status_word(%{status: :changed}), do: "its source has changed"

  # `:yes` writes, `:ask` asks, `:show` prints what is left once nobody could be asked.
  defp answer(item, :yes, workspace, onboard, _ask), do: {write(item, workspace, onboard), :yes}
  defp answer(_item, :show, _workspace, _onboard, _ask), do: {:unasked, :show}

  defp answer(item, :ask, workspace, onboard, ask) do
    case ask.("Write #{item.shown}? [y/N] ") do
      line when is_binary(line) ->
        if yes?(line),
          do: {write(item, workspace, onboard), :ask},
          else: {decline(item, onboard), :ask}

      # No terminal, or the end of the input: nobody said no, so nothing is remembered.
      _nobody ->
        {:unasked, :show}
    end
  end

  defp write(item, workspace, onboard) do
    case Troupe.Onboard.accept(item, workspace, onboard) do
      {:ok, written} ->
        IO.puts("#{written.action} #{written.shown}")
        :written

      {:error, reason} ->
        IO.puts(:stderr, "not written: #{item.shown}: #{reason}")
        :failed
    end
  end

  defp decline(item, onboard) do
    case Troupe.Onboard.decline(item, onboard) do
      :ok ->
        IO.puts(
          "left out #{item.shown}; not asked about again until #{item.proposal.source} changes"
        )

      {:error, reason} ->
        IO.puts("left out #{item.shown} (not remembered: #{reason})")
    end

    :declined
  end

  defp nothing(%{sources: []}), do: "Nothing to onboard: no source is registered in this build."

  defp nothing(plan) do
    "Nothing to onboard in #{Paths.display(plan.workspace)}" <> passed_over(plan) <> "."
  end

  defp summary(plan, results) do
    written = Enum.count(results, &(&1 == :written))
    declined = Enum.count(results, &(&1 == :declined))
    unasked = Enum.count(results, &(&1 == :unasked))

    line = "#{count(written, "file")} written, #{declined} left out" <> passed_over(plan) <> "."

    if unasked > 0,
      do:
        line <>
          "\nNothing more was written: there is no terminal to ask in. Pass --yes to write " <>
          "them all, or --json to read them.",
      else: line
  end

  # What the plan did not ask about, and why.
  defp passed_over(plan) do
    [
      plan.unchanged > 0 && "#{plan.unchanged} unchanged since onboarded",
      plan.declined > 0 && "#{plan.declined} left out before (--all asks again)"
    ]
    |> Enum.filter(& &1)
    |> case do
      [] -> ""
      parts -> "; " <> Enum.join(parts, ", ")
    end
  end

  defp refused(refusal) do
    what =
      [
        refusal.path && "#{refusal.target}:#{refusal.path}",
        refusal.source && "from #{refusal.source}"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" ")

    if what == "", do: refusal.reason, else: "#{what}: #{refusal.reason}"
  end

  defp status(plan, results) do
    cond do
      plan.refused != [] or :failed in results -> 1
      :unasked in results -> 2
      true -> 0
    end
  end

  ## JSON

  defp json(plan, args, onboard) do
    proposals =
      Enum.map(plan.proposals, fn item ->
        row = %{
          "target" => Atom.to_string(item.proposal.target),
          "path" => item.proposal.path,
          "file" => item.shown,
          "source" => item.proposal.source,
          "source_hash" => item.proposal.source_hash,
          "also_from" =>
            Enum.map(
              item.proposal.also_from,
              &%{"source" => &1.source, "source_hash" => &1.source_hash}
            ),
          "status" => Atom.to_string(item.status),
          "notes" => item.proposal.notes,
          "diff" => item.diff
        }

        if args.yes, do: Map.merge(row, written(item, plan.workspace, onboard)), else: row
      end)

    object = %{
      "workspace" => plan.workspace,
      "sources" => Enum.map(plan.sources, &inspect/1),
      "proposals" => proposals,
      "refused" =>
        Enum.map(plan.refused, fn r ->
          %{
            "target" => r.target && to_string(r.target),
            "path" => r.path,
            "source" => r.source,
            "reason" => r.reason
          }
        end),
      "skipped" => Enum.map(plan.skipped, &%{"source" => &1.source, "reason" => &1.reason}),
      "unchanged" => plan.unchanged,
      "declined" => plan.declined
    }

    IO.write(Jason.encode!(object, pretty: true) <> "\n")

    if plan.refused != [] or Enum.any?(proposals, &(&1["written"] == false)), do: 1, else: 0
  end

  defp written(item, workspace, onboard) do
    case Troupe.Onboard.accept(item, workspace, onboard) do
      {:ok, _written} -> %{"written" => true}
      {:error, reason} -> %{"written" => false, "error" => reason}
    end
  end

  ## Asking

  defp yes?(answer), do: String.downcase(String.trim(answer)) in ["y", "yes"]

  # Asked only at a terminal, as `troupe bench --live` asks (TUI Decision 141): a script
  # says yes with `--yes`, and on Windows the binary's VM has no reader on standard input,
  # so a question there is read key by key (`Troupe.CLI.Prompt`).
  defp ask(question) do
    cond do
      not (Terminal.stdin?() and Terminal.stdout?()) -> :no_terminal
      match?({:win32, _}, :os.type()) -> Prompt.read(question)
      true -> IO.gets(question)
    end
  end

  defp count(n, noun) when is_list(n), do: count(length(n), noun)
  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"
end
