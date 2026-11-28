defmodule Troupe.Plane.Sessions.Sensitive do
  @moduledoc """
  The plane's part of a sensitive session (#1239): the row's mark, its audit, what an
  activation carries, and what the plane refuses on its own side.

  **The mark.** A pod marks a session at its gate and says so in `session.status`
  (`sensitive_at`, `sensitive_by`, `sensitive_rule`); its owner may mark one by hand
  (`mark/2`). Either way the row's `sensitive_at` and `sensitive_by` are written once, by
  whichever comes first, audited `session.sensitive` (as `system:harness` with the tool and
  the rule, or as the person), and never cleared: nothing here, nor anywhere, unmarks a
  session. A mark by hand is pushed to the pod holding the session (`sensitive.changed`);
  a dormant one is given it with its next activation (`activation/1`), so its gate holds
  before its log is read.

  **Sharing.** The session's profile's `sensitive.sharing` says what its people may do
  with it beyond who reads it now: give it to the team, invite or grant a person, mint a
  link, move or share an artifact it published. `allow` lets them; `deny` refuses with the
  sentence `Troupe.Protocol.Sensitive.sharing_refused/2`, naming the team that reads it
  now; `ask` holds the share as a `ShareRequest` for a team administrator, answering the
  owner that it waits (`check/4`), and `decide/3` is the administrator's answer. A link
  cannot wait for anybody, since it is a secret handed back at once, so under `ask` it is
  refused, saying to invite the person by name instead. The present readers keep reading.
  """

  import Ecto.Query

  alias Troupe.Plane.{Audit, Fleet, Identity, Repo}
  alias Troupe.Plane.Control.Router
  alias Troupe.Plane.Identity.User
  alias Troupe.Plane.Sessions.{Session, ShareRequest}
  alias Troupe.Protocol.Error
  alias Troupe.Protocol.Sensitive, as: Words

  @harness "system:harness"

  @doc "Whether the session is sensitive."
  @spec sensitive?(Session.t() | nil) :: boolean()
  def sensitive?(%Session{sensitive_at: %DateTime{}}), do: true
  def sensitive?(_session), do: false

  @doc """
  The mark as a row and an activation carry it, `{at, by, how}`: `how` is `call` (`by`
  the tool whose call marked it) or `person` (`by` their subject); `nil` while it is not.
  """
  @spec json(Session.t() | nil) :: map() | nil
  def json(%Session{sensitive_at: %DateTime{} = at, sensitive_by: by}) do
    {how, who} = split(by)
    %{"at" => DateTime.to_iso8601(at), "by" => who, "how" => how}
  end

  def json(_session), do: nil

  defp split("person:" <> subject), do: {"person", subject}
  defp split(tool) when is_binary(tool), do: {"call", tool}
  defp split(_none), do: {"call", "unknown"}

  @doc """
  What a pod said in `session.status`: the row is marked where it was not, and audited.
  A report about a session already marked, or one with no mark, changes nothing.
  """
  @spec reported(String.t() | nil, map()) :: :ok
  def reported(session_id, %{"sensitive_at" => at, "sensitive_by" => by} = params)
      when is_binary(session_id) and is_binary(at) and is_binary(by) do
    with {:ok, at, _offset} <- DateTime.from_iso8601(at),
         true <- write(session_id, at, by) do
      audit_reported(session_id, at, by, params["sensitive_rule"])
    end

    :ok
  end

  def reported(_session_id, _params), do: :ok

  defp audit_reported(session_id, at, by, rule) do
    {how, who} = split(by)
    actor = if how == "person", do: who, else: @harness

    detail =
      %{"how" => how, "by" => who, "at" => DateTime.to_iso8601(at)}
      |> put_present("tool", if(how == "call", do: who))
      |> put_present("rule", rule)

    {:ok, _audit} = Audit.record(actor, "session.sensitive", session_id, detail)
  end

  # Written only where the row has none: the first mark holds, from whichever side.
  defp write(session_id, at, by) do
    {count, _} =
      from(s in Session, where: s.id == ^session_id and is_nil(s.sensitive_at))
      |> Repo.update_all(
        set: [sensitive_at: at, sensitive_by: by, updated_at: DateTime.utc_now()]
      )

    count == 1
  end

  @doc """
  A person's mark by hand, one-way: the row marked and audited as theirs, and the pod
  holding the session told. A session already sensitive is answered as it is.
  """
  @spec mark(Session.t(), User.t()) :: {:ok, Session.t()}
  def mark(%Session{} = session, %User{} = user) do
    if sensitive?(session) do
      {:ok, session}
    else
      at = DateTime.utc_now()

      if write(session.id, at, "person:" <> user.subject) do
        {:ok, _audit} =
          Audit.record(user.subject, "session.sensitive", session.id, %{
            "how" => "person",
            "by" => user.subject,
            "at" => DateTime.to_iso8601(at)
          })
      end

      updated = Repo.get!(Session, session.id)
      tell_pod(updated, user)
      {:ok, updated}
    end
  end

  @doc """
  A new session spawned or forked from a sensitive `parent`, marked as the parent is (its
  `at` and `by`), audited as the harness with the parent named. It has no pod yet, and its
  first activation carries the mark.
  """
  @spec inherit(Session.t(), Session.t()) :: {:ok, Session.t()}
  def inherit(
        %Session{} = session,
        %Session{sensitive_at: %DateTime{} = at, sensitive_by: by} = parent
      ) do
    if write(session.id, at, by) do
      {how, who} = split(by)

      {:ok, _audit} =
        Audit.record(@harness, "session.sensitive", session.id, %{
          "how" => how,
          "by" => who,
          "at" => DateTime.to_iso8601(at),
          "from" => parent.id
        })
    end

    {:ok, Repo.get!(Session, session.id)}
  end

  # Best effort, as a lifespan's push is: a dormant session has no pod, and its next
  # activation carries the mark.
  defp tell_pod(%Session{worker_id: nil}, _user), do: :ok

  defp tell_pod(session, user) do
    case Fleet.get_worker(session.worker_id) do
      nil ->
        :ok

      worker ->
        %{"by" => by, "at" => at} = json(session)

        Router.push(worker, "sensitive.changed", %{
          "session_id" => session.id,
          "by" => by,
          "by_name" => Map.get(user, :display_name),
          "at" => at
        })

        :ok
    end
  end

  # -- what the plane refuses -------------------------------------------------------

  @doc "What the session's profile says of sharing it once it is sensitive."
  @spec sharing(Session.t()) :: String.t()
  def sharing(%Session{} = session), do: Words.sharing(profile_sensitive(session))

  @doc """
  Whether a sensitive session's profile refuses `tool` there: its `sensitive.deny` names
  the tool whole. `false` for a session that is not sensitive.
  """
  @spec denies?(Session.t() | nil, String.t()) :: boolean()
  def denies?(%Session{} = session, tool) do
    sensitive?(session) and tool in List.wrap(profile_sensitive(session)["deny"])
  end

  def denies?(_session, _tool), do: false

  defp profile_sensitive(%Session{profile: name}) when is_binary(name) do
    case Fleet.get_profile(name) do
      %{spec: %{"sensitive" => %{} = sensitive}} -> sensitive
      _none -> %{}
    end
  end

  defp profile_sensitive(_session), do: %{}

  @doc """
  An artifact's publication from `session_id`, refused where the session is sensitive and
  its profile's `sensitive.deny` names `publish_artifact`.
  """
  @spec publishable(String.t() | nil) :: :ok | {:error, Error.t()}
  def publishable(session_id) when is_binary(session_id) do
    session = Repo.get(Session, session_id)

    if denies?(session, "publish_artifact"),
      do:
        {:error,
         Error.new(:forbidden, %{
           reason: Words.no_publication(session.profile),
           setting: "sensitive"
         })},
      else: :ok
  end

  def publishable(_session_id), do: :ok

  @doc """
  Whether `user` may share `session` beyond who reads it now, by `kind` (`visibility`,
  `invite`, `grant`, `link`, `artifact`) with `params`: `:ok` where it is not sensitive or
  its profile allows; an error with the sentence where it denies, or where it asks and a
  link was asked for; and where it asks, `{:ok, answer}`, the share held for a team
  administrator and the answer saying it waits.
  """
  @spec check(Session.t() | nil, String.t(), map(), User.t()) ::
          :ok | {:ok, map()} | {:error, Error.t()}
  def check(%Session{} = session, kind, params, %User{} = user) do
    cond do
      not sensitive?(session) -> :ok
      sharing(session) == "allow" -> :ok
      sharing(session) == "deny" -> {:error, refused(session)}
      kind == "link" -> {:error, link_refused(session)}
      # A team administrator's own share is the yes it would have waited for.
      administers?(user, session) -> :ok
      true -> hold(session, kind, params, user)
    end
  end

  def check(_session, _kind, _params, _user), do: :ok

  @doc """
  `check/4` for an artifact: the session it came from (its `origin.session_id`) decides,
  and an artifact from no session, or from one that is not sensitive, is anybody's to share.
  """
  @spec check_artifact(map(), String.t(), map(), User.t()) ::
          :ok | {:ok, map()} | {:error, Error.t()}
  def check_artifact(%{origin: %{"session_id" => session_id}} = artifact, kind, params, user)
      when is_binary(session_id) do
    {files?, params} = Map.pop(params, "with_files", false)
    params = params |> Map.put("artifact", artifact.id) |> Map.reject(fn {_k, v} -> is_nil(v) end)

    case Repo.get(Session, session_id) do
      nil ->
        :ok

      session ->
        # A move that would wait is the move alone: a new version sent with it is refused
        # with it, so nothing is half applied when the yes comes.
        if files? and sensitive?(session) and sharing(session) == "ask" and
             not administers?(user, session),
           do: {:error, files_refused(session)},
           else: check(session, kind, params, user)
    end
  end

  def check_artifact(_artifact, _kind, _params, _user), do: :ok

  defp refused(session) do
    Error.new(:forbidden, %{
      reason: Words.sharing_refused(session.profile, readers(session)),
      setting: "sensitive.sharing"
    })
  end

  defp link_refused(session) do
    Error.new(:forbidden, %{
      reason:
        "This session is sensitive and #{session.profile} asks a team administrator before it is " <>
          "shared wider; a link cannot wait for one, so none was made. Invite the person by name " <>
          "instead, which waits for the administrator's yes",
      setting: "sensitive.sharing"
    })
  end

  defp administers?(_user, %Session{team_id: nil}), do: false

  defp administers?(user, %Session{team_id: id}),
    do: user |> Identity.teams_administered_by() |> Enum.any?(&(&1.id == id))

  defp files_refused(session) do
    Error.new(:forbidden, %{
      reason:
        "This session is sensitive and #{session.profile} asks a team administrator before what " <>
          "it published is shared wider: publish the new version first, then move it on its own, " <>
          "which waits for the administrator's yes",
      setting: "sensitive.sharing"
    })
  end

  # The team that reads the session now: its own team where it is the team's.
  defp readers(%Session{visibility: "team"} = session), do: List.wrap(team_name(session))
  defp readers(_session), do: []

  defp team_name(%Session{team_id: nil}), do: nil

  defp team_name(%Session{team_id: id}) do
    case Identity.fetch_team(id) do
      nil -> nil
      team -> team.name
    end
  end

  defp hold(session, kind, params, user) do
    request =
      %ShareRequest{
        id: "share-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
        session_id: session.id,
        team: team_name(session),
        kind: kind,
        params: params,
        requested_by: user.subject
      }
      |> Repo.insert!()

    {:ok, _audit} =
      Audit.record(user.subject, "session.share_request", session.id, %{
        "request" => request.id,
        "kind" => kind,
        "params" => params
      })

    {:ok,
     %{
       "waiting" => true,
       "reason" => Words.waiting(),
       "share_request" => ShareRequest.json(request)
     }}
  end

  # -- a team administrator's answer ------------------------------------------------

  @doc "The requests waiting on `user`: those of every team they administer, oldest first."
  @spec pending(User.t()) :: [ShareRequest.t()]
  def pending(%User{} = user) do
    teams = user |> Identity.teams_administered_by() |> Enum.map(& &1.name)

    Repo.all(
      from(r in ShareRequest,
        where: r.state == "pending" and r.team in ^teams,
        order_by: [asc: r.inserted_at]
      )
    )
  end

  @doc """
  A team administrator's answer to request `id`: `approve` or `decline`. Marked answered
  and audited as theirs; the caller applies an approved one as its owner asked it.
  `not_found` for a request that is not theirs to answer, `conflict` for one answered.
  """
  @spec decide(String.t(), User.t(), String.t()) :: {:ok, ShareRequest.t()} | {:error, Error.t()}
  def decide(id, %User{} = user, decision) when decision in ["approve", "decline"] do
    teams = user |> Identity.teams_administered_by() |> Enum.map(& &1.name)
    state = if decision == "approve", do: "approved", else: "declined"

    case Repo.get(ShareRequest, id || "") do
      %ShareRequest{team: team} = request when is_binary(team) ->
        cond do
          team not in teams ->
            {:error, Error.new(:not_found, %{share_request: id})}

          request.state != "pending" ->
            {:error,
             Error.new(:conflict, %{
               reason: "this request was answered already",
               state: request.state
             })}

          true ->
            answer(request, user, state)
        end

      _none ->
        {:error, Error.new(:not_found, %{share_request: id})}
    end
  end

  def decide(_id, _user, _decision),
    do: {:error, Error.new(:invalid_params, %{reason: "decision is approve or decline"})}

  defp answer(request, user, state) do
    decided =
      request
      |> Ecto.Changeset.change(
        state: state,
        decided_by: user.subject,
        decided_at: DateTime.utc_now()
      )
      |> Repo.update!()

    {:ok, _audit} =
      Audit.record(user.subject, "session.share_request.decide", request.session_id, %{
        "request" => request.id,
        "kind" => request.kind,
        "decision" => state,
        "requested_by" => request.requested_by
      })

    {:ok, decided}
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
