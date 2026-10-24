defmodule Troupe.ConsolePathsTest do
  @moduledoc """
  Every place on the plane's console a client names is one the console has (#768).

  A client sends a person to the console as `Group → Area`, the way the console's map
  (`clients/gui/apps/console/src/nav.ts`) groups its areas. `troupe config pull` named a
  `Policy` page the console no longer had; this reads every `A → B` in the clients' and the
  daemon's code whose first word is a word of the map, and holds it to a group and one of
  that group's areas. An arrow between other words (another product's menus) is left alone.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @nav Path.join(@root, "clients/gui/apps/console/src/nav.ts")
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

      assert Enum.any?(areas, &String.starts_with?(rest, &1)),
             "#{file} names #{inspect(group <> " → " <> rest)}: #{group} has #{Enum.join(areas, ", ")}"
    end
  end

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
end
