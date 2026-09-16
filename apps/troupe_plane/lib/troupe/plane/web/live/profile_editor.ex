defmodule Troupe.Plane.Web.Live.ProfileEditor do
  @moduledoc """
  Editing a profile: every field of it, and what it will become before applying it.

  A profile is a description of how somebody else's work runs — which image, which model,
  what it may reach on the network, how much disk it gets — and for a while this page
  edited four of those and left the rest to whoever was willing to write JSON and post it
  to the API. That is not an administration console, it is a form beside one. So it now
  renders the whole `WorkerProfile` spec: scale, model, egress, storage, resources, MCP
  servers, and the channel the pods follow.

  ## Three things that make it safe to have all of that on one page

  **The form's state is one map and one list.** `@fields` is every scalar, keyed by the
  name the input carries, and `@servers` is the MCP rows. Both are rebuilt on change and
  both are what apply reads — so there is no second copy to drift, and a button that is not
  a submit (adding a row, checking a host) does not lose what has been typed, which is what
  happens when a handler tries to read a form it was not sent.

  **Empty is absent.** A blank field does not write an empty string into the custom
  resource; the branch it belongs to disappears entirely if nothing under it is set. The
  CRD has defaults, and `storage: {size: ""}` overrides them with nonsense.

  **Nothing is applied until the diff has been read.** The page shows what will change,
  field by field, computed by the same function that writes the audit record — so what the
  form promised and what the trail says cannot differ. Policy is checked as the form
  changes, with the same check admission will make.

  The apply control is one button and not the design's two, deliberately: which of the two
  happens is not the operator's choice, it is `provisioning_mode`. The button is named for
  what will actually happen and the consequence is written above it. Two buttons where one
  of them is a lie would be worse than one.
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin

  @providers ~w(openai anthropic fake)


  # Every scalar field, in the order it appears. The form's names are paths into the
  # resource, so a field and the thing it writes are spelled the same and there is no
  # translation table to get wrong.
  # Seven fields used to be here that are not any more: `replicas`, `sessionsPerPod`,
  # the four resource numbers and `storage.size`. They are all still in the custom
  # resource, written by the plane from the size class and from what is actually running
  # — because they were seven guesses an administrator was asked for before they could
  # reach anything they came here to configure, and the first of them was a capacity
  # question the plane already had the data to answer.
  @scalars ~w(
    name image sizeClass maxSessions warmWorkers
    llm.endpoint llm.provider llm.model llm.smallModel llm.secretRef.name llm.secretRef.key
    egress.fqdns egress.gitHosts
    storage.storageClassName
    configBundleChannel
  )

  @server_fields ~w(name url credentialRef header timeoutMs)

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(name: params["profile"], notice: nil, error: nil, applied: nil, checked: %{})
     |> load(params["profile"])}
  end

  @impl Phoenix.LiveView
  def handle_event("change", params, socket) do
    {:noreply,
     socket
     |> assign(fields: merge_fields(socket.assigns.fields, params))
     |> assign(servers: rows_from(params))
     |> preview()}
  end

  def handle_event("add-server", _params, socket) do
    {:noreply, socket |> assign(servers: socket.assigns.servers ++ [%{}]) |> preview()}
  end

  def handle_event("remove-server", %{"index" => index}, socket) do
    servers = List.delete_at(socket.assigns.servers, to_integer(index) || 0)
    {:noreply, socket |> assign(servers: servers) |> preview()}
  end

  # Whether the cluster would let a pod reach a server, asked of the plane rather than
  # guessed: the answer belongs to the egress policy, and a page that assumed it would be
  # confidently wrong on exactly the profiles where it matters.
  def handle_event("check-server", %{"url" => url}, socket) do
    case Admin.mcp_check(socket.assigns.actor, url) do
      {:ok, result} ->
        {:noreply, assign(socket, checked: Map.put(socket.assigns.checked, url, result))}

      {:error, error} ->
        {:noreply, assign(socket, error: describe(error))}
    end
  end

  def handle_event("apply", _params, socket) do
    case Admin.profile_put(socket.assigns.actor, draft(socket.assigns)) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(applied: result.provisioning, notice: applied_message(result), error: nil)
         |> load(socket.assigns.fields["name"])}

      {:error, error} ->
        {:noreply, assign(socket, error: describe(error), notice: nil)}
    end
  end

  # -- the form's state --------------------------------------------------------

  # A checkbox that is off sends nothing at all, so it is read from the form's presence
  # rather than from its value: without this, unmounting the org volume would be a change
  # the form could express and never send.
  defp merge_fields(fields, params) do
    fields
    |> Map.merge(Map.take(params, @scalars))
    |> Map.put("orgMount", Map.has_key?(params, "orgMount"))
  end

  # Rows arrive as `mcp.0.url`. Gathered by index and kept whole, empty ones included: a
  # row being typed into is a row, and dropping it because its URL is still blank would
  # take the field away mid-keystroke.
  defp rows_from(params) do
    params
    |> Enum.flat_map(fn
      {"mcp." <> rest, value} ->
        case String.split(rest, ".", parts: 2) do
          [index, field] when field in @server_fields -> [{to_integer(index), field, value}]
          _other -> []
        end

      _other ->
        []
    end)
    |> Enum.group_by(fn {index, _field, _value} -> index end)
    |> Enum.sort_by(fn {index, _fields} -> index end)
    |> Enum.map(fn {_index, fields} ->
      Map.new(fields, fn {_index, field, value} -> {field, value} end)
    end)
  end

  defp preview(socket) do
    draft = draft(socket.assigns)

    case Admin.preview(socket.assigns.actor, draft) do
      {:ok, preview} -> assign(socket, preview: preview, error: nil)
      {:error, error} -> assign(socket, preview: nil, error: describe(error))
    end
  end

  @doc """
  The profile the form describes, in the shape `admin.profile.put` takes.

  Public so a test can assert the mapping without driving a browser: this function is
  where a mis-spelled path in the form would turn into a field the cluster ignores.
  """
  @spec draft(map()) :: map()
  def draft(%{fields: fields, servers: servers}) do
    spec =
      compact(%{
        "llm" =>
          compact(%{
            "endpoint" => fields["llm.endpoint"],
            "provider" => fields["llm.provider"],
            "model" => fields["llm.model"],
            "smallModel" => fields["llm.smallModel"],
            "secretRef" =>
              compact(%{
                "name" => fields["llm.secretRef.name"],
                "key" => fields["llm.secretRef.key"]
              })
          }),
        "egress" =>
          compact(%{
            "fqdns" => split(fields["egress.fqdns"]),
            "gitHosts" => split(fields["egress.gitHosts"])
          }),
        # The size and the resources belong to the class; only the storage *class* is
        # still asked for here, because which storage a cluster has is a fact about the
        # cluster rather than a question about how demanding a session is.
        "storage" => compact(%{"storageClassName" => fields["storage.storageClassName"]}),
        "mcpServers" => servers_for(servers),
        "configBundleChannel" => fields["configBundleChannel"],
        # Always present: false is a value here, not an absence, and an absent `orgMount`
        # would mean a mounted volume could never be unmounted from this page.
        "orgMount" => fields["orgMount"] == true
      })

    compact(%{
      "name" => fields["name"],
      "image" => fields["image"],
      "size_class" => fields["sizeClass"],
      "max_sessions" => to_integer(fields["maxSessions"]),
      "warm_workers" => to_integer(fields["warmWorkers"]) || 0,
      "spec" => spec
    })
  end

  defp servers_for(servers) do
    servers
    |> Enum.map(fn server ->
      server
      |> Map.take(@server_fields)
      |> Map.new(fn {field, value} -> {field, cast_server(field, value)} end)
      |> compact()
    end)
    |> Enum.reject(&(&1["url"] in [nil, ""]))
  end

  defp cast_server("timeoutMs", value), do: to_integer(value)
  defp cast_server(_field, value), do: value

  # Absent, not empty. A blank field is one nobody filled in, and the difference between
  # "no storage class" and "the storage class is the empty string" is the difference
  # between the cluster's default and a resource the API server refuses.
  defp compact(%{} = map), do: Map.reject(map, fn {_key, value} -> empty?(value) end)

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?([]), do: true
  defp empty?(map) when map == %{}, do: true
  defp empty?(_value), do: false

  defp split(nil), do: []
  defp split(text) when is_binary(text), do: String.split(text, ~r/[\s,]+/, trim: true)
  defp split(list) when is_list(list), do: list

  defp to_integer(nil), do: nil
  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  # -- loading -----------------------------------------------------------------

  defp load(socket, nil) do
    socket
    |> assign(current: nil, verdict: nil, mode: mode(socket), preview: nil)
    |> assign(fields: %{"orgMount" => false}, servers: [])
  end

  defp load(socket, name) do
    case Admin.profile_get(socket.assigns.actor, name) do
      {:ok, detail} ->
        spec = detail.spec || %{}

        socket
        |> assign(current: detail, verdict: detail.policy, mode: mode(socket), preview: nil)
        |> assign(fields: fields_from(name, detail, spec), servers: servers_of(spec))

      {:error, error} ->
        socket
        |> assign(current: nil, verdict: nil, mode: mode(socket), preview: nil)
        |> assign(fields: %{"name" => name, "orgMount" => false}, servers: [])
        |> assign(error: error.message)
    end
  end

  defp fields_from(name, detail, spec) do
    %{
      "name" => name,
      "image" => detail.profile.image,
      "sizeClass" => detail.profile.size_class,
      "maxSessions" => detail.profile.max_sessions,
      "warmWorkers" => detail.profile.warm_workers,
      "llm.endpoint" => get_in(spec, ["llm", "endpoint"]),
      "llm.provider" => get_in(spec, ["llm", "provider"]),
      "llm.model" => get_in(spec, ["llm", "model"]),
      "llm.smallModel" => get_in(spec, ["llm", "smallModel"]),
      "llm.secretRef.name" => get_in(spec, ["llm", "secretRef", "name"]),
      "llm.secretRef.key" => get_in(spec, ["llm", "secretRef", "key"]),
      "egress.fqdns" => joined(get_in(spec, ["egress", "fqdns"])),
      "egress.gitHosts" => joined(get_in(spec, ["egress", "gitHosts"])),
      "storage.storageClassName" => get_in(spec, ["storage", "storageClassName"]),
      "configBundleChannel" => Map.get(spec, "configBundleChannel"),
      "orgMount" => Map.get(spec, "orgMount") == true
    }
  end

  defp servers_of(spec) do
    case Map.get(spec, "mcpServers") do
      list when is_list(list) -> list
      _absent -> []
    end
  end

  defp joined(nil), do: ""
  defp joined(list) when is_list(list), do: Enum.join(list, "\n")
  defp joined(other), do: to_string(other)

  defp mode(socket) do
    case Admin.provisioning_mode(socket.assigns.actor) do
      {:ok, mode} -> mode
      {:error, _error} -> :unknown
    end
  end

  defp applied_message(%{changes: changes}) when changes == %{}, do: "Nothing changed."

  defp applied_message(%{changes: changes, provisioning: %{state: :pending, commit: commit}}) do
    "#{count(changes)} committed as #{String.slice(commit, 0, 8)}. Nothing has changed in the cluster yet."
  end

  defp applied_message(%{changes: changes}), do: "#{count(changes)} applied."

  defp count(changes) do
    case map_size(changes) do
      1 -> "One field"
      n -> "#{n} fields"
    end
  end

  defp describe(%{message: message, data: %{policy_violations: violations}}) do
    "#{message}: #{Enum.map_join(violations, "; ", &violation/1)}"
  end

  defp describe(%{message: message, data: %{reason: reason}}), do: "#{message}: #{reason}"
  defp describe(%{message: message}), do: message

  defp violation(%{} = violation) do
    violation[:message] || violation["message"] || inspect(violation)
  end

  defp violation(other), do: to_string(other)

  # -- rendering ---------------------------------------------------------------

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns =
      assigns
      |> assign(:decision, decision(assigns))
      |> assign(:changes, changes_of(assigns))
      |> assign(:providers, @providers)
      |> assign(:size_classes, Admin.size_classes())

    ~H"""
    <.shell actor={@actor} breakglass={@breakglass} page={:workers}>
      <h1>{@name || "New profile"}</h1>
      <p class="lede">
        How work runs on this profile: which image, which model, what the pods may reach,
        and how much of the cluster each one takes.
      </p>

      <p :if={@notice} class="banner" role="status">{@notice}</p>
      <p :if={@error} class="banner banner--breakglass" role="alert">{@error}</p>

      <form id="profile-editor" phx-change="change" phx-submit="apply">
        <section class="panel">
          <h2>What runs</h2>

          <.field form={@fields} name="name" label="name">
            The profile's name, and the name of its WorkerProfile in the cluster. A
            different name is a different profile, not a rename.
          </.field>
          <.field form={@fields} name="image" label="image">
            repository:tag, or repository@sha256:… A digest pins the image; a tag does not,
            and a pod that restarts on a moved tag comes back running something else.
          </.field>
        </section>

        <section class="panel">
          <h2>Capacity</h2>
          <p class="lede">
            Three questions, and the plane answers the rest. How many workers run, how many
            sessions each carries, and how much CPU, memory and disk they get all follow
            from the size class and from what is actually running — written by the plane,
            the way it already writes which teams may use this.
          </p>
          <p class="lede">
            Every session gets its own workspace. Sessions cannot see each other's files,
            even on the same worker and even for the same person. Files in the team folder
            are shared, as a shared folder is.
          </p>

          <.choice form={@fields} name="sizeClass" label="how demanding" options={@size_classes}>
            Standard puts several sessions on a worker and is right for most work. Heavy
            gives each one more CPU, memory and disk, for large repositories, builds and
            long runs. This is a question about resources, not about safety.
          </.choice>

          <.field form={@fields} name="maxSessions" label="most sessions at once" type="number">
            How far this may grow, in sessions rather than workers. Empty is no ceiling,
            bounded by the team's budget. Somebody refused here is shown this number, so it
            is worth it being one you would stand behind.
          </.field>

          <.field form={@fields} name="warmWorkers" label="workers kept warm" type="number">
            How many to keep up when nothing is running. 0 costs the next session a cold
            start of roughly half a minute — the same wait as waking a dormant session, and
            described the same way.
          </.field>
        </section>

        <section class="panel">
          <h2>The model</h2>
          <p class="lede">
            Where a session's model calls go. Usually a gateway rather than a provider,
            which is what makes the cost of a call knowable.
          </p>

          <.field form={@fields} name="llm.endpoint" label="endpoint">
            The base URL. Egress has to allow its host, or every call times out.
          </.field>

          <.choice form={@fields} name="llm.provider" label="provider" options={@providers}>
            Which adapter speaks to it. openai is plain Chat Completions, which is what a
            gateway serves; anthropic is the Messages API; fake answers without a network.
          </.choice>

          <.field form={@fields} name="llm.model" label="model">
            What a session uses for its work.
          </.field>
          <.field form={@fields} name="llm.smallModel" label="small model">
            Used only to summarise a long conversation, where a cheaper model is enough.
          </.field>
          <.field form={@fields} name="llm.secretRef.name" label="credential: secret name">
            The name of a Secret in the worker's namespace. A reference, read at call time
            by the pod: neither the plane nor this page ever holds the value, and there is
            nothing here that could show it to you.
          </.field>
          <.field form={@fields} name="llm.secretRef.key" label="credential: key">
            The key inside that Secret. Empty means api-key.
          </.field>
        </section>

        <section class="panel">
          <h2>What the pods may reach</h2>
          <p class="lede">
            Enforced by the cluster's network policy and not by the worker. A host that is
            not here is not reachable from a session, whatever the session tries.
          </p>

          <.text_lines form={@fields} name="egress.fqdns" label="allowed hosts">
            One per line. The model endpoint, and anything a skill calls.
          </.text_lines>
          <.text_lines form={@fields} name="egress.gitHosts" label="git hosts">
            One per line. Where a session may clone from and push to.
          </.text_lines>
        </section>

        <section class="panel">
          <h2>Where a worker's disk comes from</h2>
          <p class="lede">
            How much disk is the size class's answer. Which storage it comes from is a fact
            about this cluster, so it is still asked here — and it is fixed once the pods
            exist, because a StatefulSet's volume claim cannot be resized in place.
          </p>

          <.field form={@fields} name="storage.storageClassName" label="storage class">
            Must be one the cluster policy allows. Empty means the cluster's default.
          </.field>
        </section>

        <section class="panel">
          <h2>MCP servers</h2>
          <p class="lede">
            Offered to every session on this profile. The credential is the name of an
            environment variable the pod finds a token in; the token is a Secret the
            operator mounts, and nothing here holds it.
          </p>

          <.server
            :for={{server, index} <- Enum.with_index(@servers)}
            server={server}
            index={index}
            checked={@checked}
          />

          <p :if={@servers == []} class="empty">
            None. Sessions on this profile get whatever the configuration bundle gives them
            and nothing else.
          </p>

          <button type="button" phx-click="add-server">add a server</button>
        </section>

        <section class="panel">
          <h2>Configuration</h2>

          <.field form={@fields} name="configBundleChannel" label="bundle channel">
            Which channel's agents, skills and servers the pods follow. Publishing to it
            pushes to every pod on this profile.
          </.field>

          <.toggle form={@fields} name="orgMount" label="mount the org volume">
            Read-only, always. The volume the cluster policy names, for material every team
            may read.
          </.toggle>
        </section>

        <section class="panel">
          <h2>What will happen</h2>

          <.policy verdict={@decision} />
          <.diff changes={@changes} />

          <p><strong>{consequence(@mode)}</strong></p>

          <button type="submit" disabled={not allowed?(@decision)}>{apply_label(@mode)}</button>

          <p :if={@applied} class="micro">{state_of(@applied)}</p>
        </section>
      </form>
    </.shell>
    """
  end

  defp consequence(:gitops),
    do:
      "Applying writes a commit for review. Nothing changes in the cluster until somebody applies it."

  defp consequence(:direct),
    do: "Applying changes the cluster now. Running sessions keep the pods they are on."

  defp consequence(_unknown),
    do: "This plane could not say how it provisions. Applying may or may not reach the cluster."

  defp apply_label(:gitops), do: "commit for review"
  defp apply_label(_direct), do: "apply now"

  defp state_of(%{state: state}), do: "Last write: #{state}."
  defp state_of(_other), do: ""

  defp allowed?(nil), do: true
  defp allowed?(%{allowed?: allowed}), do: allowed

  # What policy makes of the form as it stands, or of the profile as it is when nothing
  # has been typed yet.
  defp decision(%{preview: %{policy: policy}}), do: policy
  defp decision(%{verdict: verdict}), do: verdict

  defp changes_of(%{preview: %{changes: changes}}), do: changes
  defp changes_of(_assigns), do: nil

  attr(:form, :map, required: true)
  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:type, :string, default: "text")
  slot(:inner_block, required: true)

  # The help is required rather than optional: every field here names something outside
  # Troupe — an image, a model, a storage class — and the design's rule is that a field
  # naming an external thing says what it is for, in body text and not in a tooltip.
  defp field(assigns) do
    ~H"""
    <div class="setting">
      <label>
        {@label}
        <input type={@type} name={@name} value={Map.get(@form, @name)} />
      </label>
      <p class="field-help">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  attr(:form, :map, required: true)
  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  attr(:options, :list, required: true)
  slot(:inner_block, required: true)

  defp choice(assigns) do
    ~H"""
    <div class="setting">
      <label>
        {@label}
        <select name={@name}>
          <option value="">not set</option>
          <option
            :for={option <- @options}
            value={option}
            selected={Map.get(@form, @name) == option}
          >
            {option}
          </option>
        </select>
      </label>
      <p class="field-help">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  attr(:form, :map, required: true)
  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  slot(:inner_block, required: true)

  defp text_lines(assigns) do
    ~H"""
    <div class="setting">
      <label>
        {@label}
        <textarea name={@name} rows="4">{Map.get(@form, @name)}</textarea>
      </label>
      <p class="field-help">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  attr(:form, :map, required: true)
  attr(:name, :string, required: true)
  attr(:label, :string, required: true)
  slot(:inner_block, required: true)

  defp toggle(assigns) do
    ~H"""
    <div class="setting">
      <label class="toggle">
        <input type="checkbox" name={@name} checked={Map.get(@form, @name) == true} />
        {@label}
      </label>
      <p class="field-help">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  attr(:server, :map, required: true)
  attr(:index, :integer, required: true)
  attr(:checked, :map, required: true)

  defp server(assigns) do
    ~H"""
    <div class="setting server">
      <label>
        name
        <input name={"mcp.#{@index}.name"} value={@server["name"]} />
      </label>
      <label>
        url
        <input name={"mcp.#{@index}.url"} value={@server["url"]} />
      </label>
      <label>
        credential variable
        <input name={"mcp.#{@index}.credentialRef"} value={@server["credentialRef"]} />
      </label>
      <label>
        header
        <input name={"mcp.#{@index}.header"} value={@server["header"]} />
      </label>
      <label>
        timeout (ms)
        <input type="number" name={"mcp.#{@index}.timeoutMs"} value={@server["timeoutMs"]} />
      </label>

      <div class="setting__actions">
        <button
          :if={@server["url"] not in [nil, ""]}
          type="button"
          phx-click="check-server"
          phx-value-url={@server["url"]}
        >
          can a pod reach it?
        </button>
        <button type="button" phx-click="remove-server" phx-value-index={@index}>remove</button>
      </div>

      <p :if={Map.has_key?(@checked, @server["url"])} class="field-help">
        {reachability(Map.get(@checked, @server["url"]))}
      </p>
    </div>
    """
  end

  defp reachability(%{allowed: true, host: host}), do: "Egress policy allows #{host}."

  defp reachability(%{host: host}) do
    "Egress policy does not allow #{host}. A session's calls to it would time out."
  end

  attr(:verdict, :any, default: nil)

  defp policy(assigns) do
    ~H"""
    <div :if={@verdict}>
      <p :if={@verdict.allowed?} class="micro">Cluster policy allows this profile.</p>

      <ul :if={not @verdict.allowed?} class="checks">
        <li :for={violation <- @verdict.violations} class="checks__bad">
          <span class="checks__name">policy</span>
          <span class="checks__detail">{violation(violation)}</span>
        </li>
      </ul>
    </div>
    """
  end

  attr(:changes, :any, default: nil)

  # The same diff the audit record will carry, one line per field that moved, with both
  # values. The design uses this shape for config revisions, bundle versions and audit
  # entries alike, and it is never a coloured blob saying something changed.
  defp diff(assigns) do
    ~H"""
    <p :if={is_nil(@changes)} class="empty">Change something to see what would be written.</p>
    <p :if={@changes == %{}} class="empty">Nothing would change.</p>

    <ul :if={is_map(@changes) and @changes != %{}} class="diff">
      <li :for={{field, %{"from" => from, "to" => to}} <- Enum.sort(@changes)} class="diff__row">
        <span class="diff__field mono">{field}</span>
        <span class="diff__from mono">− {show(from)}</span>
        <span class="diff__to mono">+ {show(to)}</span>
      </li>
    </ul>
    """
  end

  defp show(nil), do: "not set"
  defp show(value) when is_binary(value), do: value
  defp show(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp show(value), do: Jason.encode!(value)
end
