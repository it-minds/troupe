defmodule Troupe.Bench.LiveScenarios do
  @moduledoc """
  The scenarios `troupe bench --live` runs against a real model (Decision 773), in the
  order the report lists them.

  The offline suite's scenarios are about the harness's shape, and a script drives them;
  these are small tasks a model has to do itself, each with an outcome a script checks
  afterwards whoever answered: a file written with given content, a failing test fixed,
  a question delegated and its answer used, a tool that always fails recovered from.
  What each shows is whether the work got done on this provider and model, and what it
  cost, in time and in money. A check beside the outcome says the work was done the way
  the scenario is about (delegated, not read directly; the test fixed, not edited).

  Two suites (Decision 775). `smoke`, the first four, is the cheapest answer to "does it
  work here and what does it cost", and what `troupe bench --live` runs unless told
  otherwise. `standard` adds six that look more like work: a function renamed across the
  files that call it, one written from its documentation, a count found in a log too
  large to read whole, one line changed in a long file, steps followed from a file, and a
  question that needs no tool at all. Each still has an outcome a script checks.
  """

  alias Troupe.Bench.Scenario

  @suites %{
    "smoke" => ~w(write_file fix_test delegate recover),
    "standard" =>
      ~w(write_file fix_test delegate recover rename_symbol implement_spec large_log precise_edit follow_steps answer_only)
  }

  @doc "Every live scenario, in report order."
  @spec all() :: [Scenario.t()]
  def all do
    [
      write_file(),
      fix_test(),
      delegate(),
      recover(),
      rename_symbol(),
      implement_spec(),
      large_log(),
      precise_edit(),
      follow_steps(),
      answer_only()
    ]
  end

  @doc "The suites' names, the default first."
  @spec suites() :: [String.t()]
  def suites, do: ["smoke", "standard"]

  @doc """
  The scenarios of a suite (`nil` for `smoke`), or those named in `names`, in report order:
  a name may be any live scenario's, whichever suite it is in.
  """
  @spec select(String.t() | nil, [String.t()] | nil) ::
          {:ok, [Scenario.t()]} | {:error, String.t()}
  def select(suite, names \\ nil)

  def select(_suite, [_ | _] = names) do
    known = Enum.map(all(), & &1.name)

    case names -- known do
      [] ->
        {:ok, Enum.filter(all(), &(&1.name in names))}

      unknown ->
        {:error,
         "no live scenario is called #{Enum.join(unknown, ", ")}; there are #{Enum.join(known, ", ")}"}
    end
  end

  def select(suite, _names) do
    case Map.fetch(@suites, suite || "smoke") do
      {:ok, names} ->
        {:ok, Enum.filter(all(), &(&1.name in names))}

      :error ->
        {:error, "no live suite is called #{suite}; there are #{Enum.join(suites(), " and ")}"}
    end
  end

  # -- a file with given content ----------------------------------------------------

  # `scripts/live-check task`'s run: the smallest turn that does something.
  defp write_file do
    %Scenario{
      name: "write_file",
      title: "write a file with given content",
      prompt: """
      Create a file named hello.txt in the current directory whose only content is the line: troupe bench ok
      Use write_file once and do nothing else. When the file is written, say so in one short sentence and stop.\
      """,
      outcome: {:file, "hello.txt", "troupe bench ok\n"},
      measure: &nothing/1
    }
  end

  # -- a failing test fixed ---------------------------------------------------------

  @calc """
  defmodule Calc do
    @doc "The sum of a list of numbers."
    def sum(numbers), do: Enum.reduce(numbers, 1, &+/2)
  end
  """

  @calc_test """
  Code.require_file("calc.exs", __DIR__)
  ExUnit.start()

  defmodule CalcTest do
    use ExUnit.Case

    test "sums a list of numbers" do
      assert Calc.sum([1, 2, 3]) == 6
      assert Calc.sum([]) == 0
    end
  end
  """

  # An Elixir test, since `elixir` is what this repository's own tests have; on a machine
  # without it on the PATH the scenario is left out before anything is spent.
  defp fix_test do
    %Scenario{
      name: "fix_test",
      title: "a failing test fixed",
      prompt: """
      calc_test.exs fails. Fix calc.exs so that the test passes, and do not change calc_test.exs.
      The test runs with: elixir calc_test.exs
      When it passes, say so in one short sentence.\
      """,
      files: %{"calc.exs" => @calc, "calc_test.exs" => @calc_test},
      outcome: {:command, ["elixir", "calc_test.exs"]},
      measure: &test_kept/1
    }
  end

  defp test_kept(ctx) do
    kept = File.read(Path.join(ctx.workspace, "calc_test.exs")) == {:ok, @calc_test}
    {[], [{"test_kept", "calc_test.exs was left as it was", kept}]}
  end

  # -- a question delegated ---------------------------------------------------------

  # `scripts/live-check delegate`'s run, with the answer used rather than only said.
  defp delegate do
    %Scenario{
      name: "delegate",
      title: "a question delegated and its answer used",
      prompt: """
      The notes/ directory holds a few short text files. Find out what the lighthouse keeper's cat is called.
      Do not read, list or search any file yourself: call the delegate tool exactly once, with agent "explore" and a task asking it to find the cat's name in notes/.
      When it reports back, write the cat's name and nothing else to answer.txt with write_file, then say the name in one sentence.\
      """,
      files: %{
        "notes/harbour.txt" =>
          "The harbour opens at six and closes at dusk. Boats moor on the east quay.\n",
        "notes/keeper.txt" =>
          "The lighthouse keeper is Ines Varga. Her cat is called Pemberton and sleeps by the lamp.\n",
        "notes/supplies.txt" => "Oil, wicks and biscuits arrive every second Tuesday.\n"
      },
      outcome: {:file, "answer.txt", "Pemberton\n"},
      measure: &delegated/1
    }
  end

  defp delegated(ctx) do
    delegated =
      Enum.any?(
        ctx.events,
        &(&1.type == "tool_call_started" and &1.agent == ["root"] and
            &1.data["name"] == "delegate")
      )

    {[], [{"delegated", "the root agent called delegate", delegated}]}
  end

  # -- a tool that always fails ------------------------------------------------------

  # The file the prompt names is never there, so every read of it fails, however often it
  # is tried; the way out is the default the prompt gives.
  defp recover do
    %Scenario{
      name: "recover",
      title: "a tool that always fails, recovered from",
      prompt: """
      Read settings/port.txt with read_file to find the port the service listens on. If it cannot be read, the port is 8080.
      Write the port and nothing else to port.txt with write_file, then say which port you wrote.\
      """,
      files: %{"settings/README.txt" => "The service's settings.\n"},
      outcome: {:file, "port.txt", "8080\n"},
      measure: &failed_and_went_on/1
    }
  end

  defp failed_and_went_on(ctx) do
    failed =
      Enum.any?(
        ctx.events,
        &(&1.type == "tool_call_completed" and &1.data["name"] == "read_file" and
            &1.data["ok"] == false)
      )

    {[], [{"failed", "read_file failed, as it always does", failed}]}
  end

  # -- a function renamed where it is called -----------------------------------------

  @cart ~S"""
  defmodule Shop.Cart do
    @moduledoc "A cart's lines and what they come to, in cents."

    @doc "What one line costs: its unit price times its quantity."
    def line_total(%{price: price, quantity: quantity}), do: price * quantity

    @doc "What the whole cart comes to."
    def total(lines), do: lines |> Enum.map(&line_total/1) |> Enum.sum()
  end
  """

  @receipt ~S"""
  defmodule Shop.Receipt do
    @moduledoc "A receipt: a line of text for each line of the cart, and the total last."

    @doc "One line of the receipt: what was bought, and what it came to."
    def line(%{name: name} = line), do: "#{name}: #{Shop.Cart.line_total(line)}"

    @doc "Every line, then the total."
    def lines(lines), do: Enum.map(lines, &line/1) ++ ["total: #{Shop.Cart.total(lines)}"]
  end
  """

  @discount ~S"""
  defmodule Shop.Discount do
    @moduledoc "Discounts, in cents and rounded down."

    @doc "What a line comes to with a percentage off."
    def off(line, percent), do: div(Shop.Cart.line_total(line) * (100 - percent), 100)
  end
  """

  @shop_test ~S"""
  for file <- ~w(lib/cart.exs lib/receipt.exs lib/discount.exs) do
    Code.require_file(file, __DIR__)
  end

  ExUnit.start()

  defmodule ShopTest do
    use ExUnit.Case

    @lines [%{name: "tea", price: 250, quantity: 2}, %{name: "cake", price: 400, quantity: 1}]

    test "a line's subtotal" do
      assert Shop.Cart.subtotal(hd(@lines)) == 500
    end

    test "the receipt and the discount use it" do
      assert Shop.Receipt.lines(@lines) == ["tea: 500", "cake: 400", "total: 900"]
      assert Shop.Discount.off(hd(@lines), 10) == 450
    end

    test "the old name is gone" do
      refute function_exported?(Shop.Cart, :line_total, 1)
    end
  end
  """

  @shop_files ~w(lib/cart.exs lib/receipt.exs lib/discount.exs)

  # One function and its three callers in two other files: the edit a rename is, which no
  # single file read shows the whole of.
  defp rename_symbol do
    %Scenario{
      name: "rename_symbol",
      title: "a function renamed, and every place that calls it",
      prompt: """
      Rename the function Shop.Cart.line_total/1 to Shop.Cart.subtotal/1, in lib/cart.exs and everywhere it is called. Do not change shop_test.exs.
      The tests run with: elixir shop_test.exs
      When they pass, say so in one short sentence.\
      """,
      files: %{
        "lib/cart.exs" => @cart,
        "lib/receipt.exs" => @receipt,
        "lib/discount.exs" => @discount,
        "shop_test.exs" => @shop_test
      },
      outcome: {:command, ["elixir", "shop_test.exs"]},
      measure: &renamed/1
    }
  end

  defp renamed(ctx) do
    left =
      Enum.any?(@shop_files, fn file ->
        case File.read(Path.join(ctx.workspace, file)) do
          {:ok, text} -> text =~ "line_total"
          {:error, _reason} -> false
        end
      end)

    {[],
     [
       {"old_name_gone", "line_total is left in no file of lib/", not left},
       {"test_kept", "shop_test.exs was left as it was",
        Scenario.holds?(ctx.workspace, "shop_test.exs", @shop_test)}
     ]}
  end

  # -- a function written from its documentation -------------------------------------

  @roman ~S'''
  defmodule Roman do
    @doc """
    The Roman numeral for a whole number from 1 to 3999, in capitals, with the subtractive
    forms: 4 is IV, 9 is IX, 40 is XL, 90 is XC, 400 is CD and 900 is CM.
    """
    def encode(_number) do
      raise "not written yet"
    end
  end
  '''

  @roman_test ~S"""
  Code.require_file("roman.exs", __DIR__)
  ExUnit.start()

  defmodule RomanTest do
    use ExUnit.Case

    test "the numerals" do
      for {number, numeral} <- [
            {1, "I"},
            {3, "III"},
            {4, "IV"},
            {9, "IX"},
            {14, "XIV"},
            {40, "XL"},
            {90, "XC"},
            {400, "CD"},
            {1994, "MCMXCIV"},
            {2026, "MMXXVI"},
            {3999, "MMMCMXCIX"}
          ] do
        assert Roman.encode(number) == numeral, "#{number}"
      end
    end
  end
  """

  defp implement_spec do
    %Scenario{
      name: "implement_spec",
      title: "a function written from its documentation",
      prompt: """
      roman.exs has a function, Roman.encode/1, that is not written yet; its documentation says what it must do. Write it so that roman_test.exs passes, and do not change roman_test.exs.
      The test runs with: elixir roman_test.exs
      When it passes, say so in one short sentence.\
      """,
      files: %{"roman.exs" => @roman, "roman_test.exs" => @roman_test},
      outcome: {:command, ["elixir", "roman_test.exs"]},
      measure: fn ctx ->
        {[],
         [
           {"test_kept", "roman_test.exs was left as it was",
            Scenario.holds?(ctx.workspace, "roman_test.exs", @roman_test)}
         ]}
      end
    }
  end

  # -- a count in a log too large to read whole ---------------------------------------

  @log_lines 6_000

  @doc """
  The log `large_log` asks about: #{@log_lines} lines, about 480 kB, more than a read
  returns at `tool_output_limit`'s default. A line every 113th is an `ERROR` with the code
  `E1042`, every 89th a `WARN` with the same code, every 71st an `ERROR` with another, so
  neither the level nor the code alone counts the right lines: 53 do.
  """
  @spec service_log() :: String.t()
  def service_log do
    Enum.map_join(1..@log_lines, fn i ->
      at = "2026-10-04T#{pad(12 + div(i, 3600))}:#{pad(rem(div(i, 60), 60))}:#{pad(rem(i, 60))}.000Z"
      req = "req=r" <> String.pad_leading(Integer.to_string(i), 5, "0")

      cond do
        rem(i, 113) == 0 -> "#{at} ERROR code=E1042 #{req} upstream timed out after 5000 ms\n"
        rem(i, 89) == 0 -> "#{at} WARN  code=E1042 #{req} upstream slow, retrying\n"
        rem(i, 71) == 0 -> "#{at} ERROR code=E2001 #{req} payload rejected by the validator\n"
        true -> "#{at} INFO  #{req} GET /api/items/#{rem(i * 7919, 10_000)} status=200 ms=#{rem(i * 31, 250) + 3}\n"
      end
    end)
  end

  # What a run costs when the input is larger than one read: the measure to watch is the
  # largest tool result a run carried (Decision 775), not only whether the count is right.
  defp large_log do
    %Scenario{
      name: "large_log",
      title: "a count found in a log too large to read whole",
      prompt: """
      logs/service.log is the log of a busy service. How many of its lines have the level ERROR and the code E1042?
      Write the number and nothing else to answer.txt with write_file, then say the number in one sentence.\
      """,
      files: %{"logs/service.log" => service_log()},
      outcome: {:file, "answer.txt", "53\n"},
      measure: &nothing/1
    }
  end

  # -- one line of a long file changed ------------------------------------------------

  @doc """
  The file `precise_edit` changes: sixty sections of 23 settings each, about 1,560 lines.
  `[database]` has `max_connections = <n>`; `[cache]` has a `max_connections = 100` too,
  so the line alone does not say which to change.
  """
  @spec settings_conf(pos_integer()) :: String.t()
  def settings_conf(database_connections) do
    Enum.map_join(1..60, "\n", fn n ->
      {name, keys} =
        case n do
          20 ->
            {"cache", [{"max_connections", "100"}, {"eviction", "lru"}]}

          48 ->
            {"database",
             [
               {"max_connections", Integer.to_string(database_connections)},
               {"statement_timeout_ms", "30000"}
             ]}

          _other ->
            {"service_#{pad(n)}", []}
        end

      filler = for k <- 1..(23 - length(keys)), do: {"option_#{pad(k)}", "#{rem(n * 37 + k * 11, 997)}"}

      Enum.join(
        ["# settings for #{name}", "[#{name}]" | Enum.map(keys ++ filler, fn {k, v} -> "#{k} = #{v}" end)],
        "\n"
      ) <> "\n"
    end)
  end

  defp precise_edit do
    %Scenario{
      name: "precise_edit",
      title: "one line of a long file changed, and nothing else",
      prompt: """
      settings.conf is long. In its [database] section, change max_connections from 100 to 250. Change nothing else in the file.
      Say when it is done in one short sentence.\
      """,
      files: %{"settings.conf" => settings_conf(100)},
      outcome: {:file, "settings.conf", settings_conf(250)},
      measure: &edited_in_place/1
    }
  end

  # Writing the file whole to change one line is a turn's output spent on what was already
  # there; the check says which way it was done.
  defp edited_in_place(ctx) do
    rewritten =
      Enum.any?(
        ctx.events,
        &(&1.type == "tool_call_started" and &1.data["name"] == "write_file" and
            get_in(&1.data, ["args", "path"]) in ["settings.conf", "./settings.conf"])
      )

    {[], [{"in_place", "settings.conf was edited in place, not written whole", not rewritten}]}
  end

  # -- steps followed from a file -----------------------------------------------------

  @task """
  # What to do

  1. Create out/greeting.txt holding exactly this line: hello from the bench
  2. In config.ini, change mode from draft to final, and leave every other line as it is.
  3. Create out/done.txt listing the two files you created or changed, one per line, in the order of the steps above.
  """

  @config_ini "[app]\nname = bench\nmode = draft\nretries = 3\n"

  defp follow_steps do
    %Scenario{
      name: "follow_steps",
      title: "steps followed from a file in the workspace",
      prompt: """
      Do what TASK.md says, one step after another. When every step is done, say so in one short sentence.\
      """,
      files: %{"TASK.md" => @task, "config.ini" => @config_ini},
      outcome: {:file, "out/done.txt", "out/greeting.txt\nconfig.ini\n"},
      measure: fn ctx ->
        {[],
         [
           {"greeting", "out/greeting.txt holds its line",
            Scenario.holds?(ctx.workspace, "out/greeting.txt", "hello from the bench\n")},
           {"config", "config.ini says mode = final, and nothing else changed",
            Scenario.holds?(ctx.workspace, "config.ini", String.replace(@config_ini, "draft", "final"))}
         ]}
      end
    }
  end

  # -- a question that needs no tool --------------------------------------------------

  # The least a turn can cost here: one call, which still carries the system prompt and
  # every tool's definition.
  defp answer_only do
    %Scenario{
      name: "answer_only",
      title: "a question answered without a tool",
      prompt: "Answer without using any tool: what is 17 times 23? Reply with the number alone.",
      measure: fn ctx ->
        {[],
         [
           {"answer", "the reply is 391", reply(ctx) =~ ~r/\b391\b/},
           {"no_tools", "no tool was called",
            not Enum.any?(ctx.events, &(&1.type == "tool_call_started"))}
         ]}
      end
    }
  end

  # The root agent's last reply, as text.
  defp reply(ctx) do
    ctx.events
    |> Enum.filter(&(&1.type == "llm_response" and &1.agent == ["root"]))
    |> List.last()
    |> case do
      nil ->
        ""

      event ->
        (get_in(event.data, ["message", "content"]) || [])
        |> Enum.filter(&match?(%{"type" => "text"}, &1))
        |> Enum.map_join("\n", & &1["text"])
    end
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp nothing(_ctx), do: {[], []}
end
