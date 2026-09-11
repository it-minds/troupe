defmodule Troupe.Plane.Web.Live.ProfileEditor do
  @moduledoc """
  Editing a profile, and seeing what it will become before applying it.

  The form renders the resulting custom resource as a diff and does not apply anything
  until that has been looked at. A profile is a description of how somebody else's work
  runs — the image, the egress, the volumes — and a panel that applied on submit would
  make a typo in a field nobody was looking at into a fleet-wide change.

  Policy is checked as the form changes, so a disallowed image is red while it is being
  typed rather than after a round trip. That check is *the same* check admission makes,
  not an approximation: both parse the same `TroupePolicy` with the same code.
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    name = params["profile"]

    {:ok,
     socket
     |> assign(name: name, flash_message: nil, applied: nil)
     |> load(name)}
  end

  @impl Phoenix.LiveView
  def handle_event("change", params, socket) do
    {:noreply, assign(socket, draft: draft_from(socket, params, socket.assigns.draft))}
  end

  def handle_event("apply", _params, socket) do
    case Admin.profile_put(socket.assigns.actor, socket.assigns.draft) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(applied: result.provisioning, flash_message: applied_message(result))
         |> load(socket.assigns.name)}

      {:error, error} ->
        {:noreply, assign(socket, flash_message: describe(error))}
    end
  end

  defp applied_message(%{changes: changes}) when changes == %{}, do: "nothing changed"

  defp applied_message(%{changes: changes, provisioning: %{state: :pending, commit: commit}}) do
    "#{map_size(changes)} field(s) committed as #{String.slice(commit, 0, 8)} — pending until Flux applies it"
  end

  defp applied_message(%{changes: changes}), do: "#{map_size(changes)} field(s) applied"

  defp describe(%{message: message, data: %{policy_violations: violations}}) do
    "#{message}: #{Enum.map_join(violations, "; ", &inspect/1)}"
  end

  defp describe(%{message: message}), do: message

  defp load(socket, nil) do
    assign(socket, current: nil, draft: %{}, verdict: nil, mode: mode(socket))
  end

  defp load(socket, name) do
    case Admin.profile_get(socket.assigns.actor, name) do
      {:ok, detail} ->
        draft = Map.merge(%{"name" => name}, Map.new(detail.spec))

        socket
        |> assign(current: detail, draft: Map.get(socket.assigns, :draft, draft), verdict: detail.policy)
        |> assign(mode: mode(socket))

      {:error, error} ->
        socket
        |> assign(current: nil, draft: %{"name" => name}, verdict: nil, mode: mode(socket))
        |> assign(flash_message: error.message)
    end
  end

  defp mode(socket) do
    case Admin.provisioning_mode(socket.assigns.actor) do
      {:ok, mode} -> mode
      {:error, _error} -> :unknown
    end
  end

  # The panel's own check, run on every keystroke. Not the enforcement — admission is,
  # and the operator is again after that — but the same function, so what it says is what
  # will happen.
  defp draft_from(socket, params, previous) do
    draft =
      previous
      |> Map.merge(Map.take(params, ~w(name image replicas sessionsPerPod)))
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)

    case Admin.preview(socket.assigns.actor, atomise(draft)) do
      {:ok, preview} -> Map.put(draft, "__preview__", preview)
      {:error, _error} -> draft
    end
  end

  defp atomise(draft) do
    %{
      name: draft["name"],
      image: draft["image"],
      replicas: to_integer(draft["replicas"]),
      sessions_per_pod: to_integer(draft["sessionsPerPod"]),
      spec: Map.drop(draft, ~w(name image replicas sessionsPerPod __verdict__))
    }
  end

  defp to_integer(nil), do: nil

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp to_integer(value), do: value

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.shell actor={@actor} page={:workers}>
      <p :if={@flash_message} class="notice">{@flash_message}</p>

      <h2>{@name || "new profile"}</h2>
      <p class="hint">Provisioning mode: {@mode}.</p>

      <form phx-change="change" phx-submit="apply">
        <label>name <input name="name" value={@draft["name"]} /></label>
        <label>image <input name="image" value={@draft["image"]} /></label>
        <label>replicas <input name="replicas" value={@draft["replicas"]} /></label>
        <label>sessions per pod <input name="sessionsPerPod" value={@draft["sessionsPerPod"]} /></label>

        <.verdict verdict={verdict_of(@draft, @verdict)} />

        <h3>What will be applied</h3>
        <pre>{changes_text(@draft)}</pre>

        <button type="submit" disabled={not allowed?(verdict_of(@draft, @verdict))}>apply</button>
      </form>
    </.shell>
    """
  end

  attr :verdict, :any, default: nil

  defp verdict(assigns) do
    ~H"""
    <div :if={@verdict}>
      <p :if={@verdict.allowed?} class="good">policy: allowed</p>
      <ul :if={not @verdict.allowed?} class="violations">
        <li :for={violation <- @verdict.violations}>{inspect(violation)}</li>
      </ul>
    </div>
    """
  end

  defp allowed?(nil), do: true
  defp allowed?(%{allowed?: allowed}), do: allowed

  defp verdict_of(draft, fallback) do
    case draft["__preview__"] do
      %{policy: policy} -> policy
      _ -> fallback
    end
  end

  # The diff a person reads before pressing apply. It is the same diff `profile_put` will
  # record in the audit, computed by the same function — so what the form promised and
  # what the trail says cannot differ.
  defp changes_text(%{"__preview__" => %{changes: changes}}) when changes != %{} do
    Enum.map_join(changes, "\n", fn {field, %{"from" => from, "to" => to}} ->
      "#{field}: #{inspect(from)} → #{inspect(to)}"
    end)
  end

  defp changes_text(%{"__preview__" => _preview}), do: "no changes"
  defp changes_text(_draft), do: "type something to see what would change"
end
