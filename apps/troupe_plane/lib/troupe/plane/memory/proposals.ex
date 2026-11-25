defmodule Troupe.Plane.Memory.Proposals do
  @moduledoc """
  What an agent may write back above its person's own memory (#55): a proposal. `remember`
  with `level: "team"` or `level: "organisation"` sends one entry under a topic, which is
  kept here with the session, the agent and the person it came from, and is in no document:
  no session reads it. An administrator who may change that level (a team's admins and the
  platform admins for a team's, a platform admin for the organisation's) accepts it, which
  writes it into the document as an entry with that provenance (`Memory.append_entry/5`), or
  declines it with a sentence. Either way the session it came from is told in a line: a
  pod's at once, a machine's at its daemon's next poll of `me.memory`, which carries the
  person's own proposals.

  The setting `memory_proposals` switches them off, and a profile's `memoryProposals: false`
  for its pods' sessions; a proposal then is refused in words and nothing is kept. Each person has at most twenty pending at once, so an agent in a loop does
  not fill an administrator's queue. A proposal, an acceptance and a refusal are each an
  audit row (`memory.propose`, `memory.proposal.accept`, `memory.proposal.decline`) on the
  level's subject, never with the entry's text, as a save's row holds none.
  """

  import Ecto.Query

  alias Troupe.Plane.{Audit, Fleet, Identity, Memory, Repo, Sessions, Settings}
  alias Troupe.Plane.Control.Router
  alias Troupe.Plane.Identity.{Team, User}
  alias Troupe.Plane.Memory.Proposal

  @pending_per_person 20
  @shown_days 7
  @reason_bytes 1_024

  @instead "nothing was proposed. Remember it for this repository instead, or in the " <>
             "person's own memory (level me)"

  @doc "Whether proposals are taken on this plane (the setting `memory_proposals`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Settings.get("memory_proposals") != false

  @doc """
  The sentence a proposal is refused with while they are switched off: on the plane by the
  setting, or with a profile's name, for that profile's sessions by its `memoryProposals`.
  The two say the same thing and offer the same instead, naming what switched them off.
  """
  @spec off_reason(String.t() | nil) :: String.t()
  def off_reason(profile \\ nil)

  def off_reason(nil),
    do:
      "proposals to a team's or the organisation's memory are switched off on this plane " <>
        "(the setting memory_proposals); " <> @instead

  def off_reason(profile),
    do:
      "proposals to a team's or the organisation's memory are switched off for the sessions " <>
        "of the profile #{profile} (its memoryProposals is false); " <> @instead

  @doc """
  The sentence a proposal from a throwaway session is refused with. Its erasure would take
  the proposal out of the administrator's queue unread, so none is kept; the person's own
  memory is still the session's to write.
  """
  @spec throwaway_reason() :: String.t()
  def throwaway_reason,
    do:
      "this session is throwaway, and a throwaway session proposes nothing for a team's or " <>
        "the organisation's memory: it is erased a while after it goes quiet, and its " <>
        "proposal with it; " <> @instead <> ", or ask the person to keep the session"

  # A session that will be erased proposes nothing above its person's memory. A session
  # the plane has no row of (one on a computer that is not private) is its daemon's to say.
  defp lasting(nil), do: :ok

  defp lasting(session_id) do
    case Sessions.get(session_id) do
      %{lifespan: "throwaway"} -> {:error, :throwaway}
      _lasting_or_unknown -> :ok
    end
  end

  # Whether a pod's session on `profile` may propose: no where its profile in effect says
  # `memoryProposals: false`, its own or a profile's it extends, which a child cannot undo.
  defp profile_allows(nil), do: :ok

  defp profile_allows(name) do
    case Fleet.get_profile(name) do
      %{spec: %{"memoryProposals" => false}} -> {:error, {:off, name}}
      _on_or_gone -> :ok
    end
  end

  @doc """
  Keep one entry proposed for `scope` (`team`, with `team`, or `organisation`) by an agent
  of `user`'s: `opts` names the `:topic` (`Notes` for none), the `:session`, the `:agent` and
  `:where` the session runs (`pod` or `machine`), and for a pod's session the `:profile` it
  runs on. Refused, and nothing kept, while proposals are switched off on the plane
  (`{:error, :off}`) or for the profile's sessions (`{:error, {:off, profile}}`), for an entry
  or topic that could not be one, and for a person with #{@pending_per_person} pending already.
  """
  @spec propose(User.t(), String.t(), Team.t() | nil, term(), keyword()) ::
          {:ok, Proposal.t()}
          | {:error, :off | {:off, String.t()} | :throwaway | :no_person | String.t()}
  def propose(user, scope, team, entry, opts \\ [])

  def propose(%User{id: id} = user, scope, team, entry, opts) when is_binary(id) do
    with :ok <- if(enabled?(), do: :ok, else: {:error, :off}),
         :ok <- profile_allows(opts[:profile]),
         :ok <- lasting(opts[:session]),
         :ok <- level(scope, team),
         {:ok, entry} <- Memory.entry_text(entry),
         {:ok, topic} <- Memory.topic_text(opts[:topic]),
         :ok <- room_for(user) do
      {:ok, proposal} =
        %Proposal{}
        |> Proposal.changeset(%{
          scope: scope,
          team_id: team && team.id,
          topic: topic,
          entry: entry,
          session_id: opts[:session],
          agent: opts[:agent],
          where: opts[:where] || "pod",
          proposer_id: user.id,
          proposer_subject: user.subject
        })
        |> Repo.insert()

      proposal = %{proposal | team: team}

      {:ok, _} =
        Audit.record(user.subject, "memory.propose", Memory.subject(owner(proposal, team)), detail(proposal))

      {:ok, proposal}
    end
  end

  def propose(_user, _scope, _team, _entry, _opts), do: {:error, :no_person}

  defp level("organisation", nil), do: :ok
  defp level("team", %Team{}), do: :ok
  defp level("team", nil), do: {:error, "a proposal for a team's memory names the team"}
  defp level(scope, _team), do: {:error, "a proposal is for team or organisation, not #{inspect(scope)}"}

  defp room_for(user) do
    pending = Repo.aggregate(from(p in Proposal, where: p.proposer_id == ^user.id and p.state == "pending"), :count)

    if pending >= @pending_per_person,
      do:
        {:error,
         "#{@pending_per_person} proposals of this person's are waiting for review already; " <>
           "nothing more is proposed until an administrator has read them"},
      else: :ok
  end

  @doc """
  The pending proposals `actor` may decide, oldest first: every one for a platform admin, a
  team admin's teams' for a team admin. Each as `json/1` has it.
  """
  @spec pending(map()) :: [map()]
  def pending(actor) do
    query = from(p in Proposal, where: p.state == "pending", order_by: [asc: p.inserted_at], preload: [:team])

    query =
      case actor do
        %{role: :platform_admin} -> query
        %{role: :team_admin, teams: names} ->
          from(p in query, join: t in assoc(p, :team), where: p.scope == "team" and t.name in ^names)
        _nobody -> from(p in query, where: false)
      end

    query |> Repo.all() |> Enum.map(&json/1)
  end

  @doc """
  A person's own proposals, for their app: every pending one, and those decided in the last
  #{@shown_days} days, newest first.
  """
  @spec own(User.t()) :: [map()]
  def own(%User{id: id}) when is_binary(id) do
    since = DateTime.add(DateTime.utc_now(), -@shown_days, :day)

    from(p in Proposal,
      where: p.proposer_id == ^id and (p.state == "pending" or p.decided_at >= ^since),
      order_by: [desc: p.inserted_at],
      limit: 50,
      preload: [:team]
    )
    |> Repo.all()
    |> Enum.map(&json/1)
  end

  def own(_user), do: []

  @doc "One proposal, or `nil`."
  @spec get(term()) :: Proposal.t() | nil
  def get(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Proposal |> Repo.get(uuid) |> Repo.preload(:team)
      :error -> nil
    end
  end

  def get(_id), do: nil

  @doc "Whether `actor` may decide `proposal`: as they may change the level it is for."
  @spec decides?(map(), Proposal.t()) :: boolean()
  def decides?(%{role: :platform_admin}, %Proposal{}), do: true
  def decides?(%{role: :team_admin, teams: names}, %Proposal{scope: "team", team: %Team{name: name}}), do: name in names
  def decides?(_actor, _proposal), do: false

  @doc """
  Accept a pending proposal as `subject`: its entry written into its level's document, under
  its topic, with the session and the agent it came from (`Memory.append_entry/5`); the row
  keeps the version it came in, the audit says `memory.proposal.accept`, and the session is
  told. `{:error, :decided}` for one somebody decided first.
  """
  @spec accept(Proposal.t(), String.t()) ::
          {:ok, Proposal.t()} | {:error, :decided | {:full, non_neg_integer()} | term()}
  def accept(%Proposal{} = proposal, subject) do
    with :ok <- claim(proposal, "accepted", subject) do
      owner = owner(proposal, proposal.team)
      opts = [session: proposal.session_id, agent: proposal.agent, proposal: proposal.id]

      case Memory.append_entry(owner, proposal.entry, proposal.topic, subject, opts) do
        {:ok, %{now: now}} ->
          proposal = settle(proposal, %{version: now && now.version})
          {:ok, _} = Audit.record(subject, "memory.proposal.accept", Memory.subject(owner), detail(proposal))
          _told = tell(proposal)
          {:ok, proposal}

        {:error, _reason} = error ->
          # Back in the queue: nothing was written, so nothing was accepted.
          _ = Repo.update_all(from(p in Proposal, where: p.id == ^proposal.id), set: [state: "pending", decided_by: nil, decided_at: nil])
          error
      end
    end
  end

  @doc """
  Decline a pending proposal as `subject`, with `reason`, a sentence the session is told as
  it is. Nothing is written; the audit says `memory.proposal.decline`. `{:error, :decided}`
  for one somebody decided first; a reason is required, at most #{@reason_bytes} bytes.
  """
  @spec decline(Proposal.t(), String.t(), term()) :: {:ok, Proposal.t()} | {:error, :decided | String.t()}
  def decline(%Proposal{} = proposal, subject, reason) do
    with {:ok, reason} <- reason(reason),
         :ok <- claim(proposal, "declined", subject) do
      proposal = settle(proposal, %{reason: reason})
      owner = owner(proposal, proposal.team)
      {:ok, _} = Audit.record(subject, "memory.proposal.decline", Memory.subject(owner), detail(proposal))
      _told = tell(proposal)
      {:ok, proposal}
    end
  end

  defp reason(reason) when is_binary(reason) do
    folded = reason |> String.split() |> Enum.join(" ")

    cond do
      folded == "" -> {:error, "a proposal is declined with a sentence saying why, which the session is told"}
      byte_size(folded) > @reason_bytes -> {:error, "a reason holds at most #{@reason_bytes} bytes"}
      true -> {:ok, folded}
    end
  end

  defp reason(_other), do: {:error, "a proposal is declined with a sentence saying why, which the session is told"}

  # One decision wins: the row moves out of pending only once.
  defp claim(proposal, state, subject) do
    now = DateTime.utc_now()

    case Repo.update_all(
           from(p in Proposal, where: p.id == ^proposal.id and p.state == "pending"),
           set: [state: state, decided_by: subject, decided_at: now, updated_at: now]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :decided}
    end
  end

  defp settle(proposal, changes) do
    {1, _} = Repo.update_all(from(p in Proposal, where: p.id == ^proposal.id), set: Map.to_list(changes))
    get(proposal.id)
  end

  @doc """
  What an erased session proposed goes with it, unless it was accepted: an accepted entry is
  the document's now, as the version it came in is, and only the session's id leaves it.
  """
  @spec forget_session(String.t()) :: :ok
  def forget_session(session_id) when is_binary(session_id) do
    _ = Repo.delete_all(from(p in Proposal, where: p.session_id == ^session_id and p.state != "accepted"))
    _ = Repo.update_all(from(p in Proposal, where: p.session_id == ^session_id), set: [session_id: nil])
    :ok
  end

  # -- telling the session ----------------------------------------------------------

  @doc """
  The line a session is told when its proposal is decided: what was proposed, for which
  level, and what became of it, with the reason a decline gave.
  """
  @spec line(Proposal.t() | map()) :: String.t()
  def line(%Proposal{} = proposal), do: proposal |> json() |> Map.fetch!("message")

  def line(%{"state" => "accepted"} = p),
    do:
      "Your proposal for #{level_words(p)} under #{p["topic"]} was accepted by #{p["decided_by"]}: " <>
        "\"#{p["entry"]}\" is in it from version #{p["version"]}, read from the next turn."

  def line(%{"state" => "declined"} = p),
    do:
      "Your proposal for #{level_words(p)} under #{p["topic"]} (\"#{p["entry"]}\") was declined by " <>
        "#{p["decided_by"]}: #{p["reason"]}"

  def line(p), do: "Your proposal for #{level_words(p)} under #{p["topic"]} is awaiting review."

  defp level_words(%{"scope" => "team", "team" => team}) when is_binary(team), do: "the team #{team}'s memory"
  defp level_words(%{"scope" => "team"}), do: "a team's memory"
  defp level_words(_organisation), do: "the organisation's memory"

  # A pod's session is told now, over its pod's control link, as a `config_note` in its log;
  # a session on a person's machine is told by its daemon, which reads the decision with its
  # next poll of `me.memory`. Best effort: a session not running now is told nothing, and
  # the person's app shows the decision either way.
  defp tell(%Proposal{where: "pod", session_id: id} = proposal) when is_binary(id) do
    with %Sessions.Session{worker_id: worker_id} = session when not is_nil(worker_id) <- Sessions.get(id),
         worker when not is_nil(worker) <- Fleet.get_worker(worker_id) do
      Router.notify(worker, "memory.proposal.decided", %{
        "session_id" => session.id,
        "epoch" => session.epoch,
        "proposal" => proposal.id,
        "state" => proposal.state,
        "message" => line(proposal)
      })

      true
    else
      _not_running -> false
    end
  end

  defp tell(_machine), do: false

  # -- shapes -----------------------------------------------------------------------

  @doc "A proposal as an answer has it, with `message`, the line its session is told."
  @spec json(Proposal.t()) :: map()
  def json(%Proposal{} = p) do
    shape = fields(p)
    Map.put(shape, "message", line(shape))
  end

  defp fields(%Proposal{} = p) do
    %{
      "id" => p.id,
      "scope" => p.scope,
      "team" => team_name(p),
      "topic" => p.topic,
      "entry" => p.entry,
      "session_id" => p.session_id,
      "agent" => p.agent,
      "where" => p.where,
      "by" => p.proposer_subject,
      "state" => p.state,
      "at" => DateTime.to_iso8601(p.inserted_at),
      "decided_by" => p.decided_by,
      "decided_at" => p.decided_at && DateTime.to_iso8601(p.decided_at),
      "reason" => p.reason,
      "version" => p.version
    }
  end

  defp team_name(%Proposal{team: %Team{name: name}}), do: name
  defp team_name(_proposal), do: nil

  defp owner(%Proposal{scope: "organisation"}, _team), do: :organisation
  defp owner(%Proposal{scope: "team"}, %Team{} = team), do: team
  defp owner(%Proposal{team_id: id}, _team), do: Identity.fetch_team(id)

  # What the audit keeps: whose proposal, from where, under which topic; never the entry.
  defp detail(%Proposal{} = p) do
    %{"proposal" => p.id, "topic" => p.topic, "by" => p.proposer_subject}
    |> put_if("session", p.session_id)
    |> put_if("agent", p.agent)
    |> put_if("version", p.version)
    |> put_if("reason", p.reason)
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
