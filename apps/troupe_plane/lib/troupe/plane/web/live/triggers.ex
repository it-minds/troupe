defmodule Troupe.Plane.Web.Live.Triggers do
  @moduledoc """
  A team's triggers, and what they last did.

  Modest on purpose: a trigger's home is a file in git and `troupe admin trigger put`,
  and this page is for the two things a person does from a browser — switching one off
  when it misbehaves and firing one now to see it work — plus the runs, because "did it
  run last night" is the question that brings somebody here. Everything goes through
  `Admin`, so what a team admin sees is their team and nothing else.
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    teams = teams_of(socket.assigns.actor)
    team = params["team"] || List.first(teams)

    {:ok,
     socket
     |> assign(teams: teams, team: team, flash_message: nil, confirming: nil)
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"team" => team}, _uri, socket) do
    {:noreply, socket |> assign(team: team, confirming: nil) |> load()}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("pick", %{"team" => team}, socket) do
    {:noreply, push_patch(socket, to: "/admin/triggers/#{team}")}
  end

  def handle_event("enable", %{"name" => name}, socket), do: toggle(socket, name, true)
  def handle_event("disable", %{"name" => name}, socket), do: toggle(socket, name, false)

  def handle_event("run", %{"name" => name}, socket) do
    case Admin.trigger_run(socket.assigns.actor, socket.assigns.team, name) do
      {:ok, %{"state" => state} = fired} ->
        message =
          case fired["session_id"] do
            nil -> "#{name}: #{state}"
            session_id -> "#{name} fired; session #{session_id} is #{state}"
          end

        {:noreply, socket |> assign(flash_message: message) |> load()}

      {:error, error} ->
        {:noreply, assign(socket, flash_message: error.message)}
    end
  end

  # Two steps, because a deleted trigger's runs go with it and a misclick should not.
  def handle_event("confirm-delete", %{"name" => name}, socket) do
    {:noreply, assign(socket, confirming: name)}
  end

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, confirming: nil)}

  def handle_event("delete", %{"name" => name}, socket) do
    case Admin.trigger_delete(socket.assigns.actor, socket.assigns.team, name) do
      {:ok, _} ->
        {:noreply, socket |> assign(flash_message: "deleted #{name}", confirming: nil) |> load()}

      {:error, error} ->
        {:noreply, assign(socket, flash_message: error.message, confirming: nil)}
    end
  end

  defp toggle(socket, name, enabled?) do
    attrs = %{"team" => socket.assigns.team, "name" => name, "enabled" => enabled?}

    case Admin.trigger_put(socket.assigns.actor, attrs) do
      {:ok, _} ->
        verb = if enabled?, do: "enabled", else: "disabled"
        {:noreply, socket |> assign(flash_message: "#{name} #{verb}") |> load()}

      {:error, error} ->
        {:noreply, assign(socket, flash_message: error.message)}
    end
  end

  defp teams_of(actor) do
    case Admin.teams_list(actor) do
      {:ok, teams} -> Enum.map(teams, & &1.name)
      {:error, _error} -> []
    end
  end

  defp load(%{assigns: %{team: nil}} = socket) do
    assign(socket, triggers: [], runs: %{}, error: nil)
  end

  defp load(%{assigns: %{team: team}} = socket) do
    with {:ok, triggers} <- Admin.triggers_list(socket.assigns.actor, team),
         {:ok, runs} <- Admin.runs_list(socket.assigns.actor, team: team, limit: 100) do
      assign(socket, triggers: triggers, runs: Enum.group_by(runs, & &1["trigger"]), error: nil)
    else
      {:error, error} -> assign(socket, triggers: [], runs: %{}, error: error.message)
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.shell actor={@actor} breakglass={@breakglass} page={:triggers}>
      <p :if={@error} class="error">{@error}</p>
      <p :if={@flash_message} class="notice">{@flash_message}</p>

      <form id="trigger-team" :if={length(@teams) > 1} phx-change="pick">
        <label>
          team
          <select name="team">
            <option :for={team <- @teams} value={team} selected={@team == team}>{team}</option>
          </select>
        </label>
      </form>

      <p class="hint">
        Definitions live in git and arrive by <code>troupe admin trigger put</code>. From here:
        switch one off, fire one now, and see what the last runs did.
      </p>

      <div :for={trigger <- @triggers} class="trigger">
        <h2>
          {trigger["name"]}
          <span class={if trigger["enabled"], do: "good", else: "none"}>
            {if trigger["enabled"], do: "enabled", else: "disabled"}
          </span>
        </h2>

        <dl class="counts">
          <dt>as</dt>
          <dd>{trigger["principal"]}</dd>
          <dt>profile</dt>
          <dd>{trigger["profile"]}{if trigger["agent"], do: " / #{trigger["agent"]}"}</dd>
          <dt>source</dt>
          <dd>{source(trigger["source"])}</dd>
          <dt>terms</dt>
          <dd>{terms(trigger["terms"])}</dd>
          <dt>concurrency</dt>
          <dd>{trigger["concurrency"]}</dd>
          <dt>review</dt>
          <dd>{trigger["review"]}</dd>
          <dt>notify</dt>
          <dd>{if trigger["notify"] == [], do: "nobody", else: Enum.join(trigger["notify"], ", ")}</dd>
          <dt>last fired</dt>
          <dd>{trigger["last_fired_at"] || "never"}</dd>
        </dl>

        <p>
          <button :if={trigger["enabled"]} phx-click="disable" phx-value-name={trigger["name"]}>
            disable
          </button>
          <button :if={!trigger["enabled"]} phx-click="enable" phx-value-name={trigger["name"]}>
            enable
          </button>
          <button phx-click="run" phx-value-name={trigger["name"]}>run now</button>
          <button
            :if={@confirming != trigger["name"]}
            phx-click="confirm-delete"
            phx-value-name={trigger["name"]}
          >
            delete
          </button>
          <span :if={@confirming == trigger["name"]}>
            its runs go with it —
            <button phx-click="delete" phx-value-name={trigger["name"]}>delete it</button>
            <button phx-click="cancel">no</button>
          </span>
        </p>

        <table>
          <thead>
            <tr>
              <th>fired</th>
              <th>by</th>
              <th>state</th>
              <th>session</th>
              <th>done</th>
              <th>approvals</th>
              <th>cost</th>
              <th>reviewed</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={run <- Enum.take(Map.get(@runs, trigger["name"], []), 10)} class={run_class(run)}>
              <td>{run["fired_at"]}</td>
              <td>{run["fired_by"]}</td>
              <td>{run["state"]}</td>
              <td>{run["session_id"] || "—"}</td>
              <td>{run["done_reason"] || "—"}</td>
              <td>{run["pending_approvals"] || 0}</td>
              <td>{money(run["cost_micros"])}</td>
              <td>{run["reviewed_by"] || "—"}</td>
            </tr>
            <tr :if={Map.get(@runs, trigger["name"], []) == []}>
              <td colspan="8" class="none">never run</td>
            </tr>
          </tbody>
        </table>
      </div>

      <p :if={@triggers == [] and @team} class="none">no triggers in {@team}</p>
      <p :if={is_nil(@team)} class="none">no team to show</p>
    </.shell>
    """
  end

  defp source(%{"kind" => "schedule"} = source),
    do: "cron #{source["cron"]} (#{source["tz"] || "UTC"})"

  defp source(%{"kind" => "webhook"} = source),
    do: "webhook from #{source["provider"] || "anywhere"}"

  defp source(_source), do: "—"

  defp terms(terms) when terms in [nil, %{}], do: "defaults"

  defp terms(terms) do
    Enum.map_join(terms, ", ", fn {key, value} -> "#{key} #{value}" end)
  end

  defp run_class(%{"state" => "failed"}), do: "bad"
  defp run_class(%{"state" => "done"}), do: "good"
  defp run_class(_run), do: "neutral"
end
