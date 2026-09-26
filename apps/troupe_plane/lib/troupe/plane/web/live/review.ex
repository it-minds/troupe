defmodule Troupe.Plane.Web.Live.Review do
  @moduledoc """
  What ran while nobody was watching, and which of it needs a person.

  Triggers answers "what fires, and when". This answers the question that comes after it
  and that nothing else does: **of everything that fired, what should somebody read?**

  ## Worst first, and grouped by what fired it

  A flat list ordered by time is a list where the one run that failed at three in the
  morning is nine screens down. So the ordering is by outcome — failed, then waiting on
  somebody, then the rest — and the grouping is by the trigger, because a trigger that
  fails every night is one problem and not thirty.

  ## Reviewed is a state somebody puts a run into

  Not a filter that hides it. A run is *unreviewed* until an administrator says they have
  read it, and the page leads with those — which is what makes the list shrink rather than
  grow. Marking one is recorded in the audit trail with the reviewer's name, because "who
  said this was fine" is exactly the question asked afterwards.

  ## What is not here

  What the session said. This screen shows how a run ended, what it cost and whether
  anybody has looked at it; reading the work itself means being on the session's ACL, which
  no administrative role grants.
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin

  # Worst first. `failed` is somebody's problem now; `waiting` is a run that stopped for a
  # person and is still stopped; the rest are ordinary outcomes that a reader may still
  # want to see and should not have to wade through to find the first two.
  @severity %{"failed" => 0, "waiting" => 1, "running" => 2, "created" => 3, "done" => 4}

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(runs: [], flash_message: nil, error: nil, show_all: false) |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("review", %{"session" => session_id}, socket) do
    case Admin.run_review(socket.assigns.actor, session_id) do
      {:ok, _reviewed} ->
        {:noreply, socket |> assign(flash_message: "#{session_id} marked read") |> load()}

      {:error, error} ->
        {:noreply, assign(socket, flash_message: describe(error))}
    end
  end

  def handle_event("show-all", _params, socket) do
    {:noreply, assign(socket, show_all: not socket.assigns.show_all)}
  end

  defp load(socket) do
    case Admin.runs_list(socket.assigns.actor, limit: 200) do
      {:ok, runs} -> assign(socket, runs: runs, error: nil)
      {:error, error} -> assign(socket, runs: [], error: describe(error))
    end
  end

  defp describe(%{message: message, data: %{reason: reason}}), do: "#{message}: #{reason}"
  defp describe(%{message: message}), do: message

  defp reviewed?(run), do: not is_nil(run["reviewed_by"])

  defp needs_a_person?(run), do: run["state"] in ["failed", "waiting"] and not reviewed?(run)

  # Grouped by the trigger, worst outcome first, and within a group the worst run first.
  # A trigger that fails every night is one problem, and a list that made it thirty would
  # bury the one that failed once.
  defp grouped(runs) do
    runs
    |> Enum.group_by(& &1["trigger"])
    |> Enum.map(fn {trigger, group} -> {trigger, Enum.sort_by(group, &severity/1)} end)
    |> Enum.sort_by(fn {_trigger, group} -> group |> Enum.map(&severity/1) |> Enum.min() end)
  end

  defp severity(run), do: Map.get(@severity, run["state"], 5)

  defp shown(runs, true), do: runs
  defp shown(runs, false), do: Enum.filter(runs, &needs_a_person?/1)

  defp outcome(run) do
    case run["state"] do
      "failed" -> "failed" <> reason(run)
      "waiting" -> "waiting for somebody" <> asked(run)
      other -> other
    end
  end

  # A session that ended for a reason worth naming names it. `budget_exhausted` is not a
  # failure — a trigger with a turn ceiling is *meant* to end that way — and the run's own
  # state has already accounted for that.
  defp reason(%{"done_reason" => reason}) when is_binary(reason), do: " — #{reason}"
  defp reason(_run), do: ""

  # An approval and a question are both a person's to answer, so the count is both.
  defp asked(run) do
    case open(run["pending_approvals"]) + open(run["pending_questions"]) do
      0 -> ""
      count -> " — #{count} waiting"
    end
  end

  defp open(count) when is_integer(count) and count > 0, do: count
  defp open(_count), do: 0

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns = assign(assigns, :groups, grouped(shown(assigns.runs, assigns.show_all)))

    ~H"""
    <.shell actor={@actor} breakglass={@breakglass} page={:review}>
      <h1>Review</h1>
      <p class="lede">
        What ran while nobody was watching, worst outcome first and grouped by what fired
        it. A trigger that fails every night is one problem, not thirty.
      </p>

      <p :if={@flash_message} class="banner" role="status">{@flash_message}</p>
      <p :if={@error} class="banner banner--breakglass" role="alert">{@error}</p>

      <form id="review-scope" phx-submit="show-all">
        <button type="submit">
          {if @show_all, do: "only what needs a person", else: "show every run"}
        </button>
      </form>

      <p :if={@groups == [] and not @show_all} class="empty">
        Nothing is waiting on anybody. Every run that failed or stopped for a person has
        been read.
      </p>

      <p :if={@groups == [] and @show_all} class="empty">
        Nothing has run yet.
      </p>

      <section :for={{trigger, runs} <- @groups} class="panel">
        <h2>{trigger}</h2>

        <div class="scroller">
          <table>
            <thead>
              <tr>
                <th>fired</th>
                <th>by</th>
                <th>ran</th>
                <th>how it ended</th>
                <th>cost</th>
                <th>read by</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={run <- runs}>
                <th scope="row">{run["fired_at"]}</th>
                <td>{run["fired_by"]}</td>
                <td>{revision_of(run)}</td>
                <td>{outcome(run)}</td>
                <td><.amount micros={run["cost_micros"]} /></td>
                <td>
                  <span :if={reviewed?(run)}>{run["reviewed_by"]}</span>
                  <span :if={not reviewed?(run)} class="none">nobody</span>
                </td>
                <td class="actions">
                  <button
                    :if={not reviewed?(run) and run["session_id"]}
                    phx-click="review"
                    phx-value-session={run["session_id"]}
                  >
                    mark read
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <p class="field-help">
        How a run ended, what it cost, and whether anybody has looked at it. Not what the
        session said — reading the work itself means being on that session's list, which no
        administrative role grants.
      </p>
    </.shell>
    """
  end

  # The number, and the hash where there is no number. A run from before revisions were
  # recorded has neither, and an em dash is the honest answer rather than a zero.
  defp revision_of(%{"revision" => number}) when is_integer(number), do: "r#{number}"

  defp revision_of(%{"revision_hash" => hash}) when is_binary(hash),
    do: String.slice(hash, 0, 11)

  defp revision_of(_run), do: "—"
end
