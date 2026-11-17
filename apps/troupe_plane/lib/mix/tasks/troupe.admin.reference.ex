defmodule Mix.Tasks.Troupe.Admin.Reference do
  @shortdoc "Write PROTOCOL.md's admin method table from the admin API's methods"

  @moduledoc """
  Write the admin method table in `PROTOCOL.md` section 9 from `Troupe.Plane.Admin.API`.

      mix troupe.admin.reference
      mix troupe.admin.reference --check

  The table is the part of the page between `<!-- admin-methods:begin -->` and
  `<!-- admin-methods:end -->`: one row per method, sorted by name, with the role the
  method answers, its risk (and, for a destructive one, the argument an MCP caller echoes
  as `confirm`), the arguments it takes with their types (`?` for an optional one) and its
  summary. The rest of the section, what no method declares, is written by hand.

  These are the declarations `/rpc` dispatches with and the admin MCP server describes its
  tools from, so the page says what a caller is actually held to. `--check` fails when the
  committed table is not what the methods render, and CI runs it.

  `--page` names another file, for the task's own tests.
  """

  use Mix.Task

  alias Troupe.Plane.Admin.API
  alias Troupe.Plane.Admin.API.{Argument, Method}

  @requirements ["app.config"]

  @begin "<!-- admin-methods:begin -->"
  @finish "<!-- admin-methods:end -->"

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [check: :boolean, page: :string])
    path = opts[:page] || Path.join(repository_root(), "PROTOCOL.md")
    page = File.read!(path)
    expected = splice(page, render(API.list()))

    cond do
      opts[:check] != true ->
        File.write!(path, expected)
        Mix.shell().info("wrote the admin method table in #{path}")

      expected == page ->
        Mix.shell().info("the admin method table in #{path} is current")

      true ->
        Mix.raise("stale: the admin method table in #{path} -- run `mix troupe.admin.reference` and commit the result")
    end
  end

  @doc "The table the methods render, header included."
  @spec render([Method.t()]) :: String.t()
  def render(methods) do
    rows =
      methods
      |> Enum.sort_by(& &1.name)
      |> Enum.map(&row/1)

    Enum.join(["| method | role | risk | takes | what it does |", "| --- | --- | --- | --- | --- |" | rows], "\n") <>
      "\n"
  end

  @doc "The page with the part between the markers replaced by `table`."
  @spec splice(String.t(), String.t()) :: String.t()
  def splice(page, table) do
    case String.split(page, [@begin, @finish]) do
      [head, _old, tail] -> head <> @begin <> "\n" <> table <> @finish <> tail
      _ -> Mix.raise("the page needs #{@begin} and #{@finish} around the admin method table, once each")
    end
  end

  defp row(%Method{} = method) do
    cells = [
      "`#{method.name}`",
      role(method.role),
      risk(method),
      "`#{takes(method.arguments)}`",
      prose(method.summary)
    ]

    "| " <> Enum.join(cells, " | ") <> " |"
  end

  defp role(:platform_admin), do: "platform"
  defp role(:admin), do: "either"

  defp risk(%Method{risk: :destructive, confirm: field}) when is_binary(field),
    do: "destructive, confirm `#{field}`"

  defp risk(%Method{risk: risk}), do: Atom.to_string(risk)

  defp takes(arguments), do: "{" <> Enum.map_join(arguments, ", ", &argument/1) <> "}"

  defp argument(%Argument{} = argument) do
    name = if argument.required, do: argument.name, else: argument.name <> "?"
    name <> ": " <> type(argument)
  end

  defp type(%Argument{type: :object, properties: [_ | _] = properties}), do: takes(properties)
  defp type(%Argument{values: [_ | _] = values}), do: Enum.join(values, "/")
  defp type(%Argument{type: type}), do: Atom.to_string(type)

  # A summary is plain text written for a model to read; in a table cell it must not open
  # a tag, start emphasis or end the cell. Inside a code span only the pipe matters.
  defp prose(text) do
    text
    |> String.split("`")
    |> Enum.with_index()
    |> Enum.map_join("`", fn
      {part, index} when rem(index, 2) == 1 -> String.replace(part, "|", "\\|")
      {part, _index} -> escape(part)
    end)
  end

  defp escape(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("|", "\\|")
    |> String.replace("*", "\\*")
    |> String.replace("<", "&lt;")
  end

  # Tasks run from the umbrella root or from an app directory, so the root is found
  # rather than assumed.
  defp repository_root, do: Path.expand(Path.join(Mix.Project.build_path(), "../.."))
end
