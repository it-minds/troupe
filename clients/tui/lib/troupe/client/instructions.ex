defmodule Troupe.Client.Instructions do
  @moduledoc """
  What `/context` prints (Decision 124): the answer to `context.get` — every file the
  session's next prompt is read from, with its scope and its share of the budget — as
  one notice line, in the order the prompt reads them.

  Paths under the workspace are shown from it; the person's own file, which is not,
  is shown whole. A file the budget cut or left out says so, and so does an alias the
  file hid in its directory, so nobody debugs a `CLAUDE.md` that was never loaded.
  """

  @doc "The line for an answer to `context.get`; `workspace` is `nil` when unknown."
  @spec line(map(), Path.t() | nil) :: String.t()
  def line(%{"files" => files} = answer, workspace) do
    {briefs, instructions} = Enum.split_with(files, &(&1["scope"] == "brief"))

    head =
      case instructions do
        [] ->
          "context: no instruction files in #{length(List.wrap(answer["searched"]))} directories"

        _ ->
          "context: #{number(answer["used"])} of #{number(answer["budget"])} chars"
      end

    Enum.join([head | Enum.map(instructions ++ briefs, &file(&1, workspace))], " · ")
  end

  defp file(%{"scope" => "brief"} = f, workspace) do
    case f["status"] do
      "absent" ->
        "#{show(f["path"], workspace)} (brief) absent"

      "disabled" ->
        "#{show(f["path"], workspace)} (brief) off"

      _ ->
        "#{show(f["path"], workspace)} (brief) #{number(f["chars"])} of #{number(f["budget"])}#{cut(f)}"
    end
  end

  defp file(f, workspace) do
    "#{show(f["path"], workspace)} (#{f["scope"]}) #{number(f["chars"])}#{cut(f)}#{skipped(f)}"
  end

  defp cut(%{"status" => "trimmed", "trimmed" => n}), do: ", #{number(n)} cut"
  defp cut(%{"status" => "dropped"}), do: ", left out"
  defp cut(_file), do: ""

  defp skipped(%{"skipped" => [_ | _] = names}), do: ", #{Enum.join(names, " and ")} skipped"
  defp skipped(_file), do: ""

  defp show(path, nil), do: path

  # Under the workspace, from it; the daemon expands its paths, so expand the workspace
  # too, and on Windows compare without the case the drive letter happens to have.
  defp show(path, workspace) do
    expanded = Path.expand(path)
    prefix = Path.expand(workspace) <> "/"

    if String.starts_with?(fold(expanded), fold(prefix)),
      do: String.slice(expanded, String.length(prefix)..-1//1),
      else: path
  end

  defp fold(path) do
    case :os.type() do
      {:win32, _} -> String.downcase(path)
      _ -> path
    end
  end

  defp number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp number(other), do: to_string(other)
end
