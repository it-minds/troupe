defmodule Troupe.Plane.Web.Live.Budgets do
  @moduledoc """
  Every ceiling that applies, the spend against each, and — the useful part — which one
  binds first.

  Spend lived inside Teams, where a team's own ceiling is a field on the team. That is the
  right place to *set* it and the wrong place to answer the question somebody actually
  arrives with, which is never "what is this team's cap" but **"why was that refused"**.
  Three rungs can refuse a session — a person's own cap, their team's, and the platform's —
  and a page that showed one of them left the other two to be guessed at.

  ## A refusal names its scope

  "Budget exhausted" without a scope is a support ticket. "Ada's personal cap, 40 of 40
  this month, inside a team at 180 of 500" is an answer, and the difference is that the
  second one says which number to change and whose it is. So the explanation is a rung per
  row, narrowest first, with the one that binds named in text.

  ## The bar is never alone

  The design's rule, and it is load-bearing here of all places: a bar alone says "quite
  full", which is not a number anybody can act on and is nothing at all to a reader who
  cannot see the colour. Every ceiling on this page is a bar with the figures beside it,
  and the binding one is marked in words as well.

  ## What this screen does not do

  Set a person's cap. That form is on Teams, because somebody wondering who is near their
  ceiling is looking at a team when they wonder it — and a second editor for one value is
  how two screens come to disagree about what it is.
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(teams: [], error: nil, explaining: nil, ceilings: [])
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("explain", %{"team" => team, "subject" => subject}, socket) do
    case Admin.budget_explain(socket.assigns.actor, presence(subject), presence(team)) do
      {:ok, ceilings} ->
        {:noreply, assign(socket, ceilings: ceilings, explaining: {team, subject}, error: nil)}

      {:error, error} ->
        {:noreply, assign(socket, ceilings: [], explaining: nil, error: describe(error))}
    end
  end

  defp load(socket) do
    case Admin.teams_list(socket.assigns.actor) do
      {:ok, teams} -> assign(socket, teams: teams, error: nil)
      {:error, error} -> assign(socket, teams: [], error: describe(error))
    end
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value) when is_binary(value), do: value

  defp describe(%{message: message, data: %{reason: reason}}), do: "#{message}: #{reason}"
  defp describe(%{message: message}), do: message

  # Which rung refuses first: the one with the least left. A rung with no ceiling has
  # `:unlimited` remaining and never binds, which is `absence means everything` in the
  # place it costs the most to get wrong — a person with no personal cap should not be
  # reported as the reason their session was refused.
  defp binds_first(ceilings) do
    ceilings
    |> Enum.filter(&is_integer(&1.remaining_micros))
    |> Enum.min_by(& &1.remaining_micros, fn -> nil end)
  end

  defp binds?(nil, _ceiling), do: false
  defp binds?(binding, ceiling), do: binding.scope == ceiling.scope

  # The person's own list, from the teams already loaded: a subject this reader cannot see
  # is a subject they cannot ask about, and the picker should not offer one.
  defp people(teams) do
    teams
    |> Enum.flat_map(& &1.members)
    |> Enum.map(& &1.subject)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # What the rung is, said as a person would say it rather than as the atom spells it.
  defp scope_name(:person), do: "this person's own cap, in every team"
  defp scope_name(:team), do: "the team's ceiling"
  defp scope_name(:platform), do: "the platform's, or the deployment's"
  defp scope_name(other), do: to_string(other)

  # The platform rung is two caps over one number — the deployment's and the platform's —
  # so the summary says which of the two wrote the one in force.
  defp bound_note(%{scope: :platform, bound_by: bound}) when not is_nil(bound),
    do: " · set by the #{bound}"

  defp bound_note(_ceiling), do: ""

  # "no ceiling left" is two answers run together, and the one it reads as is the wrong
  # one: a rung with no ceiling has everything left, not nothing.
  defp remaining(%{remaining_micros: :unlimited}), do: "no ceiling here"
  defp remaining(%{remaining_micros: micros}), do: "#{figure(micros)} left"

  @impl Phoenix.LiveView
  def render(assigns) do
    # Worked out once, here, rather than in the template: which rung refuses first is one
    # fact, and a template that asked three times could render three answers.
    assigns = assign(assigns, :binding, binds_first(assigns.ceilings))

    ~H"""
    <.shell actor={@actor} breakglass={@breakglass} page={:budgets}>
      <h1>Budgets</h1>
      <p class="lede">
        Every ceiling that applies, the spend against it, and which one would refuse first.
        A refusal names its scope here for the same reason it does anywhere else: without
        one, "budget exhausted" is a support ticket rather than an answer.
      </p>

      <p :if={@error} class="banner banner--breakglass" role="alert">{@error}</p>

      <section class="panel">
        <h2>Every team</h2>
        <p class="hint">
          Reserved money counts towards the fill, because it is money the platform has
          already promised on this team's behalf. A team whose bar looked comfortable while
          its next session was about to be refused would be worse than no bar.
        </p>

        <div class="scroller">
          <table>
            <thead>
              <tr>
                <th>team</th>
                <th>spend against its ceiling</th>
                <th>spent</th>
                <th>reserved</th>
                <th>people</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={team <- @teams}>
                <th scope="row">{team.name}</th>
                <td><.budget team={team} /></td>
                <td><.amount micros={team.spent_micros} /></td>
                <td><.amount micros={team.reserved_micros} /></td>
                <td>{length(team.members)}</td>
              </tr>
              <tr :if={@teams == []}>
                <td colspan="5" class="none">No team is enabled yet.</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="panel">
        <h2>Which ceiling binds</h2>
        <p class="hint">
          Three rungs can refuse a session. This asks all of them, in the order they are
          checked, and names the one that would refuse first — which is the number to
          change and whose it is.
        </p>

        <form id="explain-budget" phx-submit="explain">
          <label for="explain-budget-team">Team</label>
          <select id="explain-budget-team" name="team">
            <option value="">no team — the platform's ceiling alone</option>
            <option :for={team <- @teams} value={team.name}>{team.name}</option>
          </select>

          <label for="explain-budget-subject">Person</label>
          <select id="explain-budget-subject" name="subject">
            <option value="">nobody in particular</option>
            <option :for={subject <- people(@teams)} value={subject}>{subject}</option>
          </select>

          <button type="submit">explain</button>
        </form>

        <div :if={@explaining} class="ceilings">
          <p class="hint">
            <span :if={@binding}>
              <strong>{scope_name(@binding.scope)}</strong>
              is what refuses first, with {remaining(@binding)}.
            </span>
            <span :if={is_nil(@binding)}>
              No rung here has a ceiling at all, so nothing refuses on spend.
            </span>
          </p>

          <div :for={ceiling <- @ceilings} class="ceiling">
            <h3>
              {scope_name(ceiling.scope)}
              <span :if={binds?(@binding, ceiling)} class="rung rung--platform">
                binds first
              </span>
            </h3>

            <p class="micro">{ceiling.scope}{bound_note(ceiling)} · {remaining(ceiling)}</p>

            <.budget team={as_bar(ceiling)} />
          </div>
        </div>
      </section>
    </.shell>
    """
  end

  # The bar component takes a team's shape, because a ceiling is a ceiling whichever rung
  # wrote it and two renderings of one bar would eventually disagree about what full is.
  # Each rung says what its spend covers: a person's and the platform's are the month, a
  # team's is whatever the team's period is, and "this period" was all three at once.
  defp as_bar(ceiling) do
    %{
      spent_micros: ceiling.spent_micros,
      reserved_micros: ceiling.reserved_micros,
      budget_micros: ceiling.budget_micros,
      budget_period: ceiling.budget_period
    }
  end
end
