defmodule Troupe.ConsolePathsTest do
  @moduledoc """
  Every place on the plane's console a client names is one the console has (#768, #894).

  A client sends a person to the console as `Group → Area`, the way the console's map
  (`clients/gui/apps/console/src/nav.ts`, the list `views/Shell.tsx` draws its rail from)
  groups its areas. The map is read from the console's own source, which the repository
  holds beside this client, so the two cannot drift apart unseen.

  `troupe config pull` named a `Policy` page the console no longer had, and then a panel of
  a page that did not hold what it named; this reads every `A → B` in the clients' and the
  daemon's code whose first word is a word of the map, and holds it to a group and one of
  that group's areas, and to nothing finer: a sentence names the page, never a panel on it.
  An arrow between other words (another product's menus) is left alone there.

  In the terminal's own code it is stricter, over the strings as the program says them
  (the pieces of a sentence joined, the documentation left out): every `A → B` is a console
  place, and a sentence that sends somebody to the console names the page. A page only an
  administrator has is said as an administrator's, so a member reading it knows to ask one.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @nav Path.join(@root, "clients/gui/apps/console/src/nav.ts")
  @tui Path.join(@root, "clients/tui/lib")
  @sources [
    "clients/tui/lib",
    "clients/gui/apps/desktop/src",
    "clients/gui/packages/client/src",
    "apps/troupe_core/lib",
    "apps/troupe_gateway/lib",
    "apps/troupe_daemon/lib"
  ]

  # `Group → Area`: a capitalised phrase, the arrow, and what follows it.
  @path ~r/([A-Z][\w-]*(?: [a-z][\w-]*)*) → ([A-Z][\w' -]*)/u

  # A sentence that sends its reader to the plane's console.
  @to_console ~r/\bthe console\b|\bconsole's\b/

  # The group every person has; every other group is an administrator's.
  @everyone "Mine"

  test "every console place a client names is a group of the console's map and one of its areas" do
    groups = nav()
    words = vocabulary(groups)

    named =
      for file <- sources(),
          [_whole, first, rest] <- Regex.scan(@path, File.read!(file)),
          MapSet.member?(words, first |> String.split(" ") |> hd()),
          do: {Path.relative_to(file, @root), first, rest}

    assert named != [], "no console place found; the pattern or the sources moved"

    for {file, group, rest} <- named do
      areas = Map.get(groups, group)

      assert areas,
             "#{file} names #{inspect(group <> " → " <> rest)}: #{group} is no group of the console"

      assert area_of(areas, rest),
             "#{file} names #{inspect(group <> " → " <> rest)}: #{group} has #{Enum.join(areas, ", ")}"
    end
  end

  test "a console place is named as Group → Area and nothing under it, no panel of a page" do
    groups = nav()
    words = vocabulary(groups)

    for file <- sources(),
        text = File.read!(file),
        [_whole, {group_at, group_len}, {rest_at, rest_len}] <-
          Regex.scan(@path, text, return: :index),
        group = binary_part(text, group_at, group_len),
        MapSet.member?(words, group |> String.split(" ") |> hd()),
        area = area_of(Map.get(groups, group, []), binary_part(text, rest_at, rest_len)) do
      from = rest_at + byte_size(area)
      # The rest of the sentence, to its end or the end of its string.
      tail =
        text
        |> binary_part(from, byte_size(text) - from)
        |> String.split(~r/["`.\n]/, parts: 2)
        |> hd()

      refute tail =~ ~r/\bpanels?\b|→/u,
             "#{Path.relative_to(file, @root)} names #{inspect(group <> " → " <> area <> tail)}: " <>
               "a sentence names the console's Group → Area, not a part of the page"
    end
  end

  test "the terminal's every A → B is a console place, and a sentence to the console names one" do
    groups = nav()
    said = tui_strings()

    assert Enum.any?(said, fn {_file, s} -> s =~ @to_console end),
           "no sentence sends anybody to the console; the reading of the strings moved"

    for {file, s} <- said do
      places =
        for [_whole, group, rest] <- Regex.scan(~r/([A-Z][\w-]*) → ([A-Z][\w' -]*)/u, s) do
          areas = Map.get(groups, group)

          assert areas && area_of(areas, rest),
                 "#{file} says #{inspect(s)}: #{group} → #{rest} is no place on the console, " <>
                   "whose groups are #{groups |> Map.keys() |> Enum.join(", ")}"

          group
        end

      if s =~ @to_console do
        assert places != [],
               "#{file} says #{inspect(s)}: a sentence that sends somebody to the console names " <>
                 "the page, as Group → Area"
      end

      if Enum.any?(places, &(&1 != @everyone)) do
        assert s =~ "administrator",
               "#{file} says #{inspect(s)}: the page is an administrator's, so the sentence says " <>
                 "so, and a member reading it knows to ask one"
      end
    end
  end

  # The longest of a group's areas the words after the arrow start with, whole.
  defp area_of(areas, rest) do
    areas
    |> Enum.filter(&(String.starts_with?(rest, &1) and not word_goes_on?(rest, &1)))
    |> Enum.max_by(&String.length/1, fn -> nil end)
  end

  defp word_goes_on?(rest, area),
    do: String.slice(rest, String.length(area), 1) =~ ~r/^[\w]$/u

  # The map's groups and their areas' labels, read from the file as it is written.
  defp nav do
    text = File.read!(@nav)

    for [_whole, group, areas] <- Regex.scan(~r/label: "(\w+)",\s*areas: \[(.*?)\]/s, text),
        into: %{} do
      {group, for([_whole, label] <- Regex.scan(~r/label: "([^"]+)"/, areas), do: label)}
    end
  end

  # A group, or the first word of an area's label: what marks an arrow as the console's.
  defp vocabulary(groups) do
    areas = groups |> Map.values() |> List.flatten() |> Enum.map(&(&1 |> String.split(" ") |> hd()))
    MapSet.new(Map.keys(groups) ++ areas)
  end

  defp sources do
    for dir <- @sources,
        file <- Path.wildcard(Path.join([@root, dir, "**", "*.{ex,ts,tsx}"])),
        do: file
  end

  # Every string the terminal's code says, as it says it: a sentence built of pieces joined
  # with `<>` read whole, an interpolation as `…`, and the documentation left out.
  defp tui_strings do
    for file <- Path.wildcard(Path.join([@tui, "**", "*.ex"])),
        s <- file |> File.read!() |> Code.string_to_quoted!() |> strings(),
        do: {Path.relative_to(file, @root), s}
  end

  defp strings(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{doc, _, _}]}, acc when doc in [:moduledoc, :doc, :typedoc] -> {:ok, acc}
        {:<>, _, [_, _]} = node, acc -> {:ok, [fold(node) | acc]}
        {:<<>>, _, _} = node, acc -> {:ok, [fold(node) | acc]}
        s, acc when is_binary(s) -> {s, [s | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(found)
  end

  defp fold(s) when is_binary(s), do: s
  defp fold({:<>, _, [a, b]}), do: fold(a) <> fold(b)
  defp fold({:<<>>, _, parts}), do: Enum.map_join(parts, &fold/1)
  defp fold(_other), do: "…"
end
