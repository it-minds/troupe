defmodule Troupe.Worker.Auth do
  @moduledoc """
  Who may attach to a session on this pod, decided without asking the plane.

  The plane is not in the data path of a live session, so a worker that cannot reach it
  must still be able to say yes or no. It can, because everything needed is already
  here: a cached JWKS to check the signature, this pod's own worker id to check the
  audience, and a mirror of the session ACLs the plane has pushed.

  Two checks, and they answer different questions.

  **The token** says what was true when it was minted: who the subject is, which session,
  and what role. It is checked once, at `initialize`, and again at every `auth.refresh`.
  It is good for that session alone: a request naming another is refused, so is a method
  about the pod rather than a session, and a listing of the pod shows only that one.
  Archiving, pinning and erasing the session are refused too, because they are the plane's.

  **The ACL mirror** says what is true now. A collaborator whose access was revoked
  still holds a token that verifies perfectly, so the role in it is a claim about the
  past and cannot be the standing permission. Every command is checked against the
  mirror, which the plane updates by push and which `acl_granted` and `acl_revoked`
  events in the session log also feed.
  """

  use GenServer

  alias Troupe.Gateway.{Dispatch, Session}
  alias Troupe.Protocol.{Error, Token}

  require Logger

  # The answers that are about every session on the pod rather than one.
  @listings ["session.list", "fleet.get"]

  # What a token for one session may ask of a pod: every command that names a session as
  # `session_id`, which the guard then holds to the token's, but the plane's four below;
  # that session's topics; and the listings, narrowed to it. Everything else a pod serves is
  # about the pod rather than a session — a session created in any workspace, the brief,
  # agents or workflows of a path, the workspaces and worktrees the pod has seen, the
  # machine's settings and identity. `initialize` and `auth.refresh` are the connection's
  # own and never get here.
  @session_methods ~w(
    subscribe unsubscribe session.list fleet.get
    session.get
    input.send turn.cancel profile.switch approval.respond question.answer todo.edit
    session.goal.set session.goal.get session.goal.clear
    session.loop.start session.loop.stop session.loop.get
    fs.list fs.read fs.upload blob.get mcp.status presence.set
    tools.register tools.unregister
  )

  # About the session, and still not the pod's to do. The plane holds a pod session's row,
  # its key, its placement and its retention, so doing any of these here would leave the
  # two disagreeing: the pod's own `session.erase` deletes its copy and leaves the key, the
  # objects and the row. A client asks the plane, whose erasure reaches this pod over the
  # control channel (`Troupe.Worker.Plane.Commands`), which this guard is not on.
  @plane_methods ~w(session.archive session.pin session.unpin session.erase)

  @enforce_keys [:worker_id]
  defstruct [:worker_id, :issuer, jwks: %{"keys" => []}, acl: %{}, revoked: MapSet.new()]

  # -- api --------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Replace the cached JWKS. Pushed by the plane on rotation."
  @spec put_jwks(GenServer.server(), map()) :: :ok
  def put_jwks(server \\ __MODULE__, jwks), do: GenServer.call(server, {:put_jwks, jwks})

  @doc "The keys this pod would verify a token against."
  @spec jwks(GenServer.server()) :: map()
  def jwks(server \\ __MODULE__), do: GenServer.call(server, :jwks)

  @doc "This pod's worker id, which is the audience every token for it must carry."
  @spec worker_id(GenServer.server()) :: String.t() | nil
  def worker_id(server \\ __MODULE__), do: GenServer.call(server, :worker_id)

  @doc "Tell this pod who it is, once the plane has enrolled it."
  @spec put_worker_id(GenServer.server(), String.t()) :: :ok
  def put_worker_id(server \\ __MODULE__, worker_id) do
    GenServer.call(server, {:put_worker_id, worker_id})
  end

  @doc """
  Mirror one ACL change.

  `nil` as the role revokes. Applied immediately, which is what makes a revocation take
  effect on a connection that is already open rather than at its next token.
  """
  @spec put_acl(GenServer.server(), String.t(), String.t(), String.t() | nil) :: :ok
  def put_acl(server \\ __MODULE__, session_id, subject, role) do
    GenServer.call(server, {:put_acl, session_id, subject, role})
  end

  @doc "The role a subject currently has on a session, or `nil`."
  @spec role(GenServer.server(), String.t(), String.t()) :: String.t() | nil
  def role(server \\ __MODULE__, session_id, subject) do
    GenServer.call(server, {:role, session_id, subject})
  end

  @doc "Check a token as this pod would at `initialize`."
  @spec verify(GenServer.server(), String.t()) :: {:ok, map()} | {:error, atom()}
  def verify(server \\ __MODULE__, jwt), do: GenServer.call(server, {:verify, jwt})

  @doc """
  An authenticator for `Troupe.Protocol.Endpoint.remote/3`.

  Closes over the server rather than the worker id, so a pod that enrols after its
  listener is up does not have to restart it.
  """
  @spec authenticator(GenServer.server()) :: (map() -> {:ok, map(), [atom()], map()} | {:error, Error.t()})
  def authenticator(server \\ __MODULE__) do
    fn params ->
      case verify(server, get_in(params, ["auth", "token"]) || "") do
        {:ok, claims} -> {:ok, principal(claims), scopes(claims), %{claims: claims, expires_at: claims["exp"]}}
        {:error, reason} -> {:error, Error.new(:unauthenticated, %{reason: to_string(reason)})}
      end
    end
  end

  @doc "A guard for `Troupe.Protocol.Endpoint.remote/3`: the ACL as it stands now."
  @spec guard(GenServer.server()) :: (map() | nil, String.t(), map() -> :ok | {:error, Error.t()})
  def guard(server \\ __MODULE__) do
    fn claims, method, params -> check(server, claims, method, params) end
  end

  @doc """
  What a caller may see of an answer, for `Troupe.Protocol.Endpoint.remote/3`.

  The guard refuses a request that names another session. A listing names none — it is
  about the whole pod — so it is answered and then narrowed: a token for one session
  finds that session in it, and nobody else's.
  """
  @spec narrow(map() | nil, String.t(), map()) :: map()
  def narrow(%{"session_id" => session_id}, method, %{"sessions" => sessions} = result)
      when method in @listings and is_binary(session_id) and is_list(sessions) do
    %{result | "sessions" => Enum.filter(sessions, &(&1["id"] == session_id))}
  end

  def narrow(_claims, _method, result), do: result

  @doc "What a set of claims says the caller may do, before the ACL has its say."
  @spec scopes(map()) :: [atom()]
  def scopes(claims) do
    case claims["scopes"] do
      list when is_list(list) and list != [] -> Enum.flat_map(list, &to_scope/1)
      _ -> Token.scopes_for(claims["role"] || "viewer")
    end
  end

  defp to_scope("observe"), do: [:observe]
  defp to_scope("control"), do: [:control]
  defp to_scope("admin"), do: [:admin]
  defp to_scope(_other), do: []

  @doc "The principal a set of claims describes, in the shape `initialize` answers with."
  @spec principal(map()) :: map()
  def principal(claims) do
    %{
      "subject" => claims["sub"],
      "display_name" => claims["name"] || claims["sub"],
      "kind" => "user",
      "team" => claims["team"],
      "role" => claims["role"]
    }
  end

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe worker auth")

    {:ok,
     %__MODULE__{
       worker_id: Keyword.get_lazy(opts, :worker_id, &configured_worker_id/0),
       issuer: Keyword.get_lazy(opts, :issuer, &configured_issuer/0),
       jwks: Keyword.get_lazy(opts, :jwks, &cached_jwks/0)
     }}
  end

  defp configured_worker_id, do: Application.get_env(:troupe_worker, :worker_id)
  defp configured_issuer, do: Application.get_env(:troupe_worker, :token_issuer)

  # The plane pushes the JWKS over the control channel, so a pod that has been up for a
  # while always has one. A pod that has just restarted has not, and the claim this
  # module makes — that a worker can say yes or no without asking the plane — is exactly
  # the claim that is false in that window. A cached copy on disk closes it.
  #
  # A path that is configured and unreadable is not fatal: the plane's push still works,
  # and refusing to start would turn a stale mount into an outage.
  defp cached_jwks do
    with path when is_binary(path) <- Application.get_env(:troupe_worker, :jwks_path),
         {:ok, contents} <- File.read(path),
         {:ok, %{"keys" => keys} = jwks} when is_list(keys) <- Jason.decode(contents) do
      jwks
    else
      nil ->
        %{"keys" => []}

      other ->
        Logger.warning("troupe worker: no cached JWKS (#{inspect(other)}); waiting for the plane")
        %{"keys" => []}
    end
  end

  @impl GenServer
  def handle_call({:put_jwks, jwks}, _from, state), do: {:reply, :ok, %{state | jwks: jwks}}
  def handle_call(:jwks, _from, state), do: {:reply, state.jwks, state}
  def handle_call(:worker_id, _from, state), do: {:reply, state.worker_id, state}

  def handle_call({:put_worker_id, worker_id}, _from, state) do
    {:reply, :ok, %{state | worker_id: worker_id}}
  end

  def handle_call({:put_acl, session_id, subject, role}, _from, state) do
    # A revocation is recorded, not erased: "no entry" means the plane has never said
    # anything about this subject and the token stands alone, which is the opposite of
    # what a revocation means.
    entry = role || :revoked
    acl = Map.update(state.acl, session_id, %{subject => entry}, &Map.put(&1, subject, entry))
    {:reply, :ok, %{state | acl: acl}}
  end

  def handle_call({:role, session_id, subject}, _from, state) do
    {:reply, get_in(state.acl, [session_id, subject]), state}
  end

  def handle_call({:verify, jwt}, _from, state) do
    options =
      [audience: state.worker_id] ++ if(state.issuer, do: [issuer: state.issuer], else: [])

    {:reply, Token.verify(jwt, state.jwks, options), state}
  end

  def handle_call({:check, claims, method, params}, _from, state) do
    {:reply, do_check(state, claims, method, params), state}
  end

  defp check(server, claims, method, params) do
    GenServer.call(server, {:check, claims, method, params})
  end

  # No claims: nothing here vouched for the caller with a token, and there is nobody to
  # hold to an ACL.
  defp do_check(_state, nil, _method, _params), do: :ok

  # A token that names a session is good for that session and no other. A pod holds
  # several people's sessions, and the role in a token is a role on one of them — so
  # every session a request names must be the token's, the method must be one about a
  # session and not the plane's, and the ACL is then asked about that one. A token with no
  # session in it — which the plane never mints for a pod, and tooling that runs its own
  # pod signs — keeps every method and is held to the ACL of each session the request
  # names.
  defp do_check(state, claims, method, params) do
    named = named_sessions(params)

    case claims["session_id"] do
      nil -> Enum.find_value(named, :ok, &acl_refusal(state, claims["sub"], &1))
      session_id -> confined(state, claims["sub"], session_id, method, named)
    end
  end

  defp confined(state, subject, session_id, method, named) do
    case Enum.find(named, fn {_field, id} -> id != session_id end) do
      nil ->
        method_refusal(method) || acl_refusal(state, subject, {"session_id", session_id}) || :ok

      {field, _other} ->
        another_session(field)
    end
  end

  defp method_refusal(method) when method in @plane_methods, do: through_the_plane(method)

  # A method this server does not have is left to the dispatcher, which answers
  # `method_not_found` to everybody and runs nothing.
  defp method_refusal(method) do
    if method not in @session_methods and Map.has_key?(Dispatch.methods(), method),
      do: not_about_the_session(method)
  end

  defp acl_refusal(state, subject, {_field, session_id}) do
    case get_in(state.acl, [session_id, subject]) do
      # No mirrored entry: the token is the only word on the subject, and it verified.
      nil -> nil
      role when is_binary(role) -> nil
      _revoked -> revoked(session_id)
    end
  end

  # Every place a request names a session: its `session_id`, a branch's `parent`, and the
  # id in a `session:` or `presence:` topic. The `fleet` topic is every session on the pod
  # at once, which is never one token's session, so only a token that names none may
  # have it. A value that is not a string is no token's session either, and is kept so
  # that it is refused rather than passed over.
  defp named_sessions(params) do
    named =
      params
      |> Map.take(["session_id", "parent"])
      |> Enum.reject(fn {_field, id} -> id in [nil, ""] end)

    case topic_session(params["topic"]) do
      nil -> named
      id -> [{"topic", id} | named]
    end
  end

  defp topic_session(topic) when is_binary(topic) do
    case Session.parse_topic(topic) do
      {:ok, :fleet, nil} -> :fleet
      {:ok, _kind, id} -> id
      :error -> nil
    end
  end

  defp topic_session(_topic), do: nil

  defp revoked(session_id) do
    {:error, Error.new(:forbidden, %{reason: "access revoked", session_id: session_id})}
  end

  defp another_session(field) do
    {:error, Error.new(:forbidden, %{reason: "the token is for another session", field: field})}
  end

  defp not_about_the_session(method) do
    {:error, Error.new(:forbidden, %{reason: "not about the token's session", method: method})}
  end

  defp through_the_plane(method) do
    {:error, Error.new(:forbidden, %{reason: "done through the plane", method: method})}
  end
end
