defmodule Troupe.Agent.BudgetQuestion do
  @moduledoc """
  The budget question's words, and what an answer to it means (Decision 699).

  A spent limit is a checkpoint, not an error (Decision 660), and the question is the
  only place a person meets the budget, so it says what the limit is for, what the
  session has spent — in money, where its calls were priced — and what the raise on
  offer would cost. An answer says how much more, and for how long:

    * **this run** — for the turn in flight, a loop's iteration; what it does not use
      goes back when the turn ends, so the next one meets the checkpoint again;
    * **this session** — for the rest of the session, then ask again; `no limit this
      session` lifts the one limit for good, and the others still ask (Decision 687);
    * **this workspace** — for the session, and written to the workspace's
      `.troupe/config.yaml`, so the next session there starts with it.

  The sizes offered are anchored on what the session has used, and an amount can be
  typed — `50`, `+50`, `50 turns`, `+50k tokens`, `+15 min`, with a scope word after it
  — and every form means that much *more* of the limit that asked; a bare amount is for
  the session. Anything else is asked back, with the reason, never read as a stop. The
  old answers keep their meaning: `allow` buys the first slice again, `always` lifts the
  limit, `deny` stops.

  On a pod the team's terms are a ceiling: a raise past what they set is refused with
  the reason, and the workspace is not a scope there, since a pod's limits are the terms
  and the profile, in the plane.

  Pure. `Troupe.Agent.Server`'s gate builds the context, asks, and applies the decision.
  """

  alias Troupe.Agent.Headroom
  alias Troupe.Budget

  @type scope :: :run | :session | :workspace
  @type decision :: :allow | :always | :deny | {:extend, scope(), pos_integer()}

  @typedoc """
  What the question is about: the limit, how much of it is used, the session's spend
  so far in micro-dollars (`nil` when nothing priced it), which scopes may be chosen,
  the ceiling the terms put on this limit on a pod, the file a workspace answer writes,
  and what to call the run — `run`, or `iteration` inside a `/loop`.
  """
  @type context :: %{
          limit: Budget.exhaustion(),
          entry: Headroom.entry(),
          spent_micros: non_neg_integer() | nil,
          scopes: [scope()],
          cap: pos_integer() | nil,
          path: Path.t() | nil,
          run_word: String.t()
        }

  @minute 60_000
  @scopes [:run, :session, :workspace]

  @allow ~w(allow yes y ok continue more)
  @always ~w(always a unlimited lift)
  @deny ~w(deny no n stop cancel quit)
  # Words an answer may carry around its amount and scope without changing either.
  @filler ~w(this for the only of from now on and in it more)
  @run_words ~w(run iteration)
  @workspace_words ~w(workspace repo repository project)
  @units ~w(turn turns t call calls tok token tokens k thousand m million min mins minute minutes h hr hrs hour hours s sec secs second seconds ms)

  @doc "The context the gate hands over; see `t:context/0`."
  @spec context(Budget.exhaustion(), Headroom.entry(), keyword()) :: context()
  def context(limit, entry, opts \\ []) do
    %{
      limit: limit,
      entry: entry,
      spent_micros: Keyword.get(opts, :spent_micros),
      scopes: Keyword.get(opts, :scopes, @scopes),
      cap: Keyword.get(opts, :cap),
      path: Keyword.get(opts, :path),
      run_word: Keyword.get(opts, :run_word, "run")
    }
  end

  # -- the question ---------------------------------------------------------------

  @doc """
  Three increments to offer, sized on what has been used: the first is the round number
  nearest a quarter of it, so a session that burned 40 turns is offered 10, 25 and 50
  and never 5.
  """
  @spec steps(Budget.exhaustion(), non_neg_integer()) :: [pos_integer()]
  def steps(limit, used) do
    nice = nice(limit)
    from = Enum.find_index(nice, &(&1 * 4 >= used)) || length(nice)
    nice |> Enum.drop(min(from, length(nice) - 3)) |> Enum.take(3)
  end

  defp nice(:max_turns), do: [5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000]

  defp nice(tokens) when tokens in [:max_input_tokens, :max_output_tokens],
    do: [
      10_000,
      25_000,
      50_000,
      100_000,
      250_000,
      500_000,
      1_000_000,
      2_500_000,
      5_000_000,
      10_000_000,
      25_000_000
    ]

  defp nice(:wall_clock), do: Enum.map([5, 10, 15, 30, 60, 120, 240, 480, 960], &(&1 * @minute))

  @doc """
  The options, each a label a person can pick or type back: the three steps for this
  run, the larger two for this session, no limit for this session, the largest for this
  workspace, and `stop`. A scope the context does not allow is not offered, nor is a
  step the terms' ceiling has no room for.
  """
  @spec options(context()) :: [%{label: String.t(), description: String.t()}]
  def options(ctx) do
    [small, middle, large] = steps(ctx.limit, ctx.entry.used)

    run =
      for step <- [small, middle, large],
          :run in ctx.scopes,
          fits?(ctx, step),
          do: option(ctx, :run, step)

    session =
      for step <- [middle, large],
          :session in ctx.scopes,
          fits?(ctx, step),
          do: option(ctx, :session, step)

    lift = if :session in ctx.scopes and is_nil(ctx.cap), do: [no_limit(ctx)], else: []

    workspace =
      if :workspace in ctx.scopes and fits?(ctx, large),
        do: [option(ctx, :workspace, large)],
        else: []

    run ++ session ++ lift ++ workspace ++ [%{label: "stop", description: "stop here"}]
  end

  defp fits?(%{cap: nil}, _step), do: true
  defp fits?(%{cap: cap, entry: %{limit: limit}}, step), do: limit + step <= cap

  defp option(ctx, :run, step) do
    %{
      label: "+#{amount(ctx.limit, step)} this #{ctx.run_word}",
      description:
        "for the #{ctx.run_word} in flight; what it does not use goes back, and the next one asks again" <>
          cost(ctx, step)
    }
  end

  defp option(ctx, :session, step) do
    %{
      label: "+#{amount(ctx.limit, step)} this session",
      description: "for the rest of this session, then ask again" <> cost(ctx, step)
    }
  end

  defp option(ctx, :workspace, step) do
    %{
      label: "+#{amount(ctx.limit, step)} this workspace",
      description:
        "for this session, and #{key(ctx.limit)}: #{ctx.entry.limit + step} written to #{ctx.path} " <>
          "so the next session here starts with it" <> cost(ctx, step)
    }
  end

  defp no_limit(ctx) do
    %{
      label: "no limit this session",
      description:
        "lift the #{limit_words(ctx.limit)} limit for the rest of this session; the other limits still ask"
    }
  end

  @doc """
  The question: which limit is reached and what it protects against, what the session
  has used and spent, what the middle step would cost at the current rate, and how to
  answer. A `note` — why the last answer could not be read — comes first.
  """
  @spec question(context(), String.t() | nil) :: String.t()
  def question(ctx, note \\ nil) do
    [note, reached(ctx), spent(ctx), how(ctx)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp reached(ctx) do
    "#{Headroom.describe(Headroom.dimension(ctx.limit), ctx.entry)}: the #{limit_words(ctx.limit)} limit " <>
      "is a safety net against runaway loops and runaway spend."
  end

  defp spent(%{spent_micros: nil} = ctx),
    do:
      "This session has used #{amount(ctx.limit, ctx.entry.used)} so far; its calls carry no price."

  defp spent(ctx) do
    [_small, middle, _large] = steps(ctx.limit, ctx.entry.used)

    "This session has used #{amount(ctx.limit, ctx.entry.used)} and #{money(ctx.spent_micros)} so far" <>
      estimate(ctx, middle) <> "."
  end

  defp estimate(ctx, step) do
    case rate(ctx) do
      nil ->
        ""

      rate ->
        "; #{amount(ctx.limit, step)} more would cost #{roughly(round(rate * step))} at the current rate"
    end
  end

  defp cost(ctx, step) do
    case rate(ctx) do
      nil -> ""
      rate -> " (#{roughly(round(rate * step))})"
    end
  end

  defp roughly(micros) when micros < 10_000, do: "under a cent"
  defp roughly(micros), do: "roughly " <> money(micros)

  # Micro-dollars per unit of the limit — per turn, per token, per millisecond — from what
  # the session has spent on what it has used. Nothing when nothing was priced.
  defp rate(%{spent_micros: spent, entry: %{used: used}})
       when is_integer(spent) and spent > 0 and used > 0,
       do: spent / used

  defp rate(_ctx), do: nil

  defp how(%{cap: cap} = ctx) when is_integer(cap) do
    if fits?(ctx, 1) do
      "The team's terms cap the #{limit_words(ctx.limit)} limit at #{amount(ctx.limit, cap)} for this session. " <>
        choose(ctx)
    else
      "This session runs under its team's terms, which set the #{limit_words(ctx.limit)} limit at " <>
        "#{amount(ctx.limit, cap)}: it cannot raise that itself, and an admin can, in the plane."
    end
  end

  defp how(ctx), do: choose(ctx)

  defp choose(ctx) do
    workspace = if :workspace in ctx.scopes, do: ", +25 workspace", else: ""

    "Choose how much more and for how long, or type an amount (+25, +25 session#{workspace}); it asks again " <>
      "when that runs out." <> pod_note(ctx)
  end

  defp pod_note(%{scopes: scopes, run_word: run_word}) do
    if :workspace in scopes,
      do: "",
      else:
        " On a pod a raise lasts this #{run_word} or this session; the workspace's limits are the team's terms."
  end

  # -- the answer -----------------------------------------------------------------

  @doc """
  What an answer means, or why it cannot be read — a sentence for the question asked
  again. The labels `options/1` offers parse back through here, as does anything a
  person types in their own words.
  """
  @spec parse(String.t(), context()) :: {:ok, decision()} | {:error, String.t()}
  def parse(text, ctx) when is_binary(text) do
    answer = text |> String.trim() |> String.downcase()

    cond do
      answer in @allow -> {:ok, :allow}
      answer in @deny -> {:ok, :deny}
      answer in @always or String.starts_with?(answer, "no limit") -> lift(ctx)
      true -> amount_answer(answer, ctx)
    end
  end

  defp lift(%{cap: cap} = ctx) when is_integer(cap), do: {:error, capped(ctx)}
  defp lift(_ctx), do: {:ok, :always}

  defp amount_answer(answer, ctx) do
    case Regex.run(~r/^\+?\s*(\d+(?:[.,]\d+)?)([a-z]*)(.*)$/, answer) do
      [_all, number, suffix, rest] ->
        {units, scope_words} = units_and_scope(suffix, String.split(rest, ~r/[\s,]+/, trim: true))

        with {:ok, amount} <- in_unit(ctx.limit, number(number), units),
             {:ok, scope} <- scope(scope_words, ctx) do
          within_cap(ctx, scope, amount)
        end

      nil ->
        {:error,
         "`#{answer}` is not an amount: say +25, +25 session or +25 workspace, or pick one of the options."}
    end
  end

  # `50k tokens`: the suffix on the number and the unit word after it are one unit.
  defp units_and_scope(suffix, words) do
    {unit_words, scope_words} = Enum.split_while(words, &(&1 in @units))
    {Enum.reject([suffix | unit_words], &(&1 == "")), scope_words}
  end

  defp number(text) do
    text = String.replace(text, ",", ".")
    if String.contains?(text, "."), do: String.to_float(text), else: String.to_integer(text)
  end

  defp in_unit(:max_turns, n, units)
       when units in [[], ["turn"], ["turns"], ["t"], ["call"], ["calls"]] do
    if n == trunc(n) and n >= 1,
      do: {:ok, trunc(n)},
      else: {:error, "turns come whole: say +25 or +25 turns."}
  end

  defp in_unit(:max_turns, _n, _units),
    do: {:error, "the question is about turns: say +25 or +25 turns."}

  defp in_unit(tokens, n, units) when tokens in [:max_input_tokens, :max_output_tokens] do
    case units do
      [] -> tokens_amount(n)
      [word] when word in ~w(tok token tokens) -> tokens_amount(n)
      [k] when k in ["k", "thousand"] -> tokens_amount(n * 1_000)
      [k, _tokens] when k in ["k", "thousand"] -> tokens_amount(n * 1_000)
      [m] when m in ["m", "million"] -> tokens_amount(n * 1_000_000)
      [m, _tokens] when m in ["m", "million"] -> tokens_amount(n * 1_000_000)
      _other -> {:error, "the question is about tokens: say +50k, +50k tokens or +50000."}
    end
  end

  defp in_unit(:wall_clock, n, units) do
    case units do
      [] -> time_amount(n * @minute)
      [minutes] when minutes in ~w(min mins minute minutes m) -> time_amount(n * @minute)
      [hours] when hours in ~w(h hr hrs hour hours) -> time_amount(n * 60 * @minute)
      [seconds] when seconds in ~w(s sec secs second seconds) -> time_amount(n * 1_000)
      ["ms"] -> time_amount(n)
      _other -> {:error, "the question is about time: say +15, +15 min or +1 h."}
    end
  end

  defp tokens_amount(n) when n < 1_000,
    do: {:error, "#{round(n)} tokens would not last one call: say +50k or +50000."}

  defp tokens_amount(n), do: {:ok, round(n)}

  defp time_amount(ms) when ms < 1_000,
    do: {:error, "that is less than a second: say +15, +15 min or +1 h."}

  defp time_amount(ms), do: {:ok, round(ms)}

  defp scope(words, ctx) do
    case Enum.reject(words, &(&1 in @filler)) do
      [] ->
        allowed(:session, ctx)

      [run] when run in @run_words ->
        allowed(:run, ctx)

      ["session"] ->
        allowed(:session, ctx)

      [workspace] when workspace in @workspace_words ->
        allowed(:workspace, ctx)

      other ->
        {:error,
         "`#{Enum.join(other, " ")}` is not a scope: say run, session or workspace, as in +25 session."}
    end
  end

  defp allowed(scope, %{scopes: scopes}) when scope in [:run, :session] do
    if scope in scopes,
      do: {:ok, scope},
      else: {:error, "a raise for this #{scope} is not offered here."}
  end

  defp allowed(:workspace, %{scopes: scopes}) do
    if :workspace in scopes,
      do: {:ok, :workspace},
      else:
        {:error,
         "on a pod the workspace's limits are the team's terms and the profile: say +25 or +25 session."}
  end

  defp within_cap(%{cap: nil}, scope, amount), do: {:ok, {:extend, scope, amount}}

  defp within_cap(ctx, scope, amount) do
    if fits?(ctx, amount), do: {:ok, {:extend, scope, amount}}, else: {:error, capped(ctx)}
  end

  defp capped(ctx) do
    "the team's terms cap the #{limit_words(ctx.limit)} limit at #{amount(ctx.limit, ctx.cap)} for this session, " <>
      "and it cannot raise that itself; an admin can, in the plane."
  end

  # -- words ----------------------------------------------------------------------

  @doc "What to call a limit in a sentence: `the turn limit`, `the time limit`."
  @spec limit_words(Budget.exhaustion()) :: String.t()
  def limit_words(:max_turns), do: "turn"
  def limit_words(:max_input_tokens), do: "input-token"
  def limit_words(:max_output_tokens), do: "output-token"
  def limit_words(:wall_clock), do: "time"

  @doc "The config key a limit is written under."
  @spec key(Budget.exhaustion()) :: String.t()
  def key(limit), do: Atom.to_string(Budget.field(limit))

  @doc "An amount in a limit's unit, as a person reads it: `25 turns`, `50k tokens`, `15 min`."
  @spec amount(Budget.exhaustion(), non_neg_integer()) :: String.t()
  def amount(:max_turns, 1), do: "1 turn"
  def amount(:max_turns, n), do: "#{n} turns"

  def amount(tokens, n) when tokens in [:max_input_tokens, :max_output_tokens],
    do: "#{tokens(n)} tokens"

  def amount(:wall_clock, ms), do: duration(ms)

  defp tokens(n) when n >= 1_000_000, do: round_unit(n / 1_000_000) <> "M"
  defp tokens(n) when n >= 1_000, do: round_unit(n / 1_000) <> "k"
  defp tokens(n), do: Integer.to_string(n)

  defp duration(ms) when ms >= 60 * @minute, do: round_unit(ms / (60 * @minute)) <> " h"
  defp duration(ms) when ms >= @minute, do: round_unit(ms / @minute) <> " min"
  defp duration(ms), do: round_unit(ms / 1_000) <> " s"

  defp round_unit(value) do
    if value == trunc(value),
      do: Integer.to_string(trunc(value)),
      else: :erlang.float_to_binary(value / 1, decimals: 1)
  end

  @doc "Micro-dollars as money: `$1.20`; less than a cent is said rather than rounded away."
  @spec money(non_neg_integer()) :: String.t()
  def money(0), do: "$0.00"
  def money(micros) when micros < 10_000, do: "under a cent"
  def money(micros), do: "$" <> :erlang.float_to_binary(micros / 1_000_000, decimals: 2)
end
