defmodule Troupe.LinesTest do
  use ExUnit.Case, async: true

  alias Troupe.UI.Lines

  # Written by `pnpm lines` from the TypeScript reader the desktop app and the console use.
  @fixture Path.join(~w(.. gui docs design lines.order.json))

  test "the same seed gives the same order here as in the desktop app and the console" do
    %{"seeds" => seeds} = @fixture |> File.read!() |> Jason.decode!()
    assert map_size(seeds) >= 4

    for {seed, kinds} <- seeds, {kind, order} <- kinds do
      assert Lines.order(String.to_existing_atom(kind), seed) == order,
             "#{kind} for seed #{inspect(seed)} is taken in another order than the fixture's"
    end
  end

  test "the fixture covers every kind the file has" do
    %{"seeds" => seeds} = @fixture |> File.read!() |> Jason.decode!()
    covered = seeds |> Map.values() |> hd() |> Map.keys() |> Enum.sort()
    assert covered == Lines.kinds() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
  end

  test "an order is each line once, and past the end there is no line" do
    for kind <- Lines.kinds() do
      count = length(Lines.all(kind))
      assert Enum.sort(Lines.order(kind, "turn-1")) == Enum.to_list(0..(count - 1))
      assert Lines.pick(kind, "turn-1", count) != nil
      assert Lines.pick(kind, "turn-1", count + 1) == nil
    end
  end

  test "two turns do not open the same way, and a turn never repeats a line" do
    openings = for n <- 1..20, do: Lines.pick(:thinking, "s/#{n}", 1)
    assert length(Enum.uniq(openings)) > 5

    taken = for n <- 1..length(Lines.all(:thinking)), do: Lines.pick(:thinking, "s/1", n)
    assert taken == Enum.uniq(taken)
  end

  test "every line is in the register: no exclamation mark, no emoji, a fragment where it is one" do
    for kind <- Lines.kinds(), line <- Lines.all(kind) do
      refute line =~ "!", "#{kind}: #{line}"
      refute line =~ ~r/\p{So}/u, "#{kind}: #{line}"
      assert line == String.trim(line)

      if kind not in [:start_screen, :curtain_up] do
        assert line == String.downcase(line), "#{kind}: #{line} is not a lower-case fragment"
        refute String.ends_with?(line, "."), "#{kind}: #{line}"
      end
    end
  end

  test "the lines that share a footer with its keys leave it room in 80 columns" do
    for kind <- [:casting, :waiting_for_a_place], line <- Lines.all(kind) do
      assert String.length(line) <= 26, "#{kind}: #{line}"
    end
  end

  test "the lists have the sizes the design asks for" do
    for kind <- [:thinking, :reading, :acting], do: assert(length(Lines.all(kind)) in 20..30)

    for kind <- [:casting, :starting, :compacting, :long_turn, :loading],
        do: assert(length(Lines.all(kind)) in 10..15)

    for kind <- [:daemon_starting, :signing_in, :checking_for_an_update, :first_run],
        do: assert(length(Lines.all(kind)) in 5..10)
  end
end
