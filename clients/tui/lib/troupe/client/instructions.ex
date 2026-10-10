defmodule Troupe.Client.Instructions do
  @moduledoc """
  What `/context` prints (Decision 124): the answer to `context.get` — every file the
  session's next prompt is read from, with its scope and its share of the budget — as
  one notice line, in the order the prompt reads them.

  Paths under the workspace are shown from it; the person's own file, which is not,
  is shown whole. A file the budget cut or left out says so, and so does another tool's
  file the daemon does not read, so nobody debugs a `CLAUDE.md` that was never loaded.
  Every file left out says why in words (Decision 148): the `reason` `context.get` gives
  it (outside the repository, another tool's file waiting for `troupe onboard`, a
  Copilot file below the root, one that cannot be read, the budget; root Decision 828),
  and each import that was not followed, after the file that names it. A rule in
  `.troupe/rules` says why it applies, as `context.get`'s `applies` puts it, or why it
  does not, as its `reason` does (root Decisions 809 and 828).
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

    Enum.join([head | Enum.flat_map(instructions ++ briefs, &file(&1, workspace))], " · ")
  end

  defp file(f, workspace), do: [entry(f, workspace) | unfollowed(f)]

  # A file left out says why, in `context.get`'s words; an older daemon's answer has no
  # `reason`, and its line is as it was.
  defp entry(%{"reason" => reason} = f, workspace) when is_binary(reason),
    do: "#{show(f["path"], workspace)} (#{f["scope"]}) #{reason}"

  defp entry(%{"scope" => "brief"} = f, workspace) do
    case f["status"] do
      "absent" ->
        "#{show(f["path"], workspace)} (brief) absent"

      "disabled" ->
        "#{show(f["path"], workspace)} (brief) off"

      _ ->
        "#{show(f["path"], workspace)} (brief) #{number(f["chars"])} of #{number(f["budget"])}#{cut(f)}"
    end
  end

  defp entry(f, workspace) do
    "#{show(f["path"], workspace)} (#{f["scope"]}) #{number(f["chars"])}#{cut(f)}#{skipped(f)}" <>
      applies(f)
  end

  # A Cursor rule in the prompt, and why: `always applied`, or the file a glob matched.
  defp applies(%{"applies" => applies}) when is_binary(applies), do: ", #{applies}"
  defp applies(_file), do: ""

  defp cut(%{"status" => "trimmed", "trimmed" => n}), do: ", #{number(n)} cut"
  defp cut(%{"status" => "dropped"}), do: ", left out"
  defp cut(_file), do: ""

  # A daemon that gives a `reason` lists each alias a file hid on its own, saying why; an
  # older one names them only here.
  defp skipped(%{"reason" => _}), do: ""
  defp skipped(%{"skipped" => [_ | _] = names}), do: ", #{Enum.join(names, " and ")} skipped"
  defp skipped(_file), do: ""

  # Each import the file names that was not read, as the file wrote it, after the file.
  defp unfollowed(%{"unfollowed" => [_ | _] = imports} = f) do
    for %{"import" => spec, "reason" => reason} <- imports,
        do: "@#{spec} (#{f["scope"]}) import not followed: #{why(reason, f["scope"])}"
  end

  defp unfollowed(_file), do: []

  defp why("missing", _scope), do: "missing"
  defp why("depth", _scope), do: "too deep"
  defp why("cycle", _scope), do: "a cycle"
  defp why("outside", "user"), do: "outside the config directory"
  defp why("outside", _scope), do: "outside the repository"
  defp why(other, _scope), do: to_string(other)

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
