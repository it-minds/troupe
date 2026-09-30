defmodule Troupe.Plane.Web.Live.Workers do
  @moduledoc """
  Profiles, their pods, and what is wrong with them.

  The page an operator uses during an incident, so it shows the three things that can
  disagree side by side: what the profile asks for, what the cluster policy makes of it,
  and what the pods are actually running. A view that merged them would make "the image
  is not allowed", "the operator has not reconciled yet" and "the pods are still on the
  old version" look like the same problem.

  Refreshed on a short timer: a killed pod should be visible here in about the time it
  takes to notice it is gone.

  In GitOps mode the page says the profiles are locked and where they come from, and
  under each one what the last pass could not use (Decision 736). Its last panel is the
  way into GitOps mode from the other side: every profile, the policy and every trigger
  as a repository would hold them (Decision 737), to commit before the plane is switched.

  It is also the way to the profile editor, for a platform admin: each profile links to
  it, and in direct mode so does a new one. The editor was reachable by its address and
  from nowhere else.
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin

  @refresh_ms 1_000

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_ms, :refresh)

    {:ok,
     socket
     |> assign(selected: params["profile"], detail: nil, flash_message: nil, export: nil)
     |> assign(mode: mode(socket))
     |> load()}
  end

  defp mode(socket) do
    case Admin.provisioning_mode(socket.assigns.actor) do
      {:ok, mode} -> mode
      {:error, _error} -> :unknown
    end
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(selected: params["profile"]) |> load()}
  end

  @impl Phoenix.LiveView
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl Phoenix.LiveView
  def handle_event("drain", %{"worker" => worker_id}, socket) do
    case Admin.pod_drain(socket.assigns.actor, worker_id) do
      {:ok, report} ->
        {:noreply,
         socket
         |> assign(flash_message: "drained #{report.pod}: #{report.drained} session(s)")
         |> load()}

      {:error, error} ->
        {:noreply, assign(socket, flash_message: "could not drain: #{error.message}")}
    end
  end

  # Asked for rather than rendered on every refresh: it is every profile as YAML, which
  # somebody reads once, and this page reloads every second.
  def handle_event("export", _params, socket) do
    case Admin.profiles_export(socket.assigns.actor) do
      {:ok, export} ->
        {:noreply, assign(socket, export: export)}

      {:error, error} ->
        {:noreply, assign(socket, flash_message: "could not export: #{error.message}")}
    end
  end

  def handle_event("hide-export", _params, socket), do: {:noreply, assign(socket, export: nil)}

  defp load(socket) do
    case Admin.profiles_list(socket.assigns.actor) do
      {:ok, profiles} -> assign(socket, profiles: profiles, detail: detail(socket), error: nil)
      {:error, error} -> assign(socket, profiles: [], detail: nil, error: error.message)
    end
  end

  # Only a platform admin can see a profile's spec and policy verdict, so a team admin
  # gets the pod list and no detail panel rather than an error.
  defp detail(%{assigns: %{selected: nil}}), do: nil

  defp detail(socket) do
    case Admin.profile_get(socket.assigns.actor, socket.assigns.selected) do
      {:ok, detail} -> detail
      {:error, _error} -> nil
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.shell actor={@actor} breakglass={@breakglass} page={:workers}>
      <p :if={@error} class="error">{@error}</p>
      <p :if={@flash_message} class="notice">{@flash_message}</p>

      <p :if={@mode == :gitops} id="locked-to-gitops" class="banner" role="status">
        <strong>Locked to gitops.</strong>
        These profiles are the WorkerProfile resources a repository holds{source_of(@profiles)};
        a change to one is a commit there. The plane writes only how many workers each runs,
        which teams' volumes it mounts and its MCP servers.
      </p>

      <p :if={editor?(@actor) and @mode != :gitops}>
        <a href="/admin/profile/new">New profile</a>
      </p>

      <div :for={profile <- @profiles} class="profile">
        <h2>
          <a href={"/admin/workers/#{profile.name}"}>{profile.name}</a>
          <small>{profile.image} · channel {profile.channel}</small>
          <a :if={editor?(@actor)} href={"/admin/profile/#{profile.name}"}>
            {if @mode == :gitops, do: "view", else: "edit"}
          </a>
        </h2>

        <ul :if={problem?(profile)} class="checks">
          <li :for={reason <- profile.gitops.reasons} class="checks__bad">
            <span class="checks__name">{problem_name(profile.gitops)}</span>
            <span class="checks__detail">{reason}</span>
          </li>
        </ul>

        <.conditions conditions={profile.conditions} />

        <table>
          <thead>
            <tr>
              <th>pod</th>
              <th>state</th>
              <th>sessions</th>
              <th>disk</th>
              <th>version</th>
              <th>bundle</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={pod <- profile.pods} class={pod_class(pod)}>
              <td>{pod.pod}</td>
              <td>{pod_state(pod)}</td>
              <td>{pod.active_sessions} / {pod.capacity}</td>
              <td>{percent(pod.disk_fraction)}</td>
              <td>{pod.version || "—"}</td>
              <td>{short(pod.bundle_hash)}</td>
              <td>
                <button :if={@actor.role == :platform_admin} phx-click="drain" phx-value-worker={pod.worker_id}>
                  drain
                </button>
              </td>
            </tr>
            <tr :if={profile.pods == []}>
              <td colspan="7">no pods enrolled</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@detail} class="detail">
        <h2>{@selected}</h2>

        <h3>Policy</h3>
        <p :if={@detail.policy.allowed?} class="good">allowed</p>
        <ul :if={not @detail.policy.allowed?} class="violations">
          <li :for={violation <- @detail.policy.violations}>{describe(violation)}</li>
        </ul>

        <h3>Config bundle</h3>
        <p :if={@detail.bundle.published}>
          channel {@detail.bundle.channel}, published v{@detail.bundle.published}
          <span :if={Map.get(@detail.bundle, :adopted?)} class="good">— every pod has it</span>
          <span :if={Map.get(@detail.bundle, :stale, []) != []} class="bad">
            — {length(@detail.bundle.stale)} pod(s) behind
          </span>
        </p>
        <p :if={is_nil(@detail.bundle.published)}>nothing published on {@detail.bundle.channel}</p>

        <h3>Spec</h3>
        <pre>{Jason.encode!(@detail.spec, pretty: true)}</pre>
      </div>

      <section :if={@actor.role == :platform_admin} id="manifests" class="panel">
        <h2>Manifests for a repository</h2>
        <p class="lede">
          Every profile, the cluster policy and every trigger as a repository would hold
          them: what to commit before this plane is switched to gitops mode, so that the
          resources it reads are the ones it runs now. Nothing the plane or the cluster
          writes is in them, and no trigger's key: that stays with the plane.
        </p>

        <button :if={is_nil(@export)} type="button" phx-click="export">show the manifests</button>
        <button :if={@export} type="button" phx-click="hide-export">hide them</button>

        <div :if={@export}>
          <p class="hint">
            Left out, because the plane or the cluster writes them and a repository that
            held them would put its own back at every apply: {Enum.join(@export.left_out, ", ")}.
          </p>

          <div :for={manifest <- manifests(@export)}>
            <h3 class="mono">{manifest.path}</h3>
            <p :for={note <- manifest.notes} class="hint">{note}</p>
            <pre>{manifest.yaml}</pre>
          </div>
        </div>
      </section>
    </.shell>
    """
  end

  # The editor is a platform admin's page, and only a platform admin is sent to it. In
  # GitOps mode it shows what the plane read, locked, and a new profile is a manifest.
  defp editor?(actor), do: actor.role == :platform_admin

  # Everything the export has, the triggers included: a repository bootstrapped from this
  # panel without them would lose every trigger at the switch.
  defp manifests(%{profiles: profiles, policy: policy, triggers: triggers}),
    do: profiles ++ List.wrap(policy) ++ triggers

  defp problem?(%{gitops: %{problem: problem}}), do: not is_nil(problem)
  defp problem?(_profile), do: false

  # From the first profile that says, which is every one of them in GitOps mode: the
  # source is the deployment's, not the profile's.
  defp source_of(profiles) do
    case Enum.find_value(profiles, &get_in(&1, [:gitops, :source])) do
      nil -> ""
      source -> ", applied from #{source}"
    end
  end

  defp problem_name(%{problem: "refused", problem_generation: generation}),
    do: "generation #{generation} is not used"

  defp problem_name(%{problem: "missing"}), do: "no resource in the cluster"
  defp problem_name(%{problem: "plane_only"}), do: "not applied from a repository"
  defp problem_name(%{problem: problem}), do: problem

  defp pod_class(%{healthy: false}), do: "bad"
  defp pod_class(%{draining: true}), do: "neutral"
  defp pod_class(_pod), do: "good"

  defp pod_state(%{healthy: false}), do: "unhealthy"
  defp pod_state(%{draining: true}), do: "draining"
  defp pod_state(_pod), do: "ready"

  defp percent(nil), do: "—"
  defp percent(fraction), do: "#{round(fraction * 100)}%"

  defp short(nil), do: "—"
  defp short("sha256:" <> digest), do: String.slice(digest, 0, 8)
  defp short(other), do: other

  # A violation is a tuple from the policy checker; the panel is where it becomes a
  # sentence. Kept here rather than in the checker so the checker stays a pure function
  # over documents.
  defp describe({reason, actual, allowed}),
    do: "#{humanise(reason)}: #{inspect(actual)} (allowed: #{inspect(allowed)})"

  defp describe({reason, actual}), do: "#{humanise(reason)}: #{inspect(actual)}"
  defp describe(other), do: inspect(other)

  defp humanise(reason), do: reason |> Atom.to_string() |> String.replace("_", " ")
end
