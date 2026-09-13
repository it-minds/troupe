defmodule Troupe.Plane.Web.Live.Bundles do
  @moduledoc """
  Config bundles: what the current version carries, what each pod is running, and
  rolling back.

  The page shows the *current* version as structure — its agents, skills and MCP
  servers, with the Secret an admin must create for each server — because that is the
  question a person arrives with: "what does a session on this channel get?". Older
  versions are a list with their summaries. Publishing still takes the document as JSON:
  a bundle lives in git and is published from a directory with `troupe admin bundle
  publish`, and the textarea is for the first one and the quick fix. A draft can be
  checked before it is published, and the errors are the ones publishing would give,
  because they come from the same method.

  Rolling back is retiring: a version that is retired is one nothing new starts on, and
  the sessions already running on it are untouched. There is no "revert" that rewrites a
  version, because versions are immutable — a session pinned to v2 has to keep meaning
  what v2 meant, or its next activation would silently be a different session.
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin

  @blank ~s({"schema": 1, "agents": [], "skills": [], "mcp_servers": []})

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(
       channel: params["channel"] || "stable",
       flash_message: nil,
       draft: @blank,
       errors: []
     )
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("channel", %{"channel" => channel}, socket) do
    {:noreply, socket |> assign(channel: channel) |> load()}
  end

  # One form, two buttons: `check` validates the draft and shows what it would publish,
  # `publish` publishes it. The button pressed arrives as `action`; a submit naming none
  # is a publish, so a client that does not send the submitter still gets the effect the
  # form is for.
  def handle_event("draft", %{"content" => content} = params, socket) do
    socket = assign(socket, draft: content)

    case Jason.decode(content) do
      {:ok, %{} = decoded} ->
        case params["action"] do
          "check" -> check(socket, decoded)
          _ -> publish(socket, decoded)
        end

      _ ->
        {:noreply, assign(socket, errors: ["that is not a JSON object"], flash_message: nil)}
    end
  end

  def handle_event("retire", %{"version" => version}, socket) do
    %{actor: actor, channel: channel} = socket.assigns
    respond(socket, Admin.bundle_retire(actor, channel, String.to_integer(version)))
  end

  defp check(socket, decoded) do
    case Admin.bundle_validate(socket.assigns.actor, decoded) do
      {:ok, result} ->
        message = "valid — #{describe_summary(result.summary)} — #{result.hash}"
        {:noreply, assign(socket, errors: [], flash_message: message)}

      {:error, error} ->
        {:noreply, assign(socket, errors: errors_of(error), flash_message: nil)}
    end
  end

  defp publish(socket, decoded) do
    case Admin.bundle_publish(socket.assigns.actor, socket.assigns.channel, decoded) do
      {:ok, bundle} ->
        message = "published v#{bundle.version} — #{bundle.hash}"

        {:noreply,
         socket
         |> assign(flash_message: message, errors: [], draft: @blank)
         |> load()}

      {:error, error} ->
        {:noreply, assign(socket, errors: errors_of(error), flash_message: nil)}
    end
  end

  defp respond(socket, {:ok, bundle}) do
    {:noreply, socket |> assign(flash_message: "v#{bundle.version} — #{bundle.hash}") |> load()}
  end

  defp respond(socket, {:error, error}),
    do: {:noreply, assign(socket, flash_message: error.message)}

  # The validation errors as a list, or the one-line message for anything else — a
  # refusal is not a validation failure and should not be dressed as one.
  defp errors_of(%{data: %{errors: errors}}) when is_list(errors), do: errors
  defp errors_of(error), do: [error.message]

  defp load(socket) do
    actor = socket.assigns.actor
    channel = socket.assigns.channel

    case Admin.bundles_list(actor, channel) do
      {:ok, bundles} ->
        assign(socket, bundles: bundles, current: current_of(actor, channel, bundles), error: nil)

      {:error, error} ->
        assign(socket, bundles: [], current: nil, error: error.message)
    end
  end

  # The newest live version, in full. The list is newest first, so the first one that
  # is not retired is the one a new session would get.
  defp current_of(actor, channel, bundles) do
    case Enum.find(bundles, &is_nil(&1.retired_at)) do
      nil ->
        nil

      bundle ->
        case Admin.bundle_get(actor, channel, bundle.version) do
          {:ok, detail} -> detail
          {:error, _error} -> nil
        end
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.shell actor={@actor} breakglass={@breakglass} page={:bundles}>
      <p :if={@error} class="error">{@error}</p>
      <p :if={@flash_message} class="notice">{@flash_message}</p>

      <form id="bundle-channel" phx-change="channel">
        <label>channel <input name="channel" value={@channel} /></label>
      </form>

      <div :if={@current} class="detail">
        <h2>current: v{@current.version} <small>{@current.hash}</small></h2>
        <p :if={is_nil(@current.detail)} class="hint">
          This version was published by an older plane and cannot be read in full here.
        </p>

        <div :if={@current.detail}>
          <h3>Agents</h3>
          <table :if={@current.detail.agents != []}>
            <thead>
              <tr>
                <th>name</th>
                <th>mode</th>
                <th>description</th>
                <th>skills</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={agent <- @current.detail.agents}>
                <td>{agent.name}</td>
                <td>{agent.mode}</td>
                <td>{agent.description}</td>
                <td>{names(agent.skills)}</td>
              </tr>
            </tbody>
          </table>
          <p :if={@current.detail.agents == []} class="none">
            none of its own — sessions start as the built-in <code>build</code> or <code>plan</code>
          </p>

          <h3>Skills</h3>
          <table :if={@current.detail.skills != []}>
            <thead>
              <tr>
                <th>name</th>
                <th>description</th>
                <th>files</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={skill <- @current.detail.skills}>
                <td>{skill.name}</td>
                <td>{skill.description}</td>
                <td>{Enum.join(skill.files, ", ")}</td>
              </tr>
            </tbody>
          </table>
          <p :if={@current.detail.skills == []} class="none">none</p>

          <h3>MCP servers</h3>
          <table :if={@current.detail.mcp_servers != []}>
            <thead>
              <tr>
                <th>name</th>
                <th>url</th>
                <th>credential</th>
                <th>secret to create</th>
                <th>permission</th>
                <th>tools</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={server <- @current.detail.mcp_servers}>
                <td>{server.name}</td>
                <td>{server.url}</td>
                <td>{server.credential_ref || "—"}</td>
                <td>{server.secret || "—"}</td>
                <td>{server.permission}</td>
                <td>{names(server.tools)}</td>
              </tr>
            </tbody>
          </table>
          <p :if={@current.detail.mcp_servers == []} class="none">none</p>
          <p :if={@current.detail.mcp_servers != []} class="hint">
            A server's token is a Kubernetes Secret named above, key <code>token</code>, in the
            profile's worker namespace. Troupe never creates or reads one; a profile whose
            Secret is missing says so in its conditions. A person's own MCP servers are not
            configured here — they are registered by their client, under consent, per session.
          </p>
        </div>

        <h3>Adoption</h3>
        <ul :if={@current.adoption != []}>
          <li :for={report <- @current.adoption}>
            <strong>{report.profile}</strong>
            <span :if={report.pods == 0} class="none">— no pods enrolled</span>
            <span :if={report.adopted? and report.pods > 0} class="good">— every pod has it</span>
            <span :for={pod <- report.current}>{pod} ✓</span>
            <span :for={pod <- report.ahead}>{pod} (ahead)</span>
            <span :for={pod <- report.stale} class="bad">{pod.pod} behind ({short(pod.reported)})</span>
          </li>
        </ul>
        <p :if={@current.adoption == []} class="none">no profile follows {@channel}</p>
      </div>

      <h2>Versions</h2>
      <table>
        <thead>
          <tr>
            <th>version</th>
            <th>hash</th>
            <th>carries</th>
            <th>published</th>
            <th>by</th>
            <th>state</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={bundle <- @bundles} class={if bundle.retired_at, do: "neutral", else: "good"}>
            <td>v{bundle.version}</td>
            <td>{bundle.hash}</td>
            <td>{describe_summary(bundle.summary)}</td>
            <td>{bundle.published_at}</td>
            <td>{bundle.published_by}</td>
            <td>{if bundle.retired_at, do: "retired", else: "live"}</td>
            <td>
              <button
                :if={is_nil(bundle.retired_at) and @actor.role == :platform_admin}
                phx-click="retire"
                phx-value-version={bundle.version}
              >
                retire
              </button>
            </td>
          </tr>
          <tr :if={@bundles == []}>
            <td colspan="7">nothing published on {@channel}</td>
          </tr>
        </tbody>
      </table>

      <form id="bundle-draft" :if={@actor.role == :platform_admin} phx-submit="draft">
        <label>
          new version (JSON)
          <textarea name="content" rows="12">{@draft}</textarea>
        </label>
        <ul :if={@errors != []} class="violations">
          <li :for={message <- @errors}>{message}</li>
        </ul>
        <button type="submit" name="action" value="check">check</button>
        <button type="submit" name="action" value="publish">publish to {@channel}</button>
      </form>

      <p class="hint">
        Publishing tells every pod on this channel. Running sessions keep the version they
        started on; retiring one stops anything new starting on it and leaves those alone.
        A bundle kept in git is published from its directory with
        <code>troupe admin bundle publish {@channel} ./bundle</code>.
      </p>
    </.shell>
    """
  end

  defp names(:all), do: "all"
  defp names(list) when is_list(list), do: Enum.join(list, ", ")
  defp names(other), do: to_string(other)

  # The summary column: counts, and "summarised by an older plane" for a row that
  # predates the column rather than a confident zero.
  defp describe_summary(summary) when summary == %{} or is_nil(summary),
    do: "summarised by an older plane"

  defp describe_summary(summary) do
    [{"agents", "agent"}, {"skills", "skill"}, {"mcp_servers", "MCP server"}]
    |> Enum.map_join(", ", fn {key, noun} -> count(Map.get(summary, key, []), noun) end)
  end

  defp count(names, noun) when is_list(names) do
    case length(names) do
      1 -> "1 #{noun}"
      n -> "#{n} #{noun}s"
    end
  end

  defp count(_other, noun), do: "0 #{noun}s"

  defp short(nil), do: "nothing"
  defp short("sha256:" <> digest), do: String.slice(digest, 0, 8)
  defp short(other), do: other
end
