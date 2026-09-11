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

  **The ACL mirror** says what is true now. A collaborator whose access was revoked
  still holds a token that verifies perfectly, so the role in it is a claim about the
  past and cannot be the standing permission. Every command is checked against the
  mirror, which the plane updates by push and which `acl_granted` and `acl_revoked`
  events in the session log also feed.
  """

  use GenServer

  alias Troupe.Protocol.{Error, Token}

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
       worker_id: Keyword.get(opts, :worker_id),
       issuer: Keyword.get(opts, :issuer),
       jwks: Keyword.get(opts, :jwks, %{"keys" => []})
     }}
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

  # A token with no session in it — a create grant, or an admin listing — is not about
  # one session's ACL and there is nothing here to check.
  defp do_check(_state, nil, _method, _params), do: :ok

  defp do_check(state, claims, _method, params) do
    session_id = claims["session_id"] || params["session_id"]

    case session_id && get_in(state.acl, [session_id, claims["sub"]]) do
      # No mirrored entry: the token is the only word on the subject, and it verified.
      nil -> :ok
      :revoked -> revoked(session_id)
      role when is_binary(role) -> :ok
      _ -> revoked(session_id)
    end
  end

  defp revoked(session_id) do
    {:error, Error.new(:forbidden, %{reason: "access revoked", session_id: session_id})}
  end
end
