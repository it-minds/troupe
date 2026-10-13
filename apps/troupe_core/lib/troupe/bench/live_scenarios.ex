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

  `follow_up` is in neither suite, and runs when it is named (`--scenario follow_up`): two
  turns, the second under an instruction file the first brought into the session, which
  is what changes a prompt between turns and what issue #465's two options are measured
  on (Decision 815). `task_list`, in neither suite either, is that issue's other change:
  three turns on the `plan` agent, each after the first beginning with the task list the
  turn before left. `long_turn`, also by name, is one turn of thirteen calls on `build`
  with no list, where the task list's tools were offered from the eleventh (issue #590,
  Decision 867). `loop_turn`, by name, is a `/loop` turn and then a person's turn in the
  same session, where `goal_complete` was offered on the loop's turn alone (issue #606,
  Decision 871). `scratchpad` and `scratchpad_without`, by name too, are one migration plan
  with the scratchpad and without it (issue #472, Decision 870), and
  `scratchpad_session` and `scratchpad_session_without` a session of eight turns that
  writes a plan and a checklist, revises both, and compacts on the way, under a window of
  its own (issue #616).

  `fix_test_orchestrate`, `rename_symbol_orchestrate` and `follow_steps_orchestrate`, by
  name as well, are those three tasks on `orchestrate` rather than the default agent
  (issue #554): the same prompt, files, outcome and checks, so a bench of each beside its
  pair says what orchestrating a change costs against making it, on a one-file fix and on
  two changes across files. A check beside them says the root called `delegate`, which an
  agent that cannot write must do for the outcome to hold.
  """

  alias Troupe.Agent.Definitions
  alias Troupe.Bench.Scenario
  alias Troupe.Scratch

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
      answer_only(),
      follow_up(),
      task_list(),
      long_turn(),
      loop_turn(),
      scratchpad(),
      scratchpad_without(),
      scratchpad_session(),
      scratchpad_session_without(),
      orchestrated(fix_test()),
      orchestrated(rename_symbol()),
      orchestrated(follow_steps())
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
      Do not read, list or search any file yourself: call the delegate tool exactly once, with agent "explore" and a brief asking it to find the cat's name in notes/.
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

  # -- a second turn under an instruction file the first brought in ---------------------

  @house_rules """
  # House rules

  Every file you write starts with this line, and then its content:
  # kept by the bench
  """

  @docs_rules """
  # Under docs/

  Every file you write under docs/ ends with this line, after its content:
  -- end
  """

  # Issue #465's scenario (Decision 815). The first turn reads a file under docs/, so the
  # second begins with docs/AGENTS.md among the instruction files (Decision 798): where
  # those go in the prompt, the second turn's first call is the first whose prompt is not
  # the one before with something added. The outcome is the second turn's file under both
  # files' rules, so a run also says whether instructions sent with the turn rather than
  # in the system prompt were followed; the check says the first file kept the root's.
  defp follow_up do
    %Scenario{
      name: "follow_up",
      title: "a second turn, under an instruction file the first brought in",
      prompt: """
      docs/plan.txt names two steps. Read it, and write the word step 1 names to out/first.txt with write_file. Do nothing else, and say so in one short sentence when it is written.\
      """,
      follow_ups: [
        "Now write the word step 2 of docs/plan.txt names to docs/next.txt with write_file, and say so in one short sentence."
      ],
      files: %{
        "AGENTS.md" => @house_rules,
        "docs/AGENTS.md" => @docs_rules,
        "docs/plan.txt" => "step 1: alpha\nstep 2: beta\n"
      },
      outcome: {:file, "docs/next.txt", "# kept by the bench\nbeta\n-- end\n"},
      measure: fn ctx ->
        {[],
         [
           {"first", "out/first.txt keeps the root's rule",
            Scenario.holds?(ctx.workspace, "out/first.txt", "# kept by the bench\nalpha\n")},
           {"two_turns", "both turns were taken", typed(ctx.events) == 2}
         ]}
      end
    }
  end

  # -- three turns, each beginning with the task list the turn before left -------------

  # Issue #465's other prefix change: the task list a turn begins with is in the system
  # prompt (Decision 792), so each turn after one that changed the list begins with a
  # system prompt the conversation's thinking was not made under. On the `plan` agent,
  # which always has the list's tools (Decision 793): the first turn writes the list, and
  # works out a number in it without a tool, which is what makes a model think and hand
  # back a block the later turns carry; the second and third each read a file and mark
  # items done. Two calls a run begin with a changed list where it is in the system prompt.
  defp task_list do
    %Scenario{
      name: "task_list",
      title: "three turns, each beginning with the task list the turn before left",
      config: [default_agent: "plan"],
      prompt: """
      Write a task list with todo_write, every item pending: 1. read notes/a.txt 2. read notes/b.txt 3. report N, where N is the sum of the prime numbers below 60 (work it out yourself, with no tool, and write the number in the item). Do nothing else, and say so in one short sentence.\
      """,
      follow_ups: [
        "Read notes/a.txt with read_file and, in the same response, mark the first item of your task list completed with todo_write. Then say the file's first word in one short sentence.",
        "Read notes/b.txt with read_file and, in the same response, mark the second and third items completed with todo_write. Then say in one short sentence which of the two files has more lines, and the N of the third item."
      ],
      files: %{
        "notes/a.txt" => "apple\none\n",
        "notes/b.txt" => "banana\none\ntwo\nthree\n"
      },
      measure: fn ctx ->
        items = last_list(ctx.events)
        answer = reply(ctx)

        {[],
         [
           {"three_turns", "all three turns were taken", typed(ctx.events) == 3},
           {"list_done", "the list ends with its three items completed",
            length(items) == 3 and Enum.all?(items, &(&1["status"] == "completed"))},
           {"answer", "the last reply names b.txt and 440",
            answer =~ "b.txt" and answer =~ ~r/\b440\b/}
         ]}
      end
    }
  end

  # -- one turn of more than ten calls, on an agent with every tool ---------------------

  # Twelve files, each holding a number and naming the next.
  @chain ~w(start k7 b2 x9 m4 q1 d8 r3 h6 t5 w0 z2)
  @chain_numbers [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8]

  defp chain do
    nexts = Enum.map(tl(@chain), &"chain/#{&1}.txt") ++ ["none"]

    [@chain, @chain_numbers, nexts]
    |> Enum.zip()
    |> Enum.map(fn {name, n, next} -> {"chain/#{name}.txt", "number: #{n}\nnext: #{next}\n"} end)
  end

  # Issue #590 (Decision 867): an agent with every tool is offered the task list's tools
  # once its turn has made ten model calls (Decision 793), and the tools are the start of
  # every prompt, in front of any thinking a turn hands back. One turn on `build` with no
  # list: the first call works a number out without a tool, which is what makes a model
  # think and hand back a block every later call carries; then twelve files read one after
  # another, each naming the next, so no two reads go in one response. The eleventh call
  # and those after it are the ones a change of tools would make stale.
  defp long_turn do
    %Scenario{
      name: "long_turn",
      title: "one turn of more than ten calls, on an agent with every tool",
      config: [max_turns: 20],
      prompt: """
      First work out N, the sum of the prime numbers below 60, yourself, with no tool. Then read chain/start.txt with read_file. Each file holds a number and names the next file to read: read that one, one file a response, until a file says next: none. Then say in one short sentence what N is and what the numbers you read add up to.\
      """,
      files: Map.new(chain()),
      measure: fn ctx ->
        answer = reply(ctx)
        calls = Enum.count(ctx.events, &(&1.type == "llm_request" and &1.agent == ["root"]))

        {[],
         [
           {"answer", "the reply names 440 and #{Enum.sum(@chain_numbers)}",
            answer =~ ~r/\b440\b/ and answer =~ ~r/\b#{Enum.sum(@chain_numbers)}\b/},
           {"long", "the turn made more than ten model calls", calls > 10}
         ]}
      end
    }
  end

  # -- a /loop turn, then a person's turn ---------------------------------------------

  # Issue #606 (Decision 871): `goal_complete` was offered on a loop's turns and no others
  # (Decision 679), so a person's turn after a loop's sent other tools, in front of the
  # thinking the loop's turn hands back. The loop's one iteration works a number out
  # without a tool, which is what makes a model think, writes it and says the goal is met;
  # the person's turn then reads it back and writes the next one.
  defp loop_turn do
    %Scenario{
      name: "loop_turn",
      title: "a /loop turn, then a person's turn in the same session",
      loop: """
      out/n.txt holds N, the sum of the prime numbers below 60, and nothing else. Work N out yourself, with no tool.\
      """,
      prompt: """
      Now read out/n.txt with read_file, and write N plus 1 to out/next.txt with write_file, the number and nothing else. Say so in one short sentence.\
      """,
      outcome: {:file, "out/next.txt", "441\n"},
      measure: fn ctx ->
        {[],
         [
           {"loop", "the loop's turn said the goal is met", loop_met?(ctx.events)},
           {"person", "the person's turn was taken", typed(ctx.events) == 1}
         ]}
      end
    }
  end

  defp loop_met?(events),
    do: Enum.any?(events, &(&1.type == "loop_stopped" and &1.data["reason"] == "goal_complete"))

  # -- a long answer, and where it goes ---------------------------------------------

  @schema_sql """
  CREATE TABLE notes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    body TEXT NOT NULL DEFAULT '',
    tags TEXT,            -- comma-separated
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    archived INTEGER NOT NULL DEFAULT 0
  );
  CREATE INDEX notes_created ON notes (created_at);
  CREATE VIRTUAL TABLE notes_fts USING fts5(title, body, content='notes', content_rowid='id');
  """

  @store_py """
  import sqlite3

  DB = "notes.db"

  def connect():
      conn = sqlite3.connect(DB)
      conn.row_factory = sqlite3.Row
      return conn

  def add(title, body, tags=()):
      with connect() as conn:
          conn.execute("INSERT INTO notes (title, body, tags) VALUES (?, ?, ?)", (title, body, ",".join(tags)))

  def search(term):
      with connect() as conn:
          return conn.execute("SELECT n.* FROM notes_fts f JOIN notes n ON n.id = f.rowid WHERE notes_fts MATCH ?", (term,)).fetchall()

  def archive(note_id):
      with connect() as conn:
          conn.execute("UPDATE notes SET archived = 1 WHERE id = ?", (note_id,))
  """

  @migration_prompt """
  Write a migration plan for moving this project's storage from SQLite to PostgreSQL: db/schema.sql is the schema and app/store.py the code that uses it. Read both, then give the plan: the steps in order, the schema changes, how the data is copied, the risks, and how to roll back.\
  """

  # Issue #472 (Decision 870): a long answer a person will read, which an agent with the
  # scratchpad puts there and names in a short reply. `scratchpad_without` is the same task
  # on the build agent as it was before it, `show` denied and its words not in the prompt,
  # so the two say what the scratchpad does to a turn's tokens and to where the plan ends up.
  defp scratchpad do
    %Scenario{
      name: "scratchpad",
      title: "a migration plan, a long answer a person will read",
      prompt: @migration_prompt,
      files: %{"db/schema.sql" => @schema_sql, "app/store.py" => @store_py},
      measure: fn ctx ->
        {[],
         [
           {"shown", "the plan went to the scratchpad", shown(ctx.events) != []},
           {"named", "the reply names the document", Enum.any?(shown(ctx.events), &(reply(ctx) =~ &1))},
           {"short", "the reply is a fifth of the document or less",
            byte_size(reply(ctx)) * 5 <= Enum.max([0 | shown_sizes(ctx.events)])}
         ]}
      end
    }
  end

  defp scratchpad_without do
    %Scenario{
      name: "scratchpad_without",
      title: "the same plan, with no scratchpad",
      prompt: @migration_prompt,
      files: %{
        "db/schema.sql" => @schema_sql,
        "app/store.py" => @store_py,
        ".troupe/agents/build.md" => build_without_show()
      },
      measure: fn ctx ->
        {[],
         [
           {"answered", "the reply is the plan", byte_size(reply(ctx)) >= 1_000},
           {"not_shown", "nothing went to a scratchpad", shown(ctx.events) == []}
         ]}
      end
    }
  end

  # Issue #616: a long session that writes a plan and a checklist, revises each, asks
  # about them, and compacts on the way, with the scratchpad and without it. The person
  # reads the whole plan after each revision: in the reply without the scratchpad, beside
  # the chat with it, where a revision is a `patch`. The window is the scenario's own
  # whatever the model's is: four times the session's first prompt, so each side compacts
  # once or twice over its eight turns, after several calls each time, rather than after
  # nearly every call as a window of twice the first prompt made it. A smaller window makes
  # the side whose tail holds whole plans compact after every turn; a larger one, a session
  # several times as long and as dear before either compacts.
  @session_follow_ups [
    "Revise the plan: the notes are copied in batches of 1,000 rows that resume where they stopped after a failure, and the full-text index is rebuilt after the copy. Give the whole plan again, revised.",
    "Now write a checklist for the night of the switch: what to check before, during and after it, one line an item.",
    "Which step of the plan copies the notes, and how long does that step take for 2,000,000 notes at 5,000 rows a second? Answer in two sentences.",
    "Add a step to the plan, right after the copy, that compares the row counts of both databases, and give the whole plan again.",
    "Add to the checklist, under during the switch: the row counts match before the reads move. Give the whole checklist again.",
    "What does the plan say to do if the row counts differ? Answer in two sentences.",
    "Revise the rollback: the SQLite file stays read-only for a week after the switch, and the reads go back to it by turning the flag off. Give the whole plan again, revised."
  ]

  @session_config [
    context_window: 24_000,
    compact_at: 0.75,
    max_turns: 40,
    max_input_tokens: 600_000,
    max_output_tokens: 60_000,
    wall_clock_ms: 900_000
  ]

  defp scratchpad_session do
    %Scenario{
      name: "scratchpad_session",
      title: "a long session that writes and revises documents, and compacts",
      prompt: @migration_prompt,
      follow_ups: @session_follow_ups,
      files: %{"db/schema.sql" => @schema_sql, "app/store.py" => @store_py},
      config: @session_config,
      measure: fn ctx ->
        plan = last_plan(ctx.events)

        {[],
         [
           {"eight_turns", "all eight turns were taken", typed(ctx.events) == 8},
           {"compacted", "the session compacted before its last turn",
            compacted_before?(ctx.events, 8)},
           {"shown", "the plan went to the scratchpad, and was revised there",
            Enum.any?(shown_versions(ctx.events), &(&1 > 1))},
           {"patched", "a revision went by patch", patched(ctx.events) > 0},
           {"timed", "the fourth reply says the copy takes 400 seconds",
            timed?(answers(ctx.events), 3)},
           {"counted", "the plan as last written compares the row counts",
            plan =~ ~r/row counts?/i},
           {"kept", "the plan as last written keeps the SQLite file read-only",
            plan =~ ~r/read-only/i}
         ]}
      end
    }
  end

  defp scratchpad_session_without do
    %Scenario{
      name: "scratchpad_session_without",
      title: "the same session, with no scratchpad",
      prompt: @migration_prompt,
      follow_ups: @session_follow_ups,
      files: %{
        "db/schema.sql" => @schema_sql,
        "app/store.py" => @store_py,
        ".troupe/agents/build.md" => build_without_show()
      },
      config: @session_config,
      measure: fn ctx ->
        plan = reply(ctx)

        {[],
         [
           {"eight_turns", "all eight turns were taken", typed(ctx.events) == 8},
           {"compacted", "the session compacted before its last turn",
            compacted_before?(ctx.events, 8)},
           {"not_shown", "nothing went to a scratchpad", shown(ctx.events) == []},
           {"timed", "the fourth reply says the copy takes 400 seconds",
            timed?(answers(ctx.events), 3)},
           {"counted", "the last plan compares the row counts", plan =~ ~r/row counts?/i},
           {"kept", "the last plan keeps the SQLite file read-only", plan =~ ~r/read-only/i}
         ]}
      end
    }
  end

  # -- the same task, orchestrated ---------------------------------------------------

  # Issue #554: a task as its pair has it, on `orchestrate`, which cannot write, edit or
  # run a command and so gets the change done through subagents. Its children run one
  # after another, each on a share of the root's wall clock, so the run has more of it
  # than a task's 240 s; the runner's deadline follows. Nothing else differs: the cost,
  # the calls and the tokens are the run's whole tree's, which is what the comparison is.
  defp orchestrated(%Scenario{} = scenario) do
    %{
      scenario
      | name: scenario.name <> "_orchestrate",
        title: scenario.title <> ", on orchestrate",
        config:
          Keyword.merge(scenario.config, default_agent: "orchestrate", wall_clock_ms: 600_000),
        measure: fn ctx ->
          {metrics, checks} = scenario.measure.(ctx)
          {[], delegated} = delegated(ctx)
          {metrics, checks ++ delegated}
        end
    }
  end

  # Whether the first compaction came before the `n`th turn's input.
  defp compacted_before?(events, n) do
    compacted = Enum.find(events, &(&1.type == "compacted"))

    input =
      events
      |> Enum.filter(&(&1.type == "user_input" and &1.data["source"] == "user"))
      |> Enum.at(n - 1)

    compacted != nil and input != nil and compacted.seq < input.seq
  end

  # 2,000,000 notes at 5,000 rows a second, however the reply puts it.
  @timed ~r/\b400[\s-]*(s\b|sec)|6\.67?\s*min|6\s*min(ute)?s?,?\s*(and\s*)?40|six minutes and forty/i

  defp timed?(answers, index), do: (Enum.at(answers, index) || "") =~ @timed

  # The root's replies that ended a turn, as text, in order.
  defp answers(events) do
    events
    |> Enum.filter(&(&1.type == "llm_response" and &1.agent == ["root"]))
    |> Enum.map(&(get_in(&1.data, ["message", "content"]) || []))
    |> Enum.reject(fn content -> Enum.any?(content, &match?(%{"type" => "tool_use"}, &1)) end)
    |> Enum.map(fn content ->
      content
      |> Enum.filter(&match?(%{"type" => "text"}, &1))
      |> Enum.map_join("\n", & &1["text"])
    end)
  end

  # The versions each document reached.
  defp shown_versions(events),
    do: for(%{type: "scratch_updated", data: %{"version" => version}} <- events, do: version)

  # The patches that revised a document.
  defp patched(events) do
    Enum.count(
      events,
      &(&1.type == "tool_call_completed" and &1.data["name"] == "patch" and &1.data["ok"])
    )
  end

  # The words of the first document the run showed, its plan, as the run last wrote them:
  # its `show` and every `patch` after it, in the order the calls were made, by the rule
  # the scratchpad writes by. A call refused, or never answered, changed nothing.
  defp last_plan(events) do
    case shown(events) do
      [plan | _] -> events |> written() |> Map.get(plan, "")
      [] -> ""
    end
  end

  defp written(events) do
    done =
      for %{type: "tool_call_completed", data: %{"ok" => true, "call_id" => id}} <- events,
          into: MapSet.new(),
          do: id

    events
    |> Enum.filter(&(&1.type == "tool_call_started" and MapSet.member?(done, &1.data["call_id"])))
    |> Enum.reduce(%{}, fn %{data: data}, documents ->
      write(documents, data["name"], data["args"] || %{})
    end)
  end

  defp write(documents, "show", %{"name" => raw, "content" => content}) when is_binary(content) do
    case Scratch.name(raw) do
      {:ok, name} -> Map.put(documents, name, content)
      {:error, _refused} -> documents
    end
  end

  defp write(documents, "patch", %{"name" => raw, "new_string" => new} = args)
       when is_binary(new) do
    with {:ok, name} <- Scratch.name(raw),
         {:ok, content} <- Map.fetch(documents, name),
         {:ok, revised} <- Scratch.revise(content, args["old_string"], new) do
      Map.put(documents, name, revised)
    else
      _unchanged -> documents
    end
  end

  defp write(documents, _tool, _args), do: documents

  # The names of the documents the run showed, and their sizes.
  defp shown(events),
    do: for(%{type: "scratch_updated", data: %{"name" => name}} <- events, uniq: true, do: name)

  defp shown_sizes(events),
    do: for(%{type: "scratch_updated", data: %{"size" => size}} <- events, do: size)

  @doc false
  @spec build_without_show() :: String.t()
  def build_without_show do
    words = File.read!(Path.join(Definitions.builtin_dir(), "build.md"))
    [_, front, body] = Regex.run(~r/\A---\r?\n(.*?)\r?\n---\r?\n(.*)\z/s, words)

    body =
      Regex.replace(
        ~r/\s+Answer\s+in\s+the\s+reply\s+unless\s+they\s+ask\s+for\s+a\s+document\b.*?\s+rather\s+than\s+showing\s+it\s+again\./s,
        body,
        ""
      )

    "---\n" <> front <> "\npermissions:\n  show: deny\n  patch: deny\n---\n" <> body
  end

  # The task list as the run left it.
  defp last_list(events) do
    events
    |> Enum.filter(&(&1.type == "todo_updated"))
    |> List.last()
    |> case do
      nil -> []
      event -> event.data["items"] || []
    end
  end

  # What the run typed, each a turn of its own; a note from the harness is not one.
  defp typed(events),
    do: Enum.count(events, &(&1.type == "user_input" and &1.data["source"] == "user"))

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
