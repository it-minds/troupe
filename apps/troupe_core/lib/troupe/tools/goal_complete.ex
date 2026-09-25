defmodule Troupe.Tools.GoalComplete do
  @moduledoc """
  How an iteration of `/loop` says the session's goal is met (issue #59, Decision 681).

  A loop never reads the model's prose to decide whether it is done. This call, completed,
  is the whole of the verdict, and an iteration that ends without one is an iteration that
  did not meet the goal; `Troupe.Session.Loop` reads it off the durable
  `tool_call_completed`, with the evidence from its arguments.

  Offered only on a turn a running loop started (`Ctx.loop`), and whatever the profile's
  tool list says: it changes no file and runs nothing, and a loop whose agent had no way
  to say "done" could only ever run to its cap. Inline, because all it does is answer.
  """

  @behaviour Troupe.Tool

  alias Troupe.Tool

  @impl Troupe.Tool
  def name, do: "goal_complete"

  @impl Troupe.Tool
  def mode, do: :inline

  @impl Troupe.Tool
  def description do
    """
    Say that the session's goal, in the <goal> section, is met, which ends the loop that is
    working towards it.

    Call it only when the goal is fully achieved and you have checked that it is — a test
    run that passes, the file that now exists — and put that evidence in `summary`. If
    the goal is not met yet, do not call it: end your turn saying what is left, and the
    next iteration carries on from there.
    """
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "summary" => %{
          "type" => "string",
          "description" => "What shows the goal is met: the checks you ran and what they said."
        }
      },
      "required" => ["summary"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, _ctx) do
    with {:ok, _summary} <- Tool.fetch_string(args, "summary") do
      {:ok,
       "Recorded: the goal is met, and the loop stops when this turn ends. " <>
         "End the turn with a short account of what was done."}
    end
  end
end
