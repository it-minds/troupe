defmodule Troupe.Worker.ClientCredentials do
  @moduledoc """
  The profile's own tokens at the MCP servers it calls with client credentials (Decision
  747).

  The bundle marks a server `client_credentials`; the profile says who it is there (its
  `mcpIdentities`, which the operator hands the pod as a file). For a token, this signs a
  private key JWT (RFC 7523) whose signing input goes to OpenBao transit and whose
  signature comes back, so the key never leaves OpenBao and is never in this pod's memory,
  then asks the token endpoint with `grant_type=client_credentials`.

  ## One token per server, renewed before it runs out

  A pod runs one profile, so one token per server is one per profile and server. It is
  kept here, in this process and nowhere else, and handed out until a little before it
  expires (a minute, or a quarter of its life when that is shorter), when the next call
  gets a new one. A server that answers `401` gets one more, once (`Troupe.MCP.authorized/2`).

  The identities are read again whenever a token is asked for, from the file the operator
  mounts from a ConfigMap, which the kubelet replaces in place. So a rotation (a new key
  version in transit and the new certificate's thumbprint on the profile) or a new client
  reaches a running pod without a restart, and a token that was got as an identity the
  profile no longer describes is not handed out again.

  One process, so two sessions asking at once ask the token endpoint once. It waits on the
  token endpoint and on OpenBao while it asks, which is once an hour per server.

  ## What is never anywhere

  The token goes to the server that asked for it and nowhere else: not a log line, not an
  error, not the event log. Errors name the server and the cause, which is all an
  administrator needs and all a model needs to relay.
  """

  use GenServer

  alias Troupe.KMS.OpenBao
  alias Troupe.MCP.{OAuth, Server}
  alias Troupe.WorkerProfile.MCPIdentity

  require Logger

  @assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
  # The assertion is used once, now, so it need not live long.
  @assertion_seconds 300
  @renew_margin_ms 60_000
  # A token endpoint that says nothing of a token's life is taken at five minutes.
  @default_expires_in 300
  @http_timeout 15_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Install this pod as the answer to "what is the profile's token at this server", which is
  how `Troupe.MCP` reaches a token it must not know how to get.
  """
  @spec install(GenServer.server()) :: :ok
  def install(server \\ __MODULE__) do
    Application.put_env(:troupe_core, :profile_tokens, &token(server, &1, &2))
  end

  @doc """
  The profile's token at `server`. `rejected` is a token the server just answered `401`
  to: one other than it comes back, new unless somebody else already got one.
  """
  @spec token(GenServer.server(), Server.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def token(process \\ __MODULE__, %Server{} = server, rejected) do
    GenServer.call(process, {:token, server, rejected}, 60_000)
  catch
    # Said in a word, not inspected: the exit carries the call's message, and the message
    # carries the token the server refused.
    :exit, reason ->
      {:error, "mcp server #{server.name}: no token for the profile's identity (#{word(reason)})"}
  end

  defp word({:timeout, _call}), do: "timed out"
  defp word({:noproc, _call}), do: "not running"
  defp word(_reason), do: "stopped"

  @doc "The servers a token is held for, never the tokens. For tests."
  @spec held(GenServer.server()) :: [String.t()]
  def held(process \\ __MODULE__), do: GenServer.call(process, :held)

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe client credentials")
    if Keyword.get(opts, :install, true), do: install(Keyword.get(opts, :name, __MODULE__))

    {:ok,
     %{
       identities: Keyword.get(opts, :identities, &configured/0),
       kms: Keyword.get(opts, :kms, []),
       tokens: %{}
     }}
  end

  @impl GenServer
  def handle_call({:token, server, rejected}, _from, state) do
    with {:ok, identity} <- identity(state, server.name),
         :none <- held_token(state, server.name, identity, rejected),
         {:ok, entry} <- request(server, identity, state) do
      {:reply, {:ok, entry.token}, put_in(state.tokens[server.name], entry)}
    else
      {:held, token} ->
        {:reply, {:ok, token}, state}

      {:error, sentence} ->
        Logger.warning("troupe worker: #{sentence}")
        {:reply, {:error, sentence}, %{state | tokens: Map.delete(state.tokens, server.name)}}
    end
  end

  def handle_call(:held, _from, state),
    do: {:reply, state.tokens |> Map.keys() |> Enum.sort(), state}

  # A crash report prints the state and the last message, and both can hold a token.
  @impl GenServer
  def format_status(status) do
    status
    |> Map.replace_lazy(:state, &redacted/1)
    |> Map.replace_lazy(:message, fn _message -> :redacted end)
  end

  defp redacted(%{tokens: tokens} = state), do: %{state | tokens: Map.keys(tokens)}
  defp redacted(state), do: state

  # A token is handed out while it was got as the identity the profile still describes,
  # is not the one the server just refused, and has not reached the point it is renewed
  # at. A token somebody else renewed after this caller's was refused is the fresh one.
  defp held_token(state, name, identity, rejected) do
    now = System.monotonic_time(:millisecond)

    case Map.get(state.tokens, name) do
      %{identity: ^identity, token: token, renew_at: renew_at}
      when token != rejected and now < renew_at ->
        {:held, token}

      _stale ->
        :none
    end
  end

  # -- the identity -----------------------------------------------------------

  defp identity(state, name) do
    identities =
      if is_function(state.identities, 0), do: state.identities.(), else: state.identities

    case Enum.find(identities, &(&1.server == name)) do
      nil ->
        {:error,
         "mcp server #{name}: is called with client credentials, and the profile gives it no " <>
           "identity in mcpIdentities"}

      identity ->
        case MCPIdentity.problems(identity) do
          [] -> {:ok, identity}
          problems -> {:error, Enum.join(problems, "; ")}
        end
    end
  end

  # The file the operator mounts, read each time: the kubelet replaces it in place when the
  # profile changes, and a file read once at start would need a restart to see that.
  defp configured do
    case Application.get_env(:troupe_worker, :mcp_identities_path) do
      nil -> []
      path -> read(path)
    end
  end

  @doc """
  The identities in a file as the operator writes it: the profile's `mcpIdentities`, as
  JSON, in the resource's own spelling. Missing or unreadable is none.
  """
  @spec read(Path.t()) :: [MCPIdentity.t()]
  def read(path) do
    with {:ok, text} <- File.read(path),
         {:ok, entries} when is_list(entries) <- Jason.decode(text) do
      Enum.map(entries, &MCPIdentity.from_spec/1)
    else
      _unreadable -> []
    end
  end

  # -- the token request ------------------------------------------------------

  defp request(server, identity, state) do
    with {:ok, endpoint} <- token_endpoint(server, identity),
         {:ok, assertion} <- assertion(server, identity, endpoint, state),
         {:ok, token, expires_in} <- ask(server, identity, endpoint, assertion) do
      lifetime = expires_in * 1000

      {:ok,
       %{
         identity: identity,
         token: token,
         renew_at:
           System.monotonic_time(:millisecond) +
             max(lifetime - @renew_margin_ms, div(lifetime * 3, 4))
       }}
    end
  end

  # The profile's `tokenUrl`, or what the authorization server's metadata says, found as a
  # person's sign-in finds it: the server's protected-resource metadata names the
  # authorization server.
  defp token_endpoint(server, %MCPIdentity{token_url: nil} = identity) do
    config = %{
      client_id: identity.client_id,
      scopes: nil,
      redirect_uri: nil,
      resource: false,
      issuer: nil
    }

    case OAuth.discover(server.url, config) do
      {:ok, %{token_endpoint: endpoint}} ->
        {:ok, endpoint}

      {:error, reason} ->
        {:error,
         "mcp server #{server.name}: no token endpoint (#{reason}); name it with tokenUrl"}
    end
  end

  defp token_endpoint(_server, %MCPIdentity{token_url: url}), do: {:ok, url}

  # RFC 7523: the client vouches for itself. `iss` and `sub` are the client, `aud` the
  # token endpoint it is for, `jti` makes a replay recognisable, and the header names the
  # certificate the identity provider checks the signature against.
  defp assertion(server, identity, endpoint, state) do
    now = System.system_time(:second)

    header = %{"alg" => identity.algorithm, "typ" => "JWT", "x5t#S256" => identity.thumbprint}

    claims = %{
      "iss" => identity.client_id,
      "sub" => identity.client_id,
      "aud" => endpoint,
      "iat" => now,
      "nbf" => now,
      "exp" => now + @assertion_seconds,
      "jti" => 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    }

    input = segment(header) <> "." <> segment(claims)
    padding = if identity.algorithm == "PS256", do: :pss, else: :pkcs1v15

    case OpenBao.sign(
           identity.transit_key,
           input,
           [padding: padding, key_version: identity.key_version],
           state.kms
         ) do
      {:ok, %{signature: signature}} ->
        {:ok, input <> "." <> Base.url_encode64(signature, padding: false)}

      {:error, reason} ->
        {:error, "mcp server #{server.name}: #{signing_failure(identity, reason)}"}
    end
  end

  defp segment(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp signing_failure(identity, :key_not_found) do
    "the transit key #{identity.transit_key}#{version_of(identity)} is not in OpenBao"
  end

  defp signing_failure(identity, :forbidden) do
    "this pod may not sign with the transit key #{identity.transit_key}; its name must begin " <>
      "with the pod's namespace and a dot, under the policy Troupe.KMS.Policy.mcp_identity/2 renders"
  end

  defp signing_failure(identity, {:refused, errors}) do
    "OpenBao refused to sign with #{identity.transit_key}: #{Enum.join(errors, "; ")}"
  end

  defp signing_failure(identity, reason) do
    "OpenBao could not sign with #{identity.transit_key}: #{inspect(reason)}"
  end

  defp version_of(%MCPIdentity{key_version: nil}), do: ""
  defp version_of(%MCPIdentity{key_version: version}), do: " (version #{version})"

  defp ask(server, identity, endpoint, assertion) do
    form =
      [
        {"grant_type", "client_credentials"},
        {"client_id", identity.client_id},
        {"client_assertion_type", @assertion_type},
        {"client_assertion", assertion}
      ] ++ if(identity.scope, do: [{"scope", identity.scope}], else: [])

    if MCPIdentity.secure?(endpoint) do
      Req.request(
        method: :post,
        url: endpoint,
        form: form,
        headers: [{"accept", "application/json"}],
        retry: false,
        receive_timeout: @http_timeout,
        decode_body: true
      )
      |> answer(server, identity, endpoint)
    else
      {:error, "mcp server #{server.name}: the token endpoint #{endpoint} is not https"}
    end
  end

  defp answer(
         {:ok, %{status: 200, body: %{"access_token" => token} = body}},
         _server,
         _identity,
         _endpoint
       )
       when is_binary(token) and token != "" do
    {:ok, token, expires_in(body["expires_in"])}
  end

  defp answer({:ok, %{status: status, body: body}}, server, identity, endpoint) do
    {:error,
     "mcp server #{server.name}: the token endpoint #{host(endpoint)} refused client " <>
       "#{identity.client_id} (#{status}#{refusal(body)})"}
  end

  defp answer({:error, reason}, server, _identity, endpoint) do
    {:error,
     "mcp server #{server.name}: the token endpoint #{host(endpoint)} could not be reached: " <>
       "#{inspect(reason)}"}
  end

  # What the identity provider says, which is about the client or the assertion and never
  # carries a credential; bounded, since a description can be a page.
  defp refusal(%{"error" => error} = body) when is_binary(error) do
    case body["error_description"] do
      description when is_binary(description) ->
        ": #{error}: #{String.slice(description, 0, 240)}"

      _none ->
        ": #{error}"
    end
  end

  defp refusal(_body), do: ""

  defp expires_in(seconds) when is_integer(seconds) and seconds > 0, do: seconds

  defp expires_in(seconds) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {n, ""} when n > 0 -> n
      _ -> @default_expires_in
    end
  end

  defp expires_in(_seconds), do: @default_expires_in

  defp host(url), do: URI.parse(url).host || url
end
