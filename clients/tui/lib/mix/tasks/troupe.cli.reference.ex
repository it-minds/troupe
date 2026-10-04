defmodule Mix.Tasks.Troupe.Cli.Reference do
  @shortdoc "Write the command reference from the command-line table and the harness's"

  @moduledoc """
  Write the two generated parts of `docs/user/cli-reference.md`: the command lines
  `troupe` takes, from `Troupe.CLI.commands/0`, and the built-in commands typed inside a
  session, from the harness's `Troupe.Commands`.

      mix troupe.cli.reference
      mix troupe.cli.reference --check

  `troupe --help` prints the same two tables (`Troupe.CLI.help/0`), so the page and the
  help cannot disagree, and neither can say what the code does not do: the slash commands
  are the table `commands.list` serves both clients, and the TUI's suite holds the
  command-line table to the parser (root Decision 767). `--check` (in `mix check`, which
  CI runs) fails when the page is not what the tables say.

  Each part sits between its markers, `<!-- cli-commands:begin -->` and
  `<!-- slash-commands:begin -->` with their `:end`; the rest of the page is written by
  hand.
  """

  use Mix.Task

  alias Troupe.CLI

  @requirements ["compile"]

  @page Path.join(~w(.. .. docs user cli-reference.md))

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [check: :boolean])
    page = File.read!(@page)
    if opts[:check], do: check(page, render(page)), else: write(render(page))
  end

  defp write(page) do
    File.write!(@page, page)
    Mix.shell().info("wrote the command reference in #{@page}")
  end

  defp check(page, page), do: Mix.shell().info("#{@page} is current")

  defp check(_stale, _page),
    do: Mix.raise("#{@page} is stale: run `mix troupe.cli.reference` in clients/tui and commit it")

  @doc "A page with both generated parts what the tables say, and the rest as it was."
  @spec render(String.t()) :: String.t()
  def render(page) do
    page
    |> region("cli-commands", cli_commands())
    |> region("slash-commands", slash_commands())
  end

  defp cli_commands do
    rows = for {usage, what, _argv} <- CLI.commands(), do: [code(usage), prose(what)]
    table(["command", "what it does"], rows)
  end

  # One table per section, in the palette's order; the agents and the commands files
  # define are a session's own, so the hand-written text after the part says so.
  defp slash_commands do
    Troupe.Commands.builtins()
    |> Enum.chunk_by(& &1["section"])
    |> Enum.map_join("\n", fn [%{"section" => section} | _] = entries ->
      "### #{String.capitalize(section)}\n\n" <>
        table(["command", "what it does", "needs"], Enum.map(entries, &slash_row/1))
    end)
  end

  defp slash_row(entry) do
    names =
      Enum.map_join([entry["usage"] | Enum.map(entry["aliases"], &("/" <> &1))], ", ", &code/1)

    what =
      if entry["detail"] == entry["summary"],
        do: prose(entry["summary"] <> "."),
        else: prose("#{entry["summary"]}. #{entry["detail"]}")

    example = if entry["example"], do: " For example #{code(entry["example"])}.", else: ""
    [names, what <> example, needs(entry["availability"])]
  end

  # What `availability` asks of the session, in the palette's words.
  defp needs("always"), do: ""
  defp needs("window"), do: "a window: the activated one, or one named"
  defp needs("local"), do: "a session on this machine"
  defp needs("plane"), do: "a plane"
  defp needs(other), do: other

  defp table(header, rows) do
    lines = [header, Enum.map(header, fn _ -> "---" end) | rows]
    Enum.map_join(lines, "", &("| " <> Enum.join(&1, " | ") <> " |\n"))
  end

  # A pipe ends a table cell even inside a code span on GitHub, and `<name>` in prose is
  # an HTML tag to a Markdown renderer.
  defp code(text), do: "`" <> String.replace(text, "|", "\\|") <> "`"

  defp prose(text) do
    text
    |> String.replace("|", "\\|")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp region(page, name, content) do
    {first, last} = {"<!-- #{name}:begin -->", "<!-- #{name}:end -->"}

    case String.split(page, [first, last]) do
      [head, _old, tail] -> head <> first <> "\n" <> content <> last <> tail
      _ -> Mix.raise("#{@page} needs #{first} and #{last} around its generated part")
    end
  end
end
