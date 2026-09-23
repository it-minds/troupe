defmodule Troupe.Plane.Admin do
  @moduledoc """
  Everything an administrator can do, in one place.

  The panel, the admin JSON-RPC and the MCP tool list are three renderings of this module
  and nothing else. That is the Forbidden list's "any client, including our own panel,
  using anything but public APIs" made structural rather than remembered: a LiveView that
  reached into `Fleet` or `Identity` directly would be a private path into the plane, and
  a panel with a button no other client can press would be a feature only one kind of
  operator has. `Troupe.Plane.AdminParityTest` enumerates this module and asserts each
  function has both a method and a tool.

  ## Two roles

  `platform_admin` comes from an identity-provider group named in configuration — not
  assigned in Troupe, because an admin role Troupe could grant would be a way to escalate
  inside Troupe. `team_admin` is assigned per team by a platform admin and is scoped to
  that team.

  ## What neither can do

  Read session content. Every session-shaped answer here is the same metadata
  `sessions.list` returns, and there is no method that returns events — not as a
  restriction applied at the edge, but because the function does not exist. Break-glass
  access is out of scope, so there is nothing to bypass.

  ## Shape

  Every function takes an actor as its first argument and returns `{:ok, result}` or
  `{:error, %Error{}}`. The actor carries the role, so authorisation is decided here and
  once — a surface that decided it for itself would be a surface that could decide it
  differently.
  """

  alias Troupe.Plane.{
    Audit,
    Breakglass,
    Budget,
    Bundles,
    ClusterPolicy,
    Connections,
    Drain,
    Erasure,
    Fleet,
    Identity,
    Ledger
  }

  alias Troupe.Plane.Fleet.{Bundle, Provisioner, SizeClass, Worker}
  alias Troupe.Plane.Identity.ServicePrincipal
  alias Troupe.Plane.{OIDC, Principals, Provision, Sessions, Settings, Triggers}
  alias Troupe.Plane.SCIM.Connector
  alias Troupe.Plane.Settings.Ladder
  alias Troupe.Plane.Triggers.{Notify, Revision}
  alias Troupe.Protocol.Bundle, as: Document
  alias Troupe.Protocol.Error

  require Logger

  @type actor :: %{
          subject: String.t(),
          role: :platform_admin | :team_admin | :none,
          teams: [String.t()]
        }
  @type result :: {:ok, term()} | {:error, Error.t()}

  # -- who is asking ----------------------------------------------------------

  @doc """
  Work out what an authenticated user may administer.

  A platform admin is a member of the configured group; a team admin is named on a team.
  Derived on every call rather than carried in a token, so revoking an admin takes effect
  on their next request instead of at their next login.
  """
  @spec actor_for(Identity.User.t()) :: actor()
  def actor_for(%Identity.User{kind: "service"} = user) do
    # A principal can create and steer sessions and nothing else. Not even a team admin
    # of its own team: a credential that could create more of itself would be the
    # escalation the whole arrangement refuses.
    %{subject: user.subject, role: :none, teams: []}
  end

  def actor_for(%Identity.User{} = user) do
    teams = Identity.teams_for(user)
    group = Settings.get("platform_admin_group")

    cond do
      # Against the provider's *groups*, not against enabled teams. A team is something
      # this plane decided to do about a group — it has a budget, grants and a volume —
      # and requiring the admin group to be one would mean a fresh plane could never have
      # an administrator: enabling the first team is itself a platform-admin action.
      group && group in Identity.group_ids_for(user) ->
        %{subject: user.subject, role: :platform_admin, teams: Enum.map(teams, & &1.name)}

      administered = Identity.teams_administered_by(user) ->
        role = if administered == [], do: :none, else: :team_admin
        %{subject: user.subject, role: role, teams: Enum.map(administered, & &1.name)}
    end
  end

  @doc "Whether this actor may administer at all."
  @spec admin?(actor()) :: boolean()
  def admin?(%{role: role}), do: role in [:platform_admin, :team_admin]

  @doc """
  The actor for a subject, or `nil` if that subject administers nothing.

  What a surface calls when all it has is a name — a cookie, a token — rather than a
  loaded user. The lookup is here rather than in each surface so that a LiveView, the API
  and the CLI cannot disagree about who somebody is.
  """
  @spec actor_for_subject(String.t() | nil) :: actor() | nil
  def actor_for_subject(subject) when is_binary(subject) do
    case Identity.get_user(subject) do
      nil -> nil
      user -> user |> actor_for() |> then(&if admin?(&1), do: &1, else: nil)
    end
  end

  def actor_for_subject(_subject), do: nil

  @doc """
  Who a console session is, break-glass included.

  The console's only way to ask, because a LiveView reaches the plane through this
  module and nowhere else. Both answers are worked out on every call rather than carried
  in the cookie: a person whose admin role was taken away loses the console at their next
  page, and a break-glass session that has run out of time loses it at the same moment.

  The actor carries `breakglass` so a page can say so — the design requires a session
  opened with the token to be marked on every page, and a flag the caller has to fetch
  separately is a flag a page can forget.
  """
  @spec actor_for_session(map()) :: actor() | nil
  def actor_for_session(session) when is_map(session) do
    if Breakglass.live?(session) do
      session |> Breakglass.actor() |> Map.put(:breakglass, true)
    else
      case actor_for_subject(session["subject"]) do
        nil -> nil
        actor -> Map.put(actor, :breakglass, false)
      end
    end
  end

  def actor_for_session(_session), do: nil

  # -- overview ---------------------------------------------------------------

  @doc "Fleet health, active sessions and spend per team, scoped to what the actor sees."
  @spec overview(actor()) :: result()
  def overview(actor) do
    with :ok <- require_admin(actor) do
      teams = visible_teams(actor)

      {:ok,
       %{
         profiles: Enum.map(profiles_for(actor), &profile_summary/1),
         teams: Enum.map(teams, &team_spend/1),
         sessions: %{
           active: count_sessions(actor, "active"),
           dormant: count_sessions(actor, "dormant"),
           read_only: count_sessions(actor, "read_only")
         }
       }}
    end
  end

  # -- profiles ---------------------------------------------------------------

  @doc """
  What can make a worker, and which guarantee each one does not give.

  Asked of the provisioners rather than of any profile: what a substrate guarantees is a
  property of the substrate, and a row that claimed to be enforced would be a claim the
  cluster never made. A *profile's* own answer is in `profiles_list/1`, because a
  provisioner may give less for one profile than for another.

  Here rather than read out of `Fleet` by a screen, for the reason every other answer is
  here: the console is an admin API client and gets no private path into the plane.
  """
  @spec provisioners(actor()) :: result()
  def provisioners(actor) do
    with :ok <- require_admin(actor) do
      {:ok,
       Enum.map(Provisioner.implementations(), fn module ->
         # A bare profile of this provisioner, which is what "in general" can mean: the
         # question is what the substrate offers before anybody configures anything.
         profile = %Fleet.Profile{name: module.name(), provisioner: module.name()}
         given = module.guarantees(profile)

         %{
           name: module.name(),
           guarantees: Enum.map(given, &to_string/1),
           missing: Provisioner.guarantees() |> Kernel.--(given) |> Enum.map(&to_string/1)
         }
       end)}
    end
  end

  @doc "Every profile, with its pods, conditions and load."
  @spec profiles_list(actor()) :: result()
  def profiles_list(actor) do
    with :ok <- require_admin(actor) do
      {:ok, Enum.map(profiles_for(actor), &profile_summary/1)}
    end
  end

  @doc """
  One profile in full: what was asked for, what policy makes of it, and what is running.

  The three are separate on purpose. A profile whose spec is fine, whose policy verdict is
  a violation, and whose pods are still running the previous image is three different
  problems, and a view that merged them would make each one look like the others.
  """
  @spec profile_get(actor(), String.t()) :: result()
  def profile_get(actor, name) do
    with :ok <- require_platform_admin(actor),
         {:ok, profile} <- fetch_profile(name) do
      {:ok,
       %{
         profile: profile_summary(profile),
         spec: profile.spec,
         policy: Provision.verdict(profile),
         bundle: bundle_state(profile)
       }}
    end
  end

  @doc "Create or update a profile, returning the diff that was applied."
  @spec profile_put(actor(), map()) :: result()
  def profile_put(actor, attrs) do
    with :ok <- require_platform_admin(actor),
         {:ok, name} <- require_name(attrs),
         {:ok, attrs} <- without_derived(attrs),
         :ok <- release_named(attrs),
         :ok <- Provision.check(attrs) do
      before = Fleet.get_profile(name)

      case Fleet.put_profile(attrs) do
        {:ok, profile} ->
          changes = Audit.diff(comparable(before), comparable(profile))
          {:ok, _} = Audit.record(actor.subject, "profile.put", name, changes)

          {:ok,
           %{
             profile: profile_summary(profile),
             changes: changes,
             provisioning: provision(profile, actor)
           }}

        {:error, changeset} ->
          {:error, Error.new(:invalid_params, %{reason: inspect(changeset.errors)})}
      end
    end
  end

  # Seven fields left the admin surface and the plane writes them now: `replicas` from
  # what is running, and the rest from the size class. A caller that sends one is refused
  # rather than having it dropped — silently ignoring a field somebody typed is how a
  # person comes to believe a number is in force when it is not, and this is exactly the
  # category of mistake the seven fields were causing in the first place.
  @derived ~w(replicas sessionsPerPod sessions_per_pod resources storage)

  defp without_derived(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    spec = Map.get(attrs, "spec") || %{}
    sent = Enum.filter(@derived, &(Map.has_key?(attrs, &1) or Map.has_key?(spec, &1)))

    if sent == [] do
      {:ok, attrs}
    else
      {:error,
       Error.new(:invalid_params, %{
         reason: "the plane writes these; set size_class, max_sessions and warm_workers instead",
         not_yours: sent
       })}
    end
  end

  # `release` stands for the worker image this plane's release names, and a plane deployed
  # without one has nothing for it to stand for. Refused rather than saved: saved, it would
  # reach the cluster with no image at all — the one field the resource cannot be without
  # — and whoever typed it would find out from a pod that never appeared.
  defp release_named(attrs) do
    if Provision.follows_release?(attrs) and is_nil(Provision.release_image()) do
      {:error,
       Error.new(:invalid_params, %{
         image: "release",
         reason:
           "this plane was deployed without a worker image (worker.image in the chart, " <>
             "TROUPE_WORKER_IMAGE), so there is no release to follow; name an image instead"
       })}
    else
      :ok
    end
  end

  @doc """
  The image a profile whose image is `release` runs on this plane, or `nil` if it names none.

  Here for the reason `size_classes/0` is: the console says what the word means right now,
  and a LiveView is an admin API client with no private way to find out.
  """
  @spec release_image() :: String.t() | nil
  def release_image, do: Provision.release_image()

  @doc """
  The size classes a profile may be, in the order a console offers them.

  Here rather than read from `Fleet.SizeClass` by whoever is rendering: a LiveView is an
  admin API client and gets no private access, and a model asking over MCP should be able
  to find out what the two words mean without being told them out of band.
  """
  @spec size_classes() :: [String.t()]
  def size_classes, do: SizeClass.names()

  @doc "Each size class with what it is for, as the console and a model both read it."
  @spec size_class_summaries() :: [map()]
  def size_class_summaries do
    Enum.map(SizeClass.names(), fn name ->
      class = SizeClass.get(name)

      %{
        name: name,
        sessions_per_worker: class.sessions_per_pod,
        summary: class.summary
      }
    end)
  end

  @doc "Remove a profile. Its sessions become read-only rather than being erased."
  @spec profile_delete(actor(), String.t()) :: result()
  def profile_delete(actor, name) do
    with :ok <- require_platform_admin(actor),
         {:ok, profile} <- fetch_profile(name) do
      {:ok, _} = Audit.record(actor.subject, "profile.delete", name, comparable(profile))
      removal = unprovision(profile, actor)
      Fleet.delete_profile(name)

      {:ok, %{profile: name, deleted: true, provisioning: removal}}
    end
  end

  @doc """
  Every machine registered to a profile, and whether each has ever been seen.

  `Troupe.Plane.Fleet.Hosts` has existed since R6 and nothing called it: a host could be
  registered by a function in the plane and by no person anywhere, which made the
  single-machine case a feature the code had and the product did not.

  "Registered and never seen" is its own state and is the one somebody needs. A host that
  has never enrolled is a worker somebody has not installed yet; one that enrolled and went
  quiet is a machine that is off, or a secret that was rotated out from under it.
  """
  @spec hosts_list(actor(), String.t()) :: result()
  def hosts_list(actor, profile) do
    with :ok <- require_platform_admin(actor),
         {:ok, _profile} <- fetch_profile(profile) do
      {:ok, profile |> Fleet.Hosts.for_profile() |> Enum.map(&host_summary/1)}
    end
  end

  @doc """
  Register a machine against a profile, and mint the secret it enrols with.

  **The secret crosses once.** It is returned here, shown once, and stored only as a hash —
  the same discipline a service principal's is held to, for the same reason: a secret the
  plane could show twice is a secret the plane is keeping.

  The profile decides what the host may run, which is how a machine outside the cluster is
  bound to a policy at all: enrolment proves the host is *this* host of *that* profile, and
  the profile's grants decide the rest. A host registered against a profile no substrate
  enforces is why `allow_unenforced_workers` exists.
  """
  @spec host_register(actor(), String.t(), map()) :: result()
  def host_register(actor, profile, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    with :ok <- require_platform_admin(actor),
         {:ok, _profile} <- fetch_profile(profile) do
      # Who registered it, from the actor rather than from the caller: a field a client
      # filled in is a field a client can put somebody else's name in.
      attrs = Map.put(attrs, "registered_by", actor.subject)

      case Fleet.Hosts.register(profile, attrs) do
        {:ok, host, secret} ->
          {:ok, _} =
            Audit.record(actor.subject, "host.register", "#{profile}/#{host.name}", %{
              "profile" => profile,
              "address" => host.address
            })

          {:ok, host |> host_summary() |> Map.put(:secret, secret)}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, invalid(changeset)}

        {:error, reason} ->
          {:error, Error.new(:invalid_params, %{reason: inspect(reason)})}
      end
    end
  end

  @doc """
  Mint a new secret for a host, keeping the host.

  The id has to survive: a rotation that made a new row would leave the new secret naming a
  host nothing knows about, which is indistinguishable from a rotation that did not take.
  The old secret stops working the moment this returns.
  """
  @spec host_rotate(actor(), String.t(), String.t()) :: result()
  def host_rotate(actor, profile, name) do
    with :ok <- require_platform_admin(actor),
         {:ok, host} <- fetch_host(profile, name) do
      {:ok, rotated, secret} = Fleet.Hosts.rotate(host, actor.subject)
      {:ok, _} = Audit.record(actor.subject, "host.rotate", "#{profile}/#{name}", %{})
      {:ok, rotated |> host_summary() |> Map.put(:secret, secret)}
    end
  end

  @doc """
  Stop a machine enrolling, or let it again.

  Disabling does not reach the machine — nothing here can — so what it does is refuse the
  next enrolment and every one after it. A worker already connected keeps its sessions
  until it is drained, which is the same sequence a pod gets and for the same reason.
  """
  @spec host_set_enabled(actor(), String.t(), String.t(), boolean()) :: result()
  def host_set_enabled(actor, profile, name, enabled?) do
    with :ok <- require_platform_admin(actor),
         {:ok, host} <- fetch_host(profile, name) do
      host |> Fleet.Hosts.set_enabled(enabled?) |> recorded(actor, profile, name, enabled?)
    end
  end

  defp recorded({:ok, host}, actor, profile, name, enabled?) do
    action = if enabled?, do: "host.enable", else: "host.disable"
    {:ok, _} = Audit.record(actor.subject, action, "#{profile}/#{name}", %{})
    {:ok, host_summary(host)}
  end

  defp recorded({:error, :not_found}, _actor, profile, name, _enabled?) do
    {:error, Error.new(:not_found, %{profile: profile, host: name})}
  end

  defp fetch_host(profile, name) do
    case Fleet.Hosts.by_name(profile, name) do
      nil -> {:error, Error.new(:not_found, %{profile: profile, host: name})}
      host -> {:ok, host}
    end
  end

  # Never the hash and never the salt: what a machine is, and whether it has ever arrived.
  defp host_summary(host) do
    %{
      name: host.name,
      profile: host.profile,
      address: host.address,
      enabled: host.enabled,
      registered_at: host.inserted_at,
      last_enrolled_at: host.last_enrolled_at,
      # Three states rather than two, for the reason a principal has three: a machine
      # nobody has installed the worker on yet is a different job from one that is off.
      state: host_state(host)
    }
  end

  defp host_state(%{enabled: false}), do: :disabled
  defp host_state(%{last_enrolled_at: nil}), do: :never_seen
  defp host_state(_host), do: :enrolled

  @doc "Drain a pod, returning what it was holding."
  @spec pod_drain(actor(), String.t()) :: result()
  def pod_drain(actor, worker_id) do
    with :ok <- require_platform_admin(actor),
         %Worker{} = worker <- Fleet.get_worker(worker_id) do
      {:ok, _} =
        Audit.record(actor.subject, "pod.drain", worker.pod_name, %{"profile" => worker.profile})

      case Drain.pod(worker) do
        {:ok, report} -> {:ok, report}
        {:error, reason} -> {:error, Error.new(:unavailable, %{reason: inspect(reason)})}
      end
    else
      nil -> {:error, Error.new(:not_found, %{worker_id: worker_id})}
      other -> other
    end
  end

  # -- teams ------------------------------------------------------------------

  @doc "Teams, with their grants, budgets, volumes and retention."
  @spec teams_list(actor()) :: result()
  def teams_list(actor) do
    with :ok <- require_admin(actor) do
      {:ok, Enum.map(visible_teams(actor), &team_detail/1)}
    end
  end

  @doc """
  Make an identity-provider group a team.

  Groups are created just by being seen at login, so this is the step that turns "these
  people exist" into "these people may use Troupe" — which is why it is a platform
  admin's and not a team admin's.
  """
  @spec team_enable(actor(), String.t(), map()) :: result()
  def team_enable(actor, group_id, attrs \\ %{}) do
    with :ok <- require_platform_admin(actor),
         %Identity.Group{} = group <- Identity.get_group(group_id) do
      attrs =
        team_defaults()
        |> Map.merge(Map.new(attrs, fn {key, value} -> {to_string(key), value} end))
        |> Map.put("enabled_by", actor.subject)

      case Identity.enable_team(group, attrs) do
        {:ok, team} ->
          {:ok, _} = Audit.record(actor.subject, "team.enable", team.name, %{"group" => group_id})
          {:ok, team_detail(team)}

        {:error, changeset} ->
          {:error, Error.new(:invalid_params, changeset_reason(changeset))}
      end
    else
      nil -> {:error, Error.new(:not_found, %{group: group_id})}
      other -> other
    end
  end

  @doc """
  What a team name must be, in words, for a form to show beside the field.

  Here rather than read off `Identity.Team` by the screen, because a LiveView reaches the
  plane through this module and nowhere else. Zero arity, so it is a fact rather than an
  action and needs no API method of its own: every rendering that wants it already has the
  refusal, which carries the same sentence.
  """
  @spec team_name_rule() :: String.t()
  def team_name_rule, do: Identity.Team.name_rule()

  @doc """
  The periods a team's budget may be measured over, for a form to offer.

  The list the team's own changeset accepts, so a screen cannot offer a period that saving
  then refuses. Zero arity for the same reason as `team_name_rule/0`.
  """
  @spec budget_periods() :: [String.t()]
  def budget_periods, do: Identity.Team.budget_periods()

  # A refused changeset as a sentence per field rather than an inspected keyword list. A
  # console shows `reason` beside the form, and `[name: {"must be…", [validation:
  # :format]}]` is a thing to be decoded before it is a thing to be fixed.
  defp changeset_reason(changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Enum.reduce(opts, message, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    reason =
      Enum.map_join(errors, "; ", fn {field, messages} ->
        "#{field}: #{Enum.join(messages, ", ")}"
      end)

    %{reason: reason, fields: Map.keys(errors)}
  end

  # What a team starts with, from the platform's settings rather than from the schema's
  # defaults. The schema still has defaults — a team created by a migration or a test has
  # to be some shape — but a platform that has decided every new team gets a 500 kr ceiling
  # should not have to remember to set it on each one. In `Settings` because the SCIM
  # connector enables teams too, and a team should start the same way whoever made it.
  defp team_defaults, do: Settings.team_defaults()

  @doc "Change a team's budget, retention or default visibility."
  @spec team_update(actor(), String.t(), map()) :: result()
  def team_update(actor, name, attrs) do
    with {:ok, team} <- fetch_team(actor, name),
         :ok <- may_set_unenforced(actor, attrs),
         :ok <- still_allowed(team, attrs),
         # Before the changeset, so a widening attempt is refused with the ceiling
         # quoted rather than clamped. An administrator whose form accepted a number the
         # plane is not using has been told a lie by something that knew better.
         :ok <- within_the_ladder(team, attrs) do
      before = comparable(team)

      case Identity.update_team(team, attrs) do
        {:ok, updated} ->
          changes = Audit.diff(before, comparable(updated))
          {:ok, _} = Audit.record(actor.subject, "team.update", name, changes)
          reproject(updated, changes, actor)
          {:ok, %{team: team_detail(updated), changes: changes}}

        {:error, changeset} ->
          {:error, Error.new(:invalid_params, %{reason: inspect(changeset.errors)})}
      end
    end
  end

  defp within_the_ladder(team, attrs) do
    case Ladder.check(team, Map.new(attrs)) do
      :ok ->
        :ok

      {:error, refusal} ->
        {:error,
         Error.new(:forbidden, %{
           field: to_string(refusal.field),
           asked: refusal.asked,
           ceiling: refusal.ceiling,
           decided_by: refusal.rung,
           reason: "a lower rung may only narrow"
         })}
    end
  end

  # A team admin may set everything else about their team and not this one: a flag a team
  # could give itself is not a decision anybody made about that team. Refused rather than
  # dropped, because a form that accepted the value and ignored it would be the lie this
  # module keeps refusing to tell.
  defp may_set_unenforced(%{role: :platform_admin}, _attrs), do: :ok

  defp may_set_unenforced(_actor, attrs) do
    if is_nil(unenforced_attr(attrs)) do
      :ok
    else
      {:error,
       Error.new(:forbidden, %{
         field: "allow_unenforced_workers",
         reason: "only a platform admin decides whether a team may run where nothing is enforced"
       })}
    end
  end

  # Taking the permission back while the team still holds a grant that needed it would
  # leave the grant standing and the permission gone, which is the state the check at grant
  # time exists to make impossible. The profiles are named, because the repair is to revoke
  # them and the person doing it has to know which.
  defp still_allowed(team, attrs) do
    case unenforced_attr(attrs) do
      false ->
        case unenforced_grants(team) do
          [] ->
            :ok

          profiles ->
            {:error,
             Error.new(:forbidden, %{
               team: team.name,
               profiles: profiles,
               reason:
                 "this team is granted " <>
                   Enum.join(profiles, ", ") <>
                   ", which no substrate enforces; revoke them first"
             })}
        end

      _unchanged_or_true ->
        :ok
    end
  end

  defp unenforced_grants(team) do
    for grant <- Identity.grants_for_team(team),
        profile = Fleet.get_profile(grant.profile),
        not is_nil(profile),
        Provisioner.unenforced?(profile),
        do: grant.profile
  end

  # A form sends `"on"` and nothing at all; a JSON-RPC caller sends a boolean. `nil` means
  # this update does not mention the flag, which is not the same as setting it to false.
  #
  # Wrapped in a tuple on the way out, because the value this looks for is very often
  # `false` and `Enum.find_value/2` reads a `false` result as *not found* — which made
  # clearing the flag indistinguishable from an update that never mentioned it, and left
  # the one case both checks here exist for silently unchecked.
  defp unenforced_attr(attrs) do
    attrs
    |> Enum.find_value(fn {key, value} ->
      if to_string(key) == "allow_unenforced_workers", do: {:set, coerce_flag(value)}
    end)
    |> case do
      {:set, flag} -> flag
      nil -> nil
    end
  end

  defp coerce_flag(value) when is_boolean(value), do: value
  defp coerce_flag("on"), do: true
  defp coerce_flag("true"), do: true
  defp coerce_flag("false"), do: false
  defp coerce_flag(_other), do: nil

  @doc """
  Every group the identity provider has told this plane about.

  What an administrator links a team to. Mirrored, never authored: this list is what SCIM
  pushed or what somebody's `groups` claim created at login, and a group absent from it is
  a group nobody from has signed in yet.
  """
  @spec groups_list(actor()) :: result()
  def groups_list(actor) do
    with :ok <- require_admin(actor) do
      {:ok,
       Enum.map(Identity.list_groups(), fn group ->
         %{external_id: group.external_id, display_name: group.display_name}
       end)}
    end
  end

  @doc """
  Draw a team's members from one more identity-provider group.

  Membership is still never typed here. What this adds is *which groups count*; who is in
  them stays the provider's answer, arriving by SCIM or in a `groups` claim at login. A
  person in two of a team's groups is in the team once.
  """
  @spec team_link(actor(), String.t(), String.t()) :: result()
  def team_link(actor, name, group_id) do
    with :ok <- require_platform_admin(actor),
         {:ok, team} <- fetch_team(actor, name),
         %Identity.Group{} = group <- Identity.get_group(group_id) do
      {:ok, _link} = Identity.link_group(team, group, actor.subject)
      {:ok, _} = Audit.record(actor.subject, "team.link", name, %{"group" => group_id})

      {:ok, %{team: name, group: group_id, members: length(Identity.members_of_team(team))}}
    else
      nil -> {:error, Error.new(:not_found, %{group: group_id})}
      other -> other
    end
  end

  @doc """
  What unlinking a group would do, before anybody does it.

  The count comes first, like every other irreversible action. Somebody unlinking a group
  is usually right about which group and often wrong about how many people are in the
  team *only* through it — which is the number this answers and the one worth putting in
  front of them.

  Sessions do not move. A session's team is recorded at create and stays; unlinking
  changes who may open it, not what it belongs to. People assume that the other way round,
  so the answer says how many sessions those people can currently open.
  """
  @spec team_unlink_preview(actor(), String.t(), String.t()) :: result()
  def team_unlink_preview(actor, name, group_id) do
    with :ok <- require_platform_admin(actor),
         {:ok, team} <- fetch_team(actor, name),
         %Identity.Group{} = group <- Identity.get_group(group_id) do
      {:ok, Identity.unlink_effect(team, group)}
    else
      nil -> {:error, Error.new(:not_found, %{group: group_id})}
      other -> other
    end
  end

  @doc """
  Stop drawing a team's members from a group.

  Destructive, and confirmed by typing the group's identifier. What it removes is access
  for everybody who was in the team only through this group; `team_unlink_preview/3` says
  how many that is and is meant to be shown first.
  """
  @spec team_unlink(actor(), String.t(), String.t()) :: result()
  def team_unlink(actor, name, group_id) do
    with :ok <- require_platform_admin(actor),
         {:ok, team} <- fetch_team(actor, name),
         %Identity.Group{} = group <- Identity.get_group(group_id) do
      effect = Identity.unlink_effect(team, group)
      :ok = Identity.unlink_group(team, group)
      {:ok, _} = Audit.record(actor.subject, "team.unlink", name, effect)

      {:ok, effect}
    else
      nil -> {:error, Error.new(:not_found, %{group: group_id})}
      other -> other
    end
  end

  @doc """
  What removing a team would take with it, before anybody does it.

  A team is the thing its grants, administrators, service principals, triggers and group
  links hang off, and every one of them goes with the row. Its sessions are the one thing
  that stays: a session's team is recorded at create and the column is nulled, so the
  transcripts survive as sessions with no team, listed on the Sessions screen as what they
  are. The preview says all of that in numbers, because "delete team" reads as tidying up
  and three triggers that fire nightly is not tidy.
  """
  @spec team_disable_preview(actor(), String.t()) :: result()
  def team_disable_preview(actor, name) do
    with :ok <- require_platform_admin(actor),
         {:ok, team} <- fetch_team(actor, name) do
      {:ok, disable_effect(team)}
    end
  end

  @doc """
  Stop a group of people being a team.

  Destructive, confirmed by typing the team's name. Every grant is revoked first, the way
  `team_revoke/3` does it — the team's sessions on each profile go read-only and the
  profile's projection of who may use it is re-rendered — and then the row goes, taking
  the administrators, principals, triggers and group links with it. The people stay
  people, the groups stay groups, and the sessions stay sessions with no team.
  `team_disable_preview/2` says how many of each and is meant to be shown first.
  """
  @spec team_disable(actor(), String.t()) :: result()
  def team_disable(actor, name) do
    with :ok <- require_platform_admin(actor),
         {:ok, team} <- fetch_team(actor, name) do
      effect = disable_effect(team)

      for profile <- effect.grants do
        :ok = Identity.revoke(team, profile)
        project(profile, actor)
      end

      # Triggers before the row. A principal cannot go while a trigger revision names it
      # — that restriction is deliberate and this is not the place to lift it — and the
      # team's principals go with the team, so the triggers have to be gone first.
      Enum.each(Triggers.list(team), &Triggers.delete/1)

      case Identity.disable_team(team) do
        {:ok, _team} ->
          {:ok, _} = Audit.record(actor.subject, "team.disable", name, Map.delete(effect, :confirm))
          {:ok, effect}

        {:error, changeset} ->
          {:error, Error.new(:internal_error, %{reason: inspect(changeset.errors)})}
      end
    end
  end

  defp disable_effect(team) do
    %{
      team: team.name,
      groups: Enum.map(Identity.links_of(team), & &1.group.external_id),
      members: length(Identity.members_of_team(team)),
      grants: Enum.map(Identity.grants_for_team(team), & &1.profile),
      admins: Identity.admins_of(team),
      principals: Enum.map(Principals.list(team), & &1.subject),
      triggers: Enum.map(Triggers.list(team), & &1.name),
      # Not removed. A session's team is fixed at create and the column is nulled, so
      # these stay readable with no team rather than going with it.
      sessions_kept: Sessions.count_for_team(team),
      # What the typed confirmation has to match, in the answer rather than assumed by
      # the surface: the MCP tool and the dialog are one rule in two renderings.
      confirm: team.name
    }
  end

  @doc "Give a team access to a profile."
  @spec team_grant(actor(), String.t(), String.t(), map()) :: result()
  def team_grant(actor, name, profile, attrs \\ %{}) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    with :ok <- require_platform_admin(actor),
         {:ok, team} <- fetch_team(actor, name),
         :ok <- enforced_enough(team, profile),
         before <- entitlement_names(team, profile),
         {:ok, _grant} <- granted(team, profile, attrs) do
      detail = grant_detail(profile, Audit.diff(before, entitlement_names(team, profile)))

      {:ok, _} = Audit.record(actor.subject, "team.grant", name, detail)
      project(profile, actor)

      {:ok, team_detail(team)}
    end
  end

  # A profile whose substrate does not enforce, granted to a team nobody has said may
  # run there. Refused rather than warned about, and the refusal lists *which* guarantees
  # are missing: "unenforced" is not a useful thing to tell somebody deciding whether
  # their team's work may run on somebody's build box.
  #
  # This is deliberate friction. The feature exists so a developer with one laptop can use
  # the product, and it is not a way around the policy — a console that softened this
  # would be the most dangerous thing in the console.
  defp enforced_enough(team, profile_name) do
    profile = Fleet.get_profile(profile_name)

    cond do
      # A grant to a profile that does not exist is the grant path's business, not this
      # check's, and answering `:ok` here leaves that refusal where it already is.
      is_nil(profile) -> :ok
      Provisioner.missing(profile) == [] -> :ok
      team.allow_unenforced_workers -> :ok
      true -> unenforced_refusal(team, profile)
    end
  end

  defp unenforced_refusal(team, profile) do
    missing = profile |> Provisioner.missing() |> Enum.map(&to_string/1)

    {:error,
     Error.new(:forbidden, %{
       profile: profile.name,
       provisioner: profile.provisioner,
       missing: missing,
       team: team.name,
       reason:
         "this substrate does not provide " <>
           Enum.join(missing, ", ") <>
           "; a platform admin must allow unenforced workers for this team first"
     })}
  end

  # An unchanged entitlement list is not a change, and an audit row that recorded one
  # every time somebody adjusted a volume mode would bury the times it did move.
  defp grant_detail(profile, changes) when changes == %{}, do: %{"profile" => profile}

  defp grant_detail(profile, changes) do
    %{"profile" => profile, "entitlements" => changes}
  end

  defp granted(team, profile, attrs) do
    case Identity.grant(team, profile, attrs) do
      {:ok, grant} -> {:ok, grant}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, invalid(changeset)}
      {:error, reason} -> {:error, Error.new(:internal_error, %{reason: inspect(reason)})}
    end
  end

  # A diff of entitlement names is a diff of names, so nothing about redaction changes.
  # Grouped by kind, because that is how the editor shows them and how an admin reading
  # the audit row six weeks later will be thinking about them.
  defp entitlement_names(team, profile) do
    team
    |> Identity.entitlements_for(profile)
    |> Enum.group_by(& &1.kind, &"#{&1.mode}:#{&1.name}")
    |> Map.new(fn {kind, names} -> {kind, Enum.sort(names)} end)
  end

  defp invalid(%Ecto.Changeset{} = changeset) do
    Error.new(:invalid_params, %{reason: inspect(changeset.errors)})
  end

  @doc "Take it away. The team's sessions on that profile become read-only."
  @spec team_revoke(actor(), String.t(), String.t()) :: result()
  def team_revoke(actor, name, profile) do
    with :ok <- require_platform_admin(actor),
         {:ok, team} <- fetch_team(actor, name) do
      :ok = Identity.revoke(team, profile)
      {:ok, _} = Audit.record(actor.subject, "team.revoke", name, %{"profile" => profile})
      project(profile, actor)

      {:ok, team_detail(team)}
    end
  end

  # -- sessions ---------------------------------------------------------------

  @doc """
  Session metadata, and only metadata.

  There is no admin method that returns events. Reading what a session said requires
  being on its ACL, and this module has nothing that could be made to do it.
  """
  @spec sessions_list(actor(), keyword()) :: result()
  def sessions_list(actor, opts \\ []) do
    with :ok <- require_admin(actor) do
      {:ok, actor |> Sessions.for_admin(team_ids(actor), opts) |> Enum.map(&session_summary/1)}
    end
  end

  @doc """
  Who has connected a personal credential to which server, and whose identity a session
  carries.

  The console half of person-mode servers, and it exists to make one thing visible that
  people otherwise discover: **a session has one identity.** A person-mode server reaches
  out as the session's *owner*, fixed when the session was activated — so two people
  attached to one session are two actors behind one subject, and the answer to "whose
  credential was that" is the owner's rather than whoever typed.

  What is answered here is deliberately thin, and each absence is the same absence:

  * **whether** somebody has filled a slot, never what is in it. The plane's key manager
    policy has metadata and nothing on the data path, which is the same absence that stops
    it reading a session key.
  * no method removes a slot, because there is no credential here that could be removed.
    An administrator retires the server from the bundle; the credential stays the
    person's.

  `connected` is `false` where the key manager could not be reached, because "we could not
  ask" and "there is nothing there" lead a person to the same next step.
  """
  @spec connections(actor(), String.t() | nil) :: result()
  def connections(actor, team_name \\ nil) do
    with :ok <- require_admin(actor),
         {:ok, team} <- optional_team(actor, team_name) do
      teams = if team, do: [team], else: visible_teams(actor)
      servers = person_servers_by_profile(teams)

      {:ok,
       %{
         servers: Enum.map(servers, &server_connections(&1, teams)),
         sessions: sessions_carrying(servers, teams),
         # Said in the answer rather than only on the screen, because a model reading this
         # over MCP has to be told the same thing a person is: there is nothing to read.
         credentials_readable: false
       }}
    end
  end

  # Every person-mode server on the profiles these teams are granted, with the profiles it
  # came from. Keyed by name and slot: two profiles carrying the same server is one server
  # somebody connects once.
  defp person_servers_by_profile(teams) do
    for team <- teams,
        grant <- Identity.grants_for_team(team),
        server <- person_servers(grant.profile),
        reduce: %{} do
      acc ->
        key = {server.name, server.credential_ref}

        existing =
          Map.get(acc, key, %{name: server.name, slot: server.credential_ref, profiles: []})

        Map.put(acc, key, %{existing | profiles: Enum.uniq([grant.profile | existing.profiles])})
    end
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  defp person_servers(profile_name) do
    with %{config_bundle_channel: channel} <- Fleet.get_profile(profile_name),
         %{} = bundle <- Bundles.current(channel),
         {:ok, %{mcp_servers: servers}} <- Document.validate(bundle.content) do
      Enum.filter(servers, &(&1.credential_mode == :person))
    else
      _absent -> []
    end
  end

  defp server_connections(server, teams) do
    people =
      for team <- teams,
          Enum.any?(
            server.profiles,
            &(&1 in Enum.map(Identity.grants_for_team(team), fn g -> g.profile end))
          ),
          user <- Identity.members_of_team(team),
          uniq: true,
          do: user

    Map.put(
      server,
      :people,
      people
      |> Enum.uniq_by(& &1.subject)
      |> Enum.sort_by(& &1.subject)
      |> Enum.map(fn user ->
        %{
          subject: user.subject,
          display_name: user.display_name,
          connected: Connections.connected?(user.subject, server.slot)
        }
      end)
    )
  end

  # The sessions whose profile carries one of these servers, each with the one identity its
  # calls go out as. Metadata only, like every other session-shaped answer here.
  defp sessions_carrying(servers, teams) do
    profiles = servers |> Enum.flat_map(& &1.profiles) |> MapSet.new()

    by_id = Map.new(teams, &{&1.id, &1.name})

    # Scoped by the team ids even for a platform admin, because the teams here are already
    # the ones this actor may see — and `:platform_admin` would make `for_admin/3` ignore
    # the list, which for a team admin would be every session on the plane.
    for session <- Sessions.for_admin(%{role: :team_admin}, Map.keys(by_id)),
        session.profile in profiles,
        Map.has_key?(by_id, session.team_id) do
      %{
        id: session.id,
        profile: session.profile,
        team: Map.fetch!(by_id, session.team_id),
        # The name every person-mode call goes out as, whoever is driving.
        owner: session.owner_subject,
        state: session.state
      }
    end
  end

  @doc """
  What erasing this session will do, before anybody does it.

  The same shape as `team_unlink_preview/3` and for the same reason: the count before the
  deed. Somebody erasing a session is usually right about which session and often wrong
  about what goes with it.

  Three consequences, and the third is the one people get wrong:

  * **the key is destroyed**, every version of it, so no backup of object storage, of
    PostgreSQL or of any volume can recover the content. Erasure here is not a delete of
    rows that a restore would undo.
  * **every object version under the prefix goes**, including prior versions in the
    versioned bucket, which is the place a restore would otherwise find them.
  * **children survive.** A fork is a separate session with its own key, sealed under it
    from the moment it was opened. Erasing a parent leaves every child readable, and the
    number is here because "does this take the forks with it" is the question somebody is
    actually asking and the answer is no.
  """
  @spec session_erase_preview(actor(), String.t()) :: result()
  def session_erase_preview(actor, session_id) do
    with :ok <- require_admin(actor),
         {:ok, session} <- fetch_session(actor, session_id) do
      forks = Sessions.children_of(session.id)

      {:ok,
       %{
         session_id: session.id,
         owner: session.owner_subject,
         profile: session.profile,
         object_bytes: session.object_bytes,
         workspace_bytes: session.workspace_bytes,
         # Named rather than implied, because a console that showed only a count would be
         # asking somebody to trust a number about sessions they cannot see from here.
         survivors: Enum.map(forks, & &1.id),
         survivor_count: length(forks),
         # What the typed confirmation has to match, in the answer rather than assumed by
         # the surface: the MCP tool and the dialog are one rule in two renderings.
         confirm: session.id
       }}
    end
  end

  @doc "Erase a session, for an administrator entitled to."
  @spec session_erase(actor(), String.t()) :: result()
  def session_erase(actor, session_id) do
    with :ok <- require_admin(actor),
         {:ok, session} <- fetch_session(actor, session_id) do
      {:ok, _} =
        Audit.record(actor.subject, "session.erase", session_id, %{"profile" => session.profile})

      case Erasure.erase(session, actor: actor.subject, reason: "admin") do
        {:ok, tombstone} -> {:ok, %{session_id: session_id, head_hash: tombstone.head_hash}}
        {:error, reason} -> {:error, Error.new(:internal_error, %{reason: inspect(reason)})}
      end
    end
  end

  # -- provisioning -----------------------------------------------------------

  @doc """
  How this plane puts profiles into the cluster: `:direct` or `:gitops`.

  A panel shows it because the two mean different things when a change does not appear:
  in direct mode that is a failure, and in GitOps mode it is the normal state until Flux
  catches up.
  """
  @spec provisioning_mode(actor()) :: result()
  def provisioning_mode(actor) do
    with :ok <- require_admin(actor), do: {:ok, Provision.mode()}
  end

  @doc """
  What the cluster policy makes of a profile that has not been saved yet.

  The panel's fast feedback, and deliberately the same function admission's check comes
  from: an approximation that disagreed would be worse than no check at all, because a
  person would trust it.
  """
  @spec preview(actor(), map()) :: result()
  def preview(actor, attrs) do
    with :ok <- require_platform_admin(actor) do
      current =
        attrs |> Map.get("name", Map.get(attrs, :name)) |> then(&(&1 && Fleet.get_profile(&1)))

      {:ok,
       %{
         policy: Provision.verdict(attrs),
         changes: Audit.diff(comparable(current), comparable_attrs(attrs)),
         mode: Provision.mode()
       }}
    end
  end

  # -- the platform's own settings --------------------------------------------

  @doc """
  Every platform setting: its value, where that value came from, and what changing it does.

  A team admin may read this. The values here are not secrets — the one thing that would
  be, a credential, is reported as set or not and never returned — and a team admin who
  can see that the platform admin group is a group they are not in has been told something
  true and useful rather than something they could exploit.

  The panels come back with the settings rather than being the console's own list, so the
  console does not hold an opinion about how the platform's configuration is arranged and
  a setting added to `Troupe.Plane.Settings` appears on the page with nothing else changed.
  """
  @spec settings_list(actor()) :: result()
  def settings_list(actor) do
    with :ok <- require_admin(actor) do
      groups =
        Enum.map(Settings.groups(), fn {key, title, blurb} ->
          %{key: key, title: title, blurb: blurb}
        end)

      {:ok,
       %{
         groups: groups,
         settings: Settings.all(),
         ladder: Ladder.rungs(),
         # Which of them more than one rung decides, so a surface can put the chip on the
         # right fields without asking about every setting it has. A console is an API
         # client here like any other and cannot read the resolver to find out.
         laddered: Ladder.laddered() |> Map.keys() |> Enum.sort()
       }}
    end
  end

  @doc """
  For one setting, the value in force, the rung that decided it, and every rung that had
  an opinion.

  The thing that makes a ladder usable rather than merely correct. An administrator
  looking at a retention of thirty days where they set three hundred and sixty-five needs
  to know *who* said thirty — and a view that answered only the winner would leave them
  to guess between the deployment, the platform and their own team.

  `team` is optional: without it the answer is the two rungs above every team, which is
  what a platform admin asks when they want to know what a team may not exceed.
  """
  @spec setting_effective(actor(), String.t(), String.t() | nil) :: result()
  def setting_effective(actor, key, team_name) do
    with :ok <- require_admin(actor),
         {:ok, team} <- optional_team(actor, team_name) do
      case Ladder.effective(key, team) do
        nil ->
          {:error,
           Error.new(:not_found, %{
             setting: key,
             reason: "not a setting more than one rung decides",
             laddered: Ladder.laddered() |> Map.keys() |> Enum.sort()
           })}

        resolved ->
          {:ok, Map.put(resolved, :team, team && team.name)}
      end
    end
  end

  @doc """
  Change one setting.

  Audited like any other change, and with the same diff shape, so a setting that locked
  everybody out is answerable in the audit log rather than being a mystery about the
  deployment.
  """
  @spec setting_put(actor(), String.t(), String.t()) :: result()
  def setting_put(actor, key, value) do
    with :ok <- require_platform_admin(actor) do
      before = Settings.get(key)

      case Settings.put(key, value, actor.subject) do
        {:ok, applied} ->
          changes = Audit.diff(%{key => before}, %{key => applied.value})
          {:ok, _} = Audit.record(actor.subject, "setting.put", key, changes)
          {:ok, Map.put(applied, :changes, changes)}

        {:error, reason} ->
          {:error, setting_error(key, reason)}
      end
    end
  end

  @doc "Put a setting back to whatever this plane was deployed with."
  @spec setting_reset(actor(), String.t()) :: result()
  def setting_reset(actor, key) do
    with :ok <- require_platform_admin(actor) do
      before = Settings.get(key)

      case Settings.reset(key, actor.subject) do
        {:ok, applied} ->
          changes = Audit.diff(%{key => before}, %{key => applied.value})
          {:ok, _} = Audit.record(actor.subject, "setting.reset", key, changes)
          {:ok, Map.put(applied, :changes, changes)}

        {:error, reason} ->
          {:error, setting_error(key, reason)}
      end
    end
  end

  defp setting_error(key, :unknown_setting),
    do: Error.new(:not_found, %{setting: key})

  defp setting_error(key, :not_editable),
    do:
      Error.new(:invalid_params, %{
        setting: key,
        reason: "this one belongs to the deployment and cannot be changed from here"
      })

  defp setting_error(key, {:invalid, why}),
    do: Error.new(:invalid_params, %{setting: key, reason: why})

  @doc """
  Test the identity configuration, and optionally a group before making it the admin one.

  Four checks with what each proved, because the design asks for a check list rather than a
  tick: an operator whose sign-in is broken needs to know *which* of the four things is
  wrong, and they are separable. Three are about the provider and come from `OIDC`; the
  fourth is about this plane and is the one that actually decides whether anybody can
  administer anything.

  `group` is what makes this a check rather than a report. The way to lock every
  administrator out of a platform is to save a `platform_admin_group` that nobody is in,
  and the way to not do that is to be told, before saving, how many people would be
  administrators afterwards and whether you are one of them. So the console asks with the
  value in the field, not the value in the database.
  """
  @spec identity_check(actor(), String.t() | nil) :: result()
  def identity_check(actor, group \\ nil) do
    with :ok <- require_admin(actor) do
      candidate = presence(group) || Settings.get("platform_admin_group")
      checks = OIDC.check() ++ [admin_group_check(actor, candidate)]

      {:ok,
       %{
         checks: checks,
         ok: Enum.all?(checks, & &1.ok),
         group: candidate,
         # Not a check, because nothing here can prove it: the provider is the only thing
         # that knows which redirect URIs are registered. Reported so it can be compared
         # against the registration by eye, which is the actual repair.
         redirect_uri: redirect_uri()
       }}
    end
  end

  # Nothing here talks to the provider. It asks this plane's own tables who has arrived
  # carrying the group, which is the thing that decides who is an administrator — a group
  # that exists in Entra and has never appeared in a token grants nobody anything here.
  defp admin_group_check(_actor, nil) do
    OIDC.check_result(
      "Platform admins",
      false,
      "No platform admin group is set, so nobody who signs in is a platform admin.",
      0
    )
  end

  defp admin_group_check(actor, candidate) do
    claim = Settings.get("groups_claim")

    case Identity.get_group(candidate) do
      nil ->
        OIDC.check_result(
          "Platform admins",
          false,
          "#{candidate} has never arrived in the #{claim} claim of anybody's token. Either the group id is wrong, or the provider is not sending group claims, or nobody in it has signed in yet.",
          0
        )

      group ->
        members = Identity.members_of(group)
        you = Enum.any?(members, &(&1.subject == actor.subject))

        OIDC.check_result(
          "Platform admins",
          members != [],
          "#{length(members)} person/people known here carry #{candidate} in the #{claim} claim" <>
            if(you, do: ", including you.", else: ", and you are not one of them."),
          0
        )
    end
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  defp redirect_uri do
    case Settings.get("base_url") do
      nil -> nil
      base -> String.trim_trailing(base, "/") <> "/admin/callback"
    end
  end

  # -- the identity provider --------------------------------------------------

  @sign_in_keys ~w(issuer client_id client_secret authorization_endpoint device_authorization_endpoint token_endpoint scopes mcp_scope)

  @doc """
  The identity provider as the card shows it: every sign-in setting with its value and
  where it came from (a secret as set or not), the URLs this plane needs registered at the
  provider, and how many people have arrived through it.

  Readable by a team admin — "is sign-in pointed at the right tenant" is a question they
  ask when somebody cannot get in — and changed only by a platform admin.
  """
  @spec provider_get(actor()) :: result()
  def provider_get(actor) do
    with :ok <- require_admin(actor), do: {:ok, provider_state()}
  end

  @doc """
  Test a candidate provider before saving it.

  The candidate is the current configuration with the given fields laid over it, so a
  form can ask "what if I saved this" with exactly the values in its fields. Three checks
  from `OIDC.check/1`: discovery answers and calls itself the same thing, it names keys
  that can be read, and the endpoints in the candidate agree with the ones it publishes.
  Nothing is written.
  """
  @spec provider_check(actor(), map()) :: result()
  def provider_check(actor, attrs \\ %{}) do
    with :ok <- require_admin(actor) do
      candidate = candidate_provider(attrs)
      checks = OIDC.check(candidate)

      {:ok,
       %{
         checks: checks,
         ok: Enum.all?(checks, & &1.ok),
         candidate: Map.take(candidate, [:issuer, :token_endpoint, :device_authorization_endpoint])
       }}
    end
  end

  @doc """
  Save the identity provider, behind the check.

  Refused when the candidate fails `provider_check/2` — a provider that does not answer,
  calls itself something else, or publishes different endpoints — unless `force` is set,
  which is for the provider that is down right now and the administrator who knows it.
  A blank field is a field nobody changed, so the secret is not cleared by a form that
  did not retype it; `provider_reset/1` is how everything goes back to the deployment.

  The audit entry carries the diff with the secret as *set* or not, never its value.
  """
  @spec provider_put(actor(), map(), boolean() | String.t() | nil) :: result()
  def provider_put(actor, attrs, force \\ false) do
    with :ok <- require_platform_admin(actor),
         {:ok, attrs} <- sign_in_attrs(attrs),
         :ok <- provider_gate(attrs, force in [true, "true"]) do
      before = comparable_sign_in()

      case Enum.find_value(attrs, &refused_setting(&1, actor)) do
        nil ->
          changes = Audit.diff(before, comparable_sign_in())
          detail = with_rotated(changes, attrs)
          {:ok, _} = Audit.record(actor.subject, "provider.put", "sign-in", detail)
          {:ok, Map.put(provider_state(), :changes, detail)}

        error ->
          error
      end
    end
  end

  @doc """
  Put every sign-in setting back to whatever this plane was deployed with.

  The way back from a provider saved in error: the rows go, the deployment's values are
  read again, and a plane deployed with none has the break-glass door and nothing else,
  which the answer says.
  """
  @spec provider_reset(actor()) :: result()
  def provider_reset(actor) do
    with :ok <- require_platform_admin(actor) do
      before = comparable_sign_in()
      Enum.each(@sign_in_keys, &Settings.reset(&1, actor.subject))
      changes = Audit.diff(before, comparable_sign_in())
      {:ok, _} = Audit.record(actor.subject, "provider.reset", "sign-in", changes)
      {:ok, Map.put(provider_state(), :changes, changes)}
    end
  end

  defp provider_state do
    base = Settings.get("base_url")

    %{
      settings: Enum.filter(Settings.all(), &(&1.group == :sign_in)),
      # What the provider's registration has to know about this plane. Reported rather
      # than checked, because the provider is the only thing that knows what is registered.
      urls: %{
        redirect: at(base, "/admin/callback"),
        discovery: at(base, "/.well-known/troupe"),
        jwks: at(base, "/.well-known/jwks.json"),
        resource_metadata: at(base, "/.well-known/oauth-protected-resource")
      },
      # OpenID Connect, and not SAML: said in the answer so a card can say it where a
      # SAML tool would have an ACS URL and a metadata upload.
      protocol: "oidc",
      known_people: length(Identity.list_users())
    }
  end

  defp at(nil, _path), do: nil
  defp at(base, path), do: String.trim_trailing(base, "/") <> path

  # The current configuration with the candidate laid over it, blank fields ignored.
  defp candidate_provider(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(@sign_in_keys -- ["client_secret", "scopes", "mcp_scope"])
    |> Enum.reduce(OIDC.configured(), fn {key, value}, config ->
      case presence(value) do
        nil -> config
        value -> Map.put(config, String.to_existing_atom(key), value)
      end
    end)
  end

  # Blank fields and fields that still say what the plane already reads are not changes:
  # a form submits every field it has, and a row stored for a value equal to the
  # deployment's would show as "changed here" for nothing.
  defp sign_in_attrs(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.take(@sign_in_keys)
      |> Enum.reject(fn {key, value} -> is_nil(presence(value)) or unchanged?(key, value) end)
      |> Map.new()

    if map_size(attrs) == 0,
      do: {:error, Error.new(:invalid_params, %{missing: "attrs", reason: "nothing to save"})},
      else: {:ok, attrs}
  end

  defp sign_in_attrs(_attrs), do: {:error, Error.new(:invalid_params, %{missing: "attrs"})}

  # A secret replaced by another is "set" before and after, which a diff drops, so the
  # entry names which secrets were given — that they changed, never to what.
  defp with_rotated(changes, attrs) do
    case Map.keys(attrs) |> Enum.filter(&(&1 == "client_secret")) do
      [] -> changes
      rotated -> Map.put(changes, "rotated", rotated)
    end
  end

  # A secret cannot be compared, so a typed one is always a change.
  defp unchanged?("client_secret", _value), do: false

  defp unchanged?(key, value) do
    case Settings.get(key) do
      nil -> false
      list when is_list(list) -> String.split(to_string(value), ~r/[,\s]+/, trim: true) == list
      current -> to_string(value) == to_string(current)
    end
  end

  defp provider_gate(_attrs, true), do: :ok

  defp provider_gate(attrs, false) do
    checks = OIDC.check(candidate_provider(attrs))

    if Enum.all?(checks, & &1.ok) do
      :ok
    else
      {:error,
       Error.new(:invalid_params, %{
         reason:
           "the provider did not stand behind these values; fix them, or save anyway with force if you know the provider is down",
         checks: checks
       })}
    end
  end

  defp refused_setting({key, value}, actor) do
    case Settings.put(key, value, actor.subject) do
      {:ok, _applied} -> nil
      {:error, reason} -> {:error, setting_error(key, reason)}
    end
  end

  # The sign-in settings as a diff can hold them: a secret is `"set"` or `nil`, never its
  # value, so an audit entry about the provider is never an audit entry with a credential.
  defp comparable_sign_in do
    Settings.all()
    |> Enum.filter(&(&1.group == :sign_in))
    |> Map.new(fn
      %{secret: true, key: key, set: set?} -> {key, if(set?, do: "set", else: nil)}
      %{key: key, value: value} -> {key, value}
    end)
  end

  # -- the SCIM connector -----------------------------------------------------

  @doc """
  The SCIM connector as the card shows it: where the provider pushes, whether a token is
  set and where, when it was rotated, when the provider was last heard from, and the
  switch. Never the token.

  Readable by a team admin, because "is provisioning connected" is a question they ask
  when somebody who left is still in their team; changing any of it is a platform
  admin's.
  """
  @spec scim_get(actor()) :: result()
  def scim_get(actor) do
    with :ok <- require_admin(actor), do: {:ok, scim_state()}
  end

  @doc """
  Mint the connector's token and show it once.

  The old token stops working the moment this returns, the same way a principal's does.
  The answer carries `token` and is the only place it ever appears: not in the audit
  entry, not in `scim_get/1`, not in a later page.
  """
  @spec scim_rotate(actor()) :: result()
  def scim_rotate(actor) do
    with :ok <- require_platform_admin(actor) do
      {_connector, token} = Connector.rotate(actor.subject)
      {:ok, _} = Audit.record(actor.subject, "scim.rotate", "connector", %{})
      {:ok, Map.put(scim_state(), :token, token)}
    end
  end

  @doc """
  Forget the connector's token. Every push presenting it answers 401 from now on.

  Destructive, and confirmed by typing this plane's SCIM base URL — a connector has no
  name, and the URL is the one thing about it somebody has in front of them. The
  deployment's own `TROUPE_SCIM_TOKEN`, if there is one, is not touched: that door
  belongs to the deployment and is closed there.
  """
  @spec scim_delete(actor(), String.t()) :: result()
  def scim_delete(actor, base_url) do
    with :ok <- require_platform_admin(actor),
         :ok <- confirm_scim_base_url(base_url) do
      :ok = Connector.delete()
      {:ok, _} = Audit.record(actor.subject, "scim.delete", "connector", %{})
      {:ok, scim_state()}
    end
  end

  @doc """
  Change the connector's switch: whether a group the provider pushes becomes a team.

  Off by default and off for every plane upgrading into this, because a plane that has
  been enabling teams by hand should not wake up with forty new ones. On, a pushed group
  nobody has made a team of becomes one named from its display name, with the platform's
  defaults, audited as `scim`. Turning it off creates no more and deletes none.
  """
  @spec scim_update(actor(), map()) :: result()
  def scim_update(actor, attrs) do
    with :ok <- require_platform_admin(actor) do
      attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
      before = Connector.describe()

      case Connector.update(attrs) do
        {:ok, _connector} ->
          now = Connector.describe()

          changes =
            Audit.diff(
              %{"teams_from_groups" => before.teams_from_groups},
              %{"teams_from_groups" => now.teams_from_groups}
            )

          {:ok, _} = Audit.record(actor.subject, "scim.update", "connector", changes)
          {:ok, Map.put(scim_state(), :changes, changes)}

        {:error, changeset} ->
          {:error, Error.new(:invalid_params, %{reason: inspect(changeset.errors)})}
      end
    end
  end

  defp scim_state do
    described = Connector.describe()
    deployed? = is_binary(Settings.get("scim_token"))

    Map.merge(described, %{
      base_url: scim_base_url(),
      deployed_token_set: deployed?,
      status: scim_status(described, deployed?)
    })
  end

  defp scim_base_url do
    case Settings.get("base_url") do
      nil -> nil
      base -> String.trim_trailing(base, "/") <> "/scim/v2"
    end
  end

  # Four states, said apart: nothing could get in; something could and nothing has; the
  # provider was heard from today; the provider has gone quiet. The last two are the same
  # row read against the clock, and a day is the longest a provider that is configured
  # goes between syncs.
  defp scim_status(%{token_set: false}, false), do: :no_token
  defp scim_status(%{last_seen_at: nil}, _deployed?), do: :never_pushed

  defp scim_status(%{last_seen_at: at}, _deployed?) do
    if DateTime.diff(DateTime.utc_now(), at, :second) < 86_400, do: :connected, else: :quiet
  end

  defp confirm_scim_base_url(base_url) do
    expected = scim_base_url()

    cond do
      is_nil(expected) ->
        {:error,
         Error.new(:invalid_params, %{
           reason: "base_url is not set on this plane, so there is nothing to confirm against"
         })}

      base_url == expected ->
        :ok

      true ->
        {:error,
         Error.new(:invalid_params, %{
           reason: "the base URL to confirm with is #{expected}",
           base_url: expected
         })}
    end
  end

  # -- config bundles ---------------------------------------------------------

  @doc "Every version of a channel, newest first."
  @spec bundles_list(actor(), String.t()) :: result()
  def bundles_list(actor, channel) do
    with :ok <- require_admin(actor) do
      {:ok, channel |> Bundles.list() |> Enum.map(&bundle_summary/1)}
    end
  end

  @doc """
  One version in full: the document, what it carries, and which pods have it.

  Either role, like the list: a bundle holds prompts and skill files and the *names* of
  credentials, never a value, so there is nothing in it a team admin may not read about
  the profiles their team uses.
  """
  @spec bundle_get(actor(), String.t(), integer() | String.t()) :: result()
  def bundle_get(actor, channel, version) do
    with :ok <- require_admin(actor),
         {:ok, bundle} <- fetch_bundle(channel, version) do
      {:ok,
       bundle
       |> bundle_summary()
       |> Map.merge(%{
         content: bundle.content,
         detail: Bundles.describe(bundle),
         adoption: Enum.map(Bundles.profiles_on(channel), &Bundles.adoption(&1, bundle.hash))
       })}
    end
  end

  @doc """
  Check a document the way publishing will, without publishing it.

  The same errors publish would give, as an error rather than a result, so a CLI run in
  a pipeline fails on an invalid bundle and a panel renders both paths the same way.
  """
  @spec bundle_validate(actor(), map()) :: result()
  def bundle_validate(actor, content) do
    with :ok <- require_platform_admin(actor),
         {:ok, parsed} <- validate_bundle(content) do
      {:ok, %{ok: true, summary: Document.summary(parsed), hash: Bundle.hash(content)}}
    end
  end

  @doc """
  What publishing this document would change, and **who loses something**.

  Rule 2 of the console: nothing is applied until its diff has been read. For a bundle
  that matters more than anywhere else, because a bundle is the one document whose change
  reaches into other people's grants — three skills added and one agent removed is the easy
  half, and the half nobody answers is which teams were entitled to the agent that went.

  The diff is `Audit.diff/2` over the summaries, which is the same function that writes the
  audit record. That identity is the point: **the thing you approved and the thing in the
  trail are the same object.** A console computing a preview one way and an audit record
  another way has two descriptions of one change, and the one you read is not the one that
  survives.

  `from` is the channel's current version unless a version is named, which is how the same
  answer serves both questions — what this draft would do, and what one published version
  did against another.

  A team "loses" an entry when it holds an *allow* entitlement naming something this
  version removes. A deny row whose target is gone is not a loss: the team was not getting
  it, and reporting it would bury the rows that matter under the rows that do not.
  """
  @spec bundle_preview(actor(), String.t(), map(), integer() | nil) :: result()
  def bundle_preview(actor, channel, content, from \\ nil) do
    with :ok <- require_admin(actor),
         {:ok, parsed} <- validate_bundle(content),
         {:ok, before} <- baseline(channel, from) do
      after_summary = Document.summary(parsed)
      before_summary = before && Document.summary(before.parsed)

      {:ok,
       %{
         channel: channel,
         from: before && before.version,
         hash: Bundle.hash(content),
         changes: Audit.diff(before_summary || %{}, after_summary),
         removed: removed_entries(before_summary, after_summary),
         losers: losers(channel, removed_entries(before_summary, after_summary))
       }}
    end
  end

  # The version this is measured against: one named, or the channel's current. A channel
  # with nothing published yet has no baseline, and every entry in the document is an
  # addition rather than a change — which is right, and is not an error.
  defp baseline(channel, nil) do
    case Bundles.current(channel) do
      nil -> {:ok, nil}
      bundle -> parsed_baseline(bundle)
    end
  end

  defp baseline(channel, version) do
    with {:ok, bundle} <- fetch_bundle(channel, version), do: parsed_baseline(bundle)
  end

  defp parsed_baseline(bundle) do
    case Document.validate(bundle.content) do
      {:ok, parsed} -> {:ok, %{version: bundle.version, parsed: parsed}}
      # A version that no longer validates is a version this plane published under an
      # older schema. It is still the thing that is running, so it is still the baseline —
      # with nothing to compare, which the caller sees as everything being added.
      {:error, _messages} -> {:ok, nil}
    end
  end

  # `{kind, name}` for everything the new document does not carry and the old one did.
  # Keyed by the entitlement's own kind, because that is what a grant row names.
  @entry_kinds %{
    "agents" => "agent",
    "skills" => "skill",
    "mcp_servers" => "mcp_server",
    "acp_agents" => "acp_agent"
  }

  defp removed_entries(nil, _after_summary), do: []

  defp removed_entries(before_summary, after_summary) do
    for {section, kind} <- @entry_kinds,
        name <- Map.get(before_summary, section, []),
        name not in Map.get(after_summary, section, []),
        do: %{kind: kind, name: name}
  end

  # The teams entitled to something this version takes away. Every profile on the channel,
  # every team granted it, and the allow rows naming a removed entry.
  defp losers(_channel, []), do: []

  defp losers(channel, removed) do
    gone = MapSet.new(removed, &{&1.kind, &1.name})

    for profile <- Bundles.profiles_on(channel),
        grant <- Identity.grants_for_profile(profile),
        team = grant.team,
        row <- Identity.entitlements_for(team, profile),
        row.mode == "allow",
        MapSet.member?(gone, {row.kind, row.name}),
        do: %{team: team.name, profile: profile, kind: row.kind, name: row.name}
  end

  @doc "Publish a new version, which pushes `config.updated` to every pod on the channel."
  @spec bundle_publish(actor(), String.t(), map()) :: result()
  def bundle_publish(actor, channel, content) do
    with :ok <- require_platform_admin(actor) do
      case Bundles.publish(channel, content, by: actor.subject) do
        {:ok, bundle} ->
          {:ok, _} =
            Audit.record(actor.subject, "bundle.publish", channel, %{
              "version" => bundle.version,
              "hash" => bundle.hash,
              "summary" => bundle.summary
            })

          {:ok, bundle_summary(bundle)}

        {:error, {:invalid_bundle, messages}} ->
          {:error, invalid_bundle(messages)}

        {:error, changeset} ->
          {:error, Error.new(:invalid_params, %{reason: inspect(changeset.errors)})}
      end
    end
  end

  @doc "Retire a version, so nothing new starts on it. Running sessions are untouched."
  @spec bundle_retire(actor(), String.t(), integer()) :: result()
  def bundle_retire(actor, channel, version) do
    with :ok <- require_platform_admin(actor) do
      case Bundles.retire(channel, version, by: actor.subject) do
        {:ok, bundle} ->
          {:ok, _} =
            Audit.record(actor.subject, "bundle.retire", channel, %{"version" => version})

          {:ok, bundle_summary(bundle)}

        {:error, reason} ->
          {:error, Error.new(:not_found, %{reason: inspect(reason)})}
      end
    end
  end

  @doc """
  Whether the cluster policy lets a pod reach an MCP server's host.

  The panel's live check while an admin types a URL, and deliberately the same function
  publishing refuses with: a check that disagreed with the refusal would be one an admin
  would learn to ignore.
  """
  @spec mcp_check(actor(), String.t()) :: result()
  def mcp_check(actor, url) do
    with :ok <- require_admin(actor),
         {:ok, host} <- host_of(url) do
      {:ok, %{host: host, allowed: ClusterPolicy.egress_allowed?(host)}}
    end
  end

  defp host_of(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> {:ok, host}
      _ -> {:error, Error.new(:invalid_params, %{reason: "not a URL with a host", url: url})}
    end
  end

  defp host_of(other),
    do: {:error, Error.new(:invalid_params, %{reason: "url is a string", url: other})}

  defp validate_bundle(content) when is_map(content) do
    case Bundles.validate(content) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, {:invalid_bundle, messages}} -> {:error, invalid_bundle(messages)}
    end
  end

  defp validate_bundle(_content), do: {:error, invalid_bundle(["a bundle is a JSON object"])}

  defp invalid_bundle(messages),
    do: Error.new(:invalid_params, %{reason: "invalid bundle", errors: messages})

  defp fetch_bundle(channel, version) do
    case Bundles.get(channel, version) do
      nil -> {:error, Error.new(:not_found, %{channel: channel, version: version})}
      bundle -> {:ok, bundle}
    end
  end

  @doc "Make somebody an administrator of one team."
  @spec team_admin_add(actor(), String.t(), String.t()) :: result()
  def team_admin_add(actor, name, subject) do
    with :ok <- require_platform_admin(actor),
         {:ok, team} <- fetch_team(actor, name) do
      {:ok, _} = Identity.add_team_admin(team, subject, actor.subject)
      {:ok, _} = Audit.record(actor.subject, "team.admin.add", name, %{"subject" => subject})

      {:ok, %{team: name, admins: Identity.admins_of(team)}}
    end
  end

  @doc """
  Take the role away.

  A platform admin's job, not a team admin's: a team admin who could remove the others
  could make themselves the only one, which is an escalation dressed as a tidy-up.
  """
  @spec team_admin_remove(actor(), String.t(), String.t()) :: result()
  def team_admin_remove(actor, name, subject) do
    with :ok <- require_platform_admin(actor),
         {:ok, team} <- fetch_team(actor, name) do
      :ok = Identity.remove_team_admin(team, subject)
      {:ok, _} = Audit.record(actor.subject, "team.admin.remove", name, %{"subject" => subject})

      {:ok, %{team: name, admins: Identity.admins_of(team)}}
    end
  end

  # -- service principals -----------------------------------------------------

  @doc "A team's principals: what each may use, when it was last used, whether it still works."
  @spec principals_list(actor(), String.t()) :: result()
  def principals_list(actor, team_name) do
    with {:ok, team} <- fetch_team(actor, team_name) do
      {:ok, team |> Principals.list() |> Enum.map(&principal_summary/1)}
    end
  end

  @doc """
  Create a principal for a team, returning the secret exactly once.

  A team admin's action, because a principal spends the team's budget with nobody
  watching, and that is the team's decision. The secret is in the result and nowhere
  else: not in the audit row, not in a log line, not in this database.
  """
  @spec principal_create(actor(), String.t(), map()) :: result()
  def principal_create(actor, team_name, attrs) do
    with {:ok, team} <- fetch_team(actor, team_name) do
      case Principals.create(team, attrs, actor.subject) do
        {:ok, principal, secret} ->
          {:ok, _} =
            Audit.record(actor.subject, "principal.create", principal.subject, %{
              "team" => team.name,
              "profiles" => principal.profiles,
              "sponsor" => principal.sponsor_subject
            })

          {:ok, principal |> principal_summary() |> Map.put(:secret, secret)}

        {:error, :no_profiles} ->
          {:error, Error.new(:invalid_params, %{missing: "profiles"})}

        {:error, {:not_granted, outside}} ->
          reason = "#{team.name} is not granted #{Enum.join(outside, ", ")}"
          {:error, Error.new(:invalid_params, %{reason: reason, profiles: outside})}

        # Named separately from any other refusal, because each one is a different thing
        # for the person filling the form in: a field left empty, a name spelt wrong, a
        # person who has left, a person who is not on this team.
        {:error, :no_sponsor} ->
          {:error,
           Error.new(:invalid_params, %{
             missing: "sponsor",
             reason: "a principal names a person answerable for what it does"
           })}

        {:error, {:no_such_sponsor, subject}} ->
          {:error, Error.new(:invalid_params, %{sponsor: subject, reason: "no such person"})}

        {:error, {:sponsor_inactive, subject}} ->
          {:error,
           Error.new(:invalid_params, %{
             sponsor: subject,
             reason: "that person has been deactivated"
           })}

        {:error, {:sponsor_not_in_team, subject, team_name}} ->
          {:error,
           Error.new(:invalid_params, %{
             sponsor: subject,
             reason: "#{subject} is not a member of #{team_name}"
           })}

        {:error, changeset} ->
          {:error, Error.new(:invalid_params, %{reason: inspect(changeset.errors)})}
      end
    end
  end

  @doc "Mint a new secret. The old one stops working at once; the new one is shown once."
  @spec principal_rotate(actor(), String.t()) :: result()
  def principal_rotate(actor, subject) do
    with {:ok, principal} <- fetch_principal(actor, subject),
         {:ok, rotated, secret} <- Principals.rotate(principal) do
      {:ok, _} = Audit.record(actor.subject, "principal.rotate", subject, %{})
      {:ok, rotated |> principal_summary() |> Map.put(:secret, secret)}
    end
  end

  @doc "Disable a principal. Its next call is `unauthenticated`; its sessions are kept."
  @spec principal_disable(actor(), String.t()) :: result()
  def principal_disable(actor, subject) do
    with {:ok, principal} <- fetch_principal(actor, subject),
         {:ok, disabled} <- Principals.disable(principal) do
      {:ok, _} = Audit.record(actor.subject, "principal.disable", subject, %{})
      {:ok, principal_summary(disabled)}
    end
  end

  # -- triggers ---------------------------------------------------------------

  @doc "A team's triggers."
  @spec triggers_list(actor(), String.t()) :: result()
  def triggers_list(actor, team_name) do
    with {:ok, team} <- fetch_team(actor, team_name) do
      {:ok, team |> Triggers.list() |> Enum.map(&Triggers.trigger_json/1)}
    end
  end

  @doc """
  Create or update a trigger by team and name, returning the diff that was applied.

  Partial on update, so enabling and disabling from the panel is the same call as
  putting a whole file from the CLI. A team admin's action, like a principal's creation
  and for the same reason.

  The audit row names the revision the document now hashes to, so the audit trail and
  the revision point at each other: a run says which revision it ran, and this says who
  made that revision and what moved. A put that changes nothing names the revision that
  was already there, which is the honest answer and not a new one.
  """
  @spec trigger_put(actor(), map()) :: result()
  def trigger_put(actor, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    with {:ok, team} <- fetch_team(actor, attrs["team"]),
         {:ok, name} <- require_name(attrs) do
      before = Triggers.get(team, name)

      case Triggers.put(team, attrs, actor.subject) do
        {:ok, trigger} ->
          changes = Audit.diff(comparable(before), comparable(trigger))
          {:ok, revision} = Triggers.revise(trigger)

          detail =
            Map.merge(changes, %{
              "__revision__" => revision.revision,
              "__revision_hash__" => revision.hash
            })

          {:ok, _} = Audit.record(actor.subject, "trigger.put", "#{team.name}/#{name}", detail)

          {:ok,
           %{
             trigger: Triggers.trigger_json(trigger),
             changes: changes,
             revision: Revision.json(revision)
           }}

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end
  end

  @doc """
  Mint a key for a trigger, replacing whatever it had, and return it once.

  The only time the key is legible. It is not in `admin.triggers.list`, not in the audit
  row this writes, and not recoverable: an administrator who loses it rotates again,
  which is the same call and costs them the old one.

  The old key stops working immediately. A rotation is usually somebody reacting to a
  leak, and an overlap window would mean the leaked key went on firing for as long as
  the window lasted.
  """
  @spec trigger_key_rotate(actor(), String.t(), String.t()) :: result()
  def trigger_key_rotate(actor, team_name, name) do
    with {:ok, team} <- fetch_team(actor, team_name),
         {:ok, trigger} <- fetch_trigger(team, name) do
      {:ok, rotated, key} = Triggers.rotate_key(trigger, actor.subject)

      {:ok, _} =
        Audit.record(actor.subject, "trigger.key.rotate", "#{team.name}/#{name}", %{
          "had_key" => is_binary(trigger.key_hash)
        })

      {:ok,
       %{
         team: team.name,
         name: name,
         url: "/trigger/#{trigger.id}",
         key: key,
         rotated_at: DateTime.to_iso8601(rotated.key_rotated_at)
       }}
    end
  end

  @doc """
  Set or clear a person's own spend ceiling, across every team they are in.

  A platform admin's, not a team admin's. A cap that follows somebody between teams is a
  statement about the person rather than about any one team, and a team admin who could
  set it could cap somebody in a team they do not administer.

  `nil` or `0` clears it: absence means everything, exactly as it does at every other
  rung.
  """
  @spec person_budget(actor(), String.t(), integer() | nil) :: result()
  def person_budget(actor, subject, budget_micros) do
    with :ok <- require_platform_admin(actor),
         {:ok, user} <- fetch_user(subject) do
      before = user.budget_micros

      case Identity.set_budget(user, budget_micros) do
        {:ok, updated} ->
          changes = Audit.diff(%{budget_micros: before}, %{budget_micros: updated.budget_micros})
          {:ok, _} = Audit.record(actor.subject, "person.budget", subject, changes)

          {:ok, %{subject: subject, budget_micros: updated.budget_micros, changes: changes}}

        {:error, changeset} ->
          {:error, Error.new(:invalid_params, %{reason: inspect(changeset.errors)})}
      end
    end
  end

  @doc """
  Every ceiling that applies to a person here, narrowest first.

  The answer to "why was that refused": four numbers, in the order they are checked,
  with the one that would bind first at the top. A person told they are over budget
  should be able to see which of the four without asking anybody.
  """
  @spec budget_explain(actor(), String.t(), String.t() | nil) :: result()
  def budget_explain(actor, subject, team_name) do
    with :ok <- require_platform_admin(actor),
         {:ok, team} <- optional_team(actor, team_name) do
      {:ok, Budget.ceilings(team, subject)}
    end
  end

  defp optional_team(_actor, nil), do: {:ok, nil}
  defp optional_team(actor, name), do: fetch_team(actor, name)

  defp fetch_user(subject) when is_binary(subject) do
    case Identity.get_user(subject) do
      nil -> {:error, Error.new(:not_found, %{subject: subject})}
      user -> {:ok, user}
    end
  end

  defp fetch_user(_other), do: {:error, Error.new(:invalid_params, %{missing: "subject"})}

  defp member_summary(user) do
    %{
      subject: user.subject,
      display_name: user.display_name,
      budget_micros: user.budget_micros,
      spent_micros: Ledger.spent_micros_for(user.subject),
      reserved_micros:
        user.subject |> Ledger.open_reservations_for() |> Map.values() |> Enum.sum()
    }
  end

  @doc "Remove a trigger. Its runs go with it; the sessions they created do not."
  @spec trigger_delete(actor(), String.t(), String.t()) :: result()
  def trigger_delete(actor, team_name, name) do
    with {:ok, team} <- fetch_team(actor, team_name),
         {:ok, trigger} <- fetch_trigger(team, name) do
      detail = comparable(trigger)
      {:ok, _} = Audit.record(actor.subject, "trigger.delete", "#{team.name}/#{name}", detail)
      :ok = Triggers.delete(trigger)
      {:ok, %{team: team.name, name: name, deleted: true}}
    end
  end

  @doc """
  Every revision of a trigger, newest first.

  The document each one froze is included, because the question this answers is "what
  did the run I am looking at actually say" and an answer that was only a hash would
  send the reader back to the database.
  """
  @spec trigger_revisions(actor(), String.t(), String.t()) :: result()
  def trigger_revisions(actor, team_name, name) do
    with {:ok, team} <- fetch_team(actor, team_name),
         {:ok, trigger} <- fetch_trigger(team, name) do
      revisions =
        trigger
        |> Triggers.revisions()
        |> Enum.map(fn revision ->
          revision
          |> Revision.json()
          |> Map.put("document", Revision.document(revision))
        end)

      {:ok, revisions}
    end
  end

  @doc """
  Fire a trigger now, by hand.

  The same `fire/5` a schedule or an executor reaches, with an idempotency key that
  names the person and the moment, so a second click a minute later is a second run and
  a retry of a failed one is not.

  The source is `manual` and the console is the only door that may say so: a person's
  hand is the one thing about a run that cannot be inferred afterwards.
  """
  @spec trigger_run(actor(), String.t(), String.t()) :: result()
  def trigger_run(actor, team_name, name) do
    with {:ok, team} <- fetch_team(actor, team_name),
         {:ok, trigger} <- fetch_trigger(team, name) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      key = "manual:#{trigger.id}:#{actor.subject}:#{DateTime.to_iso8601(now)}"
      event = %{"kind" => "manual", "by" => actor.subject, "at" => DateTime.to_iso8601(now)}

      {:ok, _} =
        Audit.record(actor.subject, "trigger.run", "#{team.name}/#{name}", %{"run" => key})

      case Triggers.fire(trigger, "manual", key, event, actor.subject) do
        {:ok, fired} -> {:ok, Triggers.fired_json(fired)}
        {:error, %Error{} = error} -> {:error, error}
      end
    end
  end

  @doc "A team's runs, newest first; `trigger:` narrows to one, `limit:` caps the list."
  @spec runs_list(actor(), keyword()) :: result()
  def runs_list(actor, opts \\ []) do
    case Keyword.get(opts, :team) do
      nil -> runs_across_teams(actor, opts)
      name -> with {:ok, team} <- fetch_team(actor, name), do: {:ok, runs_of(team, opts)}
    end
  end

  # Every team this actor administers. Review's question — of everything that fired, what
  # needs a person — is not a question about one team, and asking it one team at a time is
  # how a run that failed in the team somebody was not looking at goes unread.
  defp runs_across_teams(actor, opts) do
    with :ok <- require_admin(actor) do
      {:ok, actor |> visible_teams() |> Enum.flat_map(&runs_of(&1, opts))}
    end
  end

  defp runs_of(team, opts) do
    team
    |> Triggers.runs(Keyword.take(opts, [:trigger, :limit]))
    |> Enum.map(fn {run, trigger, session} ->
      run |> Triggers.run_json(session) |> Map.put("trigger", trigger.name)
    end)
  end

  @doc """
  Mark a run reviewed, by the session it created.

  What Review is for. A run that ended badly and that nobody has looked at is the state the
  whole screen exists to empty, and an administrator who has looked at one has to be able
  to say so — otherwise the list is a backlog that only grows and stops being read.

  Keyed by the session rather than the run, because that is the identifier a person has in
  front of them and the one the run already carries. A run that created no session cannot
  be reviewed: there is nothing to have looked at.
  """
  @spec run_review(actor(), String.t()) :: result()
  def run_review(actor, session_id) do
    with :ok <- require_admin(actor),
         {:ok, session} <- fetch_session(actor, session_id) do
      :ok = Triggers.reviewed(session.id, actor.subject)
      {:ok, _} = Audit.record(actor.subject, "run.review", session.id, %{}, kind: "run")
      {:ok, %{session_id: session.id, reviewed_by: actor.subject}}
    end
  end

  @doc """
  What this plane talks to that is not a person: servers, hosts and notification targets.

  Three lists that were each somebody's private knowledge, and each of them answers a
  question that has been answered by reading a values file until now.

  * **Servers on more than one profile.** A server carried by two bundles is an
    organisation's integration rather than one profile's, and it is connected, credentialed
    and retired once. Which profiles carry it is the useful column, because it is the blast
    radius of retiring it.
  * **Every host anything here dials**, each marked allowed or not by the same
    `ClusterPolicy.egress_allowed?/1` a pod's NetworkPolicy is generated from. A host in a
    bundle that the policy refuses is a tool that will fail at the moment somebody uses it,
    and this is where that is visible before then rather than after.
  * **Notification targets**, with the rule they are held to: absolute, and not loopback.
    A relative target resolved against the plane's own base URL is the advisory LangGraph
    shipped in 2026, and it is cheaper to have this check than to explain it.

  Read-only. The allowlist is generated from what each component declares it dials, and an
  allowlist edited in two places is an allowlist nobody trusts — so this page says where
  each host comes from and leaves editing to the thing that declared it.
  """
  @spec integrations(actor()) :: result()
  def integrations(actor) do
    with :ok <- require_admin(actor) do
      servers = servers_by_profile()

      {:ok,
       %{
         servers: Enum.filter(servers, &(length(&1.profiles) > 1)),
         profile_servers: Enum.reject(servers, &(length(&1.profiles) > 1)),
         egress: egress_hosts(servers),
         notify: notify_targets(actor)
       }}
    end
  end

  # Every MCP server any channel's current bundle carries, with the profiles that carry it.
  defp servers_by_profile do
    for profile <- Fleet.list_profiles(),
        server <- bundle_servers(profile),
        reduce: %{} do
      acc ->
        entry =
          Map.get(acc, server.name, %{
            name: server.name,
            url: server.url,
            credential_mode: to_string(server.credential_mode),
            credential_ref: server.credential_ref,
            profiles: []
          })

        Map.put(acc, server.name, %{entry | profiles: Enum.uniq([profile.name | entry.profiles])})
    end
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  defp bundle_servers(%{config_bundle_channel: channel}) do
    with %{} = bundle <- Bundles.current(channel),
         {:ok, %{mcp_servers: servers}} <- Document.validate(bundle.content) do
      servers
    else
      _absent -> []
    end
  end

  defp bundle_servers(_profile), do: []

  # The hosts, each against the policy that will actually decide. Two sources today —
  # a server's URL and a profile's declared FQDNs — and the source is named because the
  # repair is made where the host was declared rather than here.
  defp egress_hosts(servers) do
    from_servers =
      for server <- servers,
          {:ok, host} <- [host_of(server.url)],
          do: %{host: host, from: server.name}

    from_profiles =
      for profile <- Fleet.list_profiles(),
          host <- get_in(profile.spec || %{}, ["egress", "fqdns"]) || [],
          do: %{host: host, from: profile.name}

    (from_servers ++ from_profiles)
    |> Enum.uniq_by(& &1.host)
    |> Enum.sort_by(& &1.host)
    |> Enum.map(&Map.put(&1, :allowed, ClusterPolicy.egress_allowed?(&1.host)))
  end

  # Where a trigger sends its outcome, and whether that target still passes the rule it
  # was accepted under. Checked again here rather than trusted: a target that was allowed
  # when it was saved and is not now is exactly what somebody needs told.
  defp notify_targets(actor) do
    for team <- visible_teams(actor),
        trigger <- Triggers.list(team),
        is_binary(trigger.notify_url),
        trigger.notify_url != "" do
      %{
        team: team.name,
        trigger: trigger.name,
        url: trigger.notify_url,
        refusal: refusal_for(trigger.notify_url)
      }
    end
  end

  defp refusal_for(url) do
    case Notify.validate(url) do
      :ok -> nil
      {:error, reason} -> reason
    end
  end

  # -- audit ------------------------------------------------------------------

  @doc "Who changed what, newest first."
  @spec audit_list(actor(), keyword()) :: result()
  def audit_list(actor, opts \\ []) do
    with :ok <- require_admin(actor) do
      {:ok, opts |> Audit.list() |> Enum.map(&audit_summary/1)}
    end
  end

  @doc """
  Check that the audit trail has not been altered, and name the first row that has.

  A table of rows is exactly as trustworthy as the database it is in: somebody who can
  write to PostgreSQL can change what a record says happened, and until there was a chain
  nothing would have said so. Each row carries a digest of its own content and the digest
  of the row before it, over canonical JSON and excluding `prev_hash` — the same rule the
  session log has used since W1, so a verifier recomputes the chain from stored data alone.

  Two failures, reported apart because the repairs differ. `:altered` is a row whose
  content no longer hashes to what it says; `:chain_broken` is a row whose predecessor is
  not the one that was there — something removed, or inserted.

  A platform admin's, not a team admin's: the trail is the whole plane's, and a check that
  answered "somewhere in the part you cannot see" would be worse than no check.
  """
  @spec audit_verify(actor()) :: result()
  def audit_verify(actor) do
    with :ok <- require_platform_admin(actor) do
      {:ok, Audit.verify()}
    end
  end

  # The grant is the plane's record and is already made; rewriting the custom resource's
  # `teams` is a projection of it. A cluster that cannot be reached leaves the projection
  # stale for as long as it takes the operator's next resync, which is the right cost —
  # failing the grant would make the plane's own state depend on the cluster being up.
  # What happened in the cluster, reported rather than swallowed: a profile that was
  # saved but not applied is a state a person needs to see, and it is the normal state in
  # GitOps mode until Flux catches up.
  defp provision(profile, actor) do
    case Provision.apply(profile, actor) do
      {:ok, state} -> state
      {:error, reason} -> %{state: :not_applied, reason: inspect(reason)}
    end
  end

  defp unprovision(profile, actor) do
    case Provision.remove(profile, actor) do
      {:ok, state} -> state
      {:error, reason} -> %{state: :not_applied, reason: inspect(reason)}
    end
  end

  # A team's volume is part of what `teams` projects — whether there is one at all, and
  # which class and size it asks for — so changing it changes what every profile the team
  # is granted on should say. Granting re-projects and revoking re-projects; updating did
  # not, because until the volume fields were projected there was nothing on a team that
  # the cluster could see. Now there is, and a class edited in the panel that never
  # reached the cluster would be the worst kind of wrong: the page says one thing, the
  # profile says another, and nothing reconciles them until somebody happens to re-grant.
  # `Audit.diff/2` keys by the field's name as a string, and `comparable/1` already takes
  # both of these, so a change to either is visible here without asking the team again.
  @volume_fields ~w(volume_storage_class volume_size)

  defp reproject(team, changes, actor) do
    if Enum.any?(@volume_fields, &Map.has_key?(changes, &1)) do
      team
      |> Identity.grants_for_team()
      |> Enum.each(&project(&1.profile, actor))
    end

    :ok
  end

  defp project(profile, actor) do
    case Provision.sync_teams(profile, actor) do
      {:ok, _state} ->
        :ok

      {:error, reason} ->
        Logger.warning("troupe plane: #{profile}'s teams are stale: #{inspect(reason)}")
    end
  end

  # -- authorisation ----------------------------------------------------------

  defp require_admin(actor) do
    if admin?(actor),
      do: :ok,
      else: {:error, Error.new(:forbidden, %{required_role: "team_admin"})}
  end

  defp require_platform_admin(%{role: :platform_admin}), do: :ok

  defp require_platform_admin(_actor) do
    {:error, Error.new(:forbidden, %{required_role: "platform_admin"})}
  end

  # Not-found rather than forbidden, because whether a team exists is itself something a
  # person who may not see it should not learn.
  defp fetch_team(actor, name) do
    cond do
      not admin?(actor) ->
        {:error, Error.new(:forbidden, %{required_role: "team_admin"})}

      not is_binary(name) ->
        {:error, Error.new(:invalid_params, %{missing: "team"})}

      actor.role == :team_admin and name not in actor.teams ->
        {:error, Error.new(:not_found, %{team: name})}

      team = Identity.get_team(name) ->
        {:ok, team}

      true ->
        {:error, Error.new(:not_found, %{team: name})}
    end
  end

  # A principal is reached through its team, which its subject names, so the same rule
  # applies: a team admin sees their own team's and no other's.
  defp fetch_principal(actor, subject) do
    with {:ok, team_name, _name} <- parse_principal(subject),
         {:ok, team} <- fetch_team(actor, team_name) do
      case Principals.get(subject) do
        %ServicePrincipal{team_id: team_id} = principal when team_id == team.id ->
          {:ok, principal}

        _ ->
          {:error, Error.new(:not_found, %{principal: subject})}
      end
    end
  end

  defp parse_principal(subject) when is_binary(subject) do
    case ServicePrincipal.parse_subject(subject) do
      {:ok, team, name} ->
        {:ok, team, name}

      :error ->
        {:error, Error.new(:invalid_params, %{reason: "a principal is svc:<team>/<name>"})}
    end
  end

  defp parse_principal(_subject), do: {:error, Error.new(:invalid_params, %{missing: "subject"})}

  defp fetch_trigger(team, name) when is_binary(name) do
    case Triggers.get(team, name) do
      nil -> {:error, Error.new(:not_found, %{team: team.name, trigger: name})}
      trigger -> {:ok, trigger}
    end
  end

  defp fetch_trigger(_team, _name), do: {:error, Error.new(:invalid_params, %{missing: "name"})}

  defp fetch_profile(name) do
    case Fleet.get_profile(name) do
      nil -> {:error, Error.new(:not_found, %{profile: name})}
      profile -> {:ok, profile}
    end
  end

  defp fetch_session(actor, session_id) do
    case Sessions.get(session_id) do
      nil ->
        {:error, Error.new(:not_found, %{session_id: session_id})}

      session ->
        if visible?(actor, session),
          do: {:ok, session},
          else: {:error, Error.new(:not_found, %{session_id: session_id})}
    end
  end

  defp visible?(%{role: :platform_admin}, _session), do: true
  defp visible?(actor, session), do: session.team_id in team_ids(actor)

  defp require_name(attrs) do
    case attrs[:name] || attrs["name"] do
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> {:error, Error.new(:invalid_params, %{missing: "name"})}
    end
  end

  # -- what each actor sees ---------------------------------------------------

  defp visible_teams(%{role: :platform_admin}), do: Identity.list_teams()
  defp visible_teams(actor), do: Enum.filter(Identity.list_teams(), &(&1.name in actor.teams))

  defp team_ids(actor), do: actor |> visible_teams() |> Enum.map(& &1.id)

  defp profiles_for(%{role: :platform_admin}), do: Fleet.list_profiles()

  defp profiles_for(actor) do
    granted =
      actor
      |> visible_teams()
      |> Enum.flat_map(&Enum.map(Identity.grants_for_team(&1), fn grant -> grant.profile end))
      |> MapSet.new()

    Enum.filter(Fleet.list_profiles(), &MapSet.member?(granted, &1.name))
  end

  defp count_sessions(actor, state) do
    Sessions.count_for_admin(team_ids(actor), actor.role == :platform_admin, state)
  end

  # -- rendering --------------------------------------------------------------

  defp profile_summary(profile) do
    workers = Fleet.list_workers(profile.name)

    %{
      name: profile.name,
      # What an administrator answers, first, because it is what they came for.
      size_class: profile.size_class,
      size_class_summary: SizeClass.get(profile.size_class).summary,
      max_sessions: profile.max_sessions,
      warm_workers: profile.warm_workers,
      # What the plane decided from it. Shown, not offered: a console should be able to
      # say how many workers are up and why, and an administrator who wants to know what
      # a class costs should not have to read the custom resource to find out.
      replicas: profile.replicas,
      sessions_per_pod: profile.sessions_per_pod,
      capacity_sessions: profile.replicas * profile.sessions_per_pod,
      channel: profile.config_bundle_channel,
      image: profile.image,
      # What makes these workers exist, and what that substrate does *not* guarantee.
      # Named individually rather than summed into a flag: "unenforced" is not a useful
      # thing to tell somebody deciding whether their team's work may run there.
      provisioner: profile.provisioner,
      missing_guarantees: profile |> Provisioner.missing() |> Enum.map(&to_string/1),
      conditions: Provision.conditions(profile),
      pods:
        Enum.map(workers, fn worker ->
          %{
            pod: worker.pod_name,
            ordinal: worker.ordinal,
            healthy: worker.healthy,
            draining: worker.draining,
            # Carried so a console can tell silence from failure. A pod that has never
            # reported is unknown; one that reported and then said it was unhealthy is
            # broken, and a console that called both broken cries wolf in a partition.
            last_seen_at: worker.last_heartbeat_at,
            capacity: worker.capacity,
            active_sessions: worker.active_sessions,
            disk_fraction: Worker.disk_fraction(worker),
            version: worker.version,
            bundle_hash: worker.bundle_hash,
            worker_id: worker.id
          }
        end),
      capacity: Enum.sum(Enum.map(workers, & &1.capacity)),
      active_sessions: Enum.sum(Enum.map(workers, & &1.active_sessions))
    }
  end

  defp bundle_state(profile) do
    channel = profile.config_bundle_channel

    case Bundles.current(channel) do
      nil ->
        %{channel: channel, published: nil, adopted?: nil}

      bundle ->
        Map.merge(
          %{channel: channel, published: bundle.version},
          Bundles.adoption(profile.name, bundle.hash)
        )
    end
  end

  defp team_detail(team) do
    %{
      name: team.name,
      # What the ladder makes of this team's laddered settings: the value in force, the
      # rung that decided it, and every rung that had an opinion. Beside the team's own
      # columns rather than instead of them — an administrator looking at a value that is
      # not the one they set has to be able to see both.
      effective: Ladder.all(team),
      budget_micros: team.budget_micros,
      budget_period: team.budget_period,
      members_may_control: team.members_may_control,
      idle_timeout_seconds: team.idle_timeout_seconds,
      cache_eviction_days: team.cache_eviction_days,
      erase_after_days: team.erase_after_days,
      pins_allowed: team.pins_allowed,
      volume_storage_class: team.volume_storage_class,
      volume_size: team.volume_size,
      allow_unenforced_workers: team.allow_unenforced_workers,
      admins: Identity.admins_of(team),
      grants:
        Enum.map(
          Identity.grants_for_team(team),
          &%{profile: &1.profile, volume_mode: &1.volume_mode}
        ),
      # The groups this team draws its members from. A team links to any number of them
      # and its membership is the union, so this is the list an administrator edits —
      # rather than the members, which are still nobody's here to edit.
      groups:
        Enum.map(Identity.links_of(team), fn link ->
          %{
            external_id: link.group.external_id,
            display_name: link.group.display_name,
            issuer: link.issuer,
            linked_by: link.linked_by
          }
        end),
      # Read-only, always: membership comes from the identity provider and a method to
      # change it would be a second source of truth for who is in a team.
      #
      # Their own ceilings come with them, because the question a team admin looking at a
      # budget asks next is which of their people is near theirs — and a cap that follows
      # somebody between teams is invisible on a page organised by team unless it is put
      # here.
      members: Enum.map(Identity.members_of_team(team), &member_summary/1),
      # What the team has actually spent, against what it promised. Both are aggregates
      # over an append-only table and both go through `Ledger.Cache`, so a page that is
      # reloaded costs a lookup rather than a scan.
      spent_micros: Ledger.spent_micros(team.id),
      reserved_micros: team.id |> Ledger.open_reservations() |> Map.values() |> Enum.sum(),
      # The five models the money went on. Five because it is a summary on a page about
      # something else; the whole list is what `Ledger.breakdown/3` is for.
      spend_by_model: team.id |> Ledger.breakdown(:model) |> Enum.take(5)
    }
  end

  defp team_spend(team) do
    %{
      name: team.name,
      budget_micros: team.budget_micros,
      # The ceiling means nothing without the period it is measured over, and Overview
      # renders both in the same sentence.
      budget_period: team.budget_period,
      spent_micros: Ledger.spent_micros(team.id),
      # `open_reservations/1` answers `%{session_id => amount_micros}`, not a list of
      # rows: mapping `& &1.amount_micros` over it hands the function a `{id, amount}`
      # tuple and raises `BadMapError`. Harmless while a team had nothing reserved —
      # `Enum.map` over an empty map is `[]` — and a 500 on the overview page the moment
      # one session was running. `team_detail/1` above takes `Map.values/1`; so does this.
      reserved_micros: team.id |> Ledger.open_reservations() |> Map.values() |> Enum.sum()
    }
  end

  defp session_summary(session) do
    %{
      id: session.id,
      owner: session.owner_subject,
      profile: session.profile,
      state: session.state,
      visibility: session.visibility,
      epoch: session.epoch,
      last_seq: session.last_seq,
      object_bytes: session.object_bytes,
      workspace_bytes: session.workspace_bytes,
      pinned: session.pinned,
      pinned_by: session.pinned_by,
      last_active_at: session.last_active_at
    }
  end

  # Never the hash, never the salt: what a principal is, and whether it still works.
  defp principal_summary(principal) do
    %{
      subject: principal.subject,
      name: principal.name,
      description: principal.description,
      profiles: principal.profiles,
      created_by: principal.created_by,
      created_at: principal.inserted_at,
      sponsor: principal.sponsor_subject,
      disabled_at: principal.disabled_at,
      disabled_reason: principal.disabled_reason,
      last_used_at: principal.last_used_at,
      enabled: ServicePrincipal.enabled?(principal),
      # Three states, not two. A console that shows `enabled: false` for both a principal
      # somebody disabled and one whose sponsor left sends people looking for a fault
      # where there is a field to fill in.
      state: ServicePrincipal.state(principal)
    }
  end

  defp bundle_summary(bundle) do
    %{
      channel: bundle.channel,
      version: bundle.version,
      hash: bundle.hash,
      summary: bundle.summary,
      published_at: bundle.published_at,
      published_by: bundle.published_by,
      retired_at: bundle.retired_at
    }
  end

  defp audit_summary(event) do
    %{
      actor: event.actor,
      action: event.action,
      subject_kind: event.subject_kind,
      subject_id: event.subject_id,
      detail: event.detail,
      occurred_at: event.occurred_at
    }
  end

  # The fields an audit diff is taken over: what was asked for, never what is running.
  defp comparable(nil), do: %{}

  defp comparable(%Fleet.Profile{} = profile) do
    Map.take(profile, [
      :replicas,
      :sessions_per_pod,
      :config_bundle_channel,
      :image,
      :workers_domain,
      :spec
    ])
  end

  defp comparable(%Identity.Team{} = team) do
    Map.take(team, [
      :budget_micros,
      :budget_period,
      :members_may_control,
      :idle_timeout_seconds,
      :cache_eviction_days,
      :erase_after_days,
      :pins_allowed,
      :volume_storage_class,
      :volume_size
    ])
  end

  defp comparable(%Triggers.Trigger{} = trigger) do
    Map.take(trigger, [
      :principal_id,
      :profile,
      :agent,
      :enabled,
      :source,
      :prompt_template,
      :terms,
      :visibility,
      :review,
      :notify,
      :concurrency
    ])
  end

  defp comparable(other), do: other

  # The same fields as `comparable/1`, from the loose map a form produces.
  defp comparable_attrs(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.drop(["__verdict__", "__preview__"])
  end
end
