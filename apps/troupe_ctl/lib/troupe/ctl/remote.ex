defmodule Troupe.Ctl.Remote do
  @moduledoc """
  `troupe --remote`: the plane says where, and the client dials the pod.

  Three steps, and the shape of them is the point.

  1. **A plane token, from the refresh token stored at login.** The provider issues it,
     not the plane; the plane exchanges it for one of its own, short and audience-bound.
     Nothing that lives on disk is ever sent to a worker.
  2. **A session, from the plane's `/rpc`.** The same public API a third-party client
     would use — there is no privileged path here, which is the rule the whole design
     rests on.
  3. **A WebSocket to the pod.** The plane hands back an endpoint and a token minted for
     *that pod*, and the client dials it directly. The plane is not in the data path of a
     live session and is not on the path of a single keystroke.

  A token minted for one pod is refused by every other, so the endpoint and the token
  travel together and are used together.
  """

  alias Troupe.Ctl.Credentials

  @type attachment :: %{
          session_id: String.t(),
          url: String.t(),
          token: String.t(),
          plane: String.t(),
          profile: String.t() | nil
        }

  @doc """
  Find or make a session on a plane, and say how to reach it.

  `:session_id` attaches to one that exists; without it a session is created on
  `:profile`, or on the only profile granted to this person when there is just one.
  """
  @spec attach(keyword()) :: {:ok, attachment()} | {:error, String.t()}
  def attach(opts \\ []) do
    with {:ok, record} <- credentials(opts),
         {:ok, token} <- session_token(record, opts),
         {:ok, endpoint} <- endpoint(record, token, opts) do
      {:ok,
       %{
         session_id: endpoint["session_id"],
         url: url_of(endpoint),
         token: endpoint["token"],
         plane: record["plane"],
         profile: endpoint["profile"]
       }}
    end
  end

  @doc "What this person may use on a plane: their teams, and the profiles granted to them."
  @spec whoami(keyword()) :: {:ok, map()} | {:error, String.t()}
  def whoami(opts \\ []) do
    with {:ok, record} <- credentials(opts),
         {:ok, token} <- session_token(record, opts) do
      rpc(record["plane"], token, "me", %{}, opts)
    end
  end

  @doc "Sessions on a plane, newest first."
  @spec list(keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def list(opts \\ []) do
    with {:ok, record} <- credentials(opts),
         {:ok, token} <- session_token(record, opts),
         {:ok, %{"sessions" => sessions}} <- rpc(record["plane"], token, "sessions.list", %{}, opts) do
      {:ok, sessions}
    end
  end

  # -- credentials ------------------------------------------------------------

  defp credentials(opts) do
    stored =
      case Keyword.get(opts, :plane) do
        nil -> Credentials.default(opts)
        plane -> Credentials.get(plane, opts)
      end

    case stored do
      nil -> {:error, "not logged in to a plane. Run: troupe login <plane-url>"}
      %{"refresh_token" => nil} -> {:error, "no refresh token stored; log in again"}
      record -> {:ok, record}
    end
  end

  @doc """
  Mint a plane token from the stored refresh token.

  Not cached to disk. A plane token is short and audience-bound, and writing one down
  would be storing a credential with none of the properties that make the refresh token
  worth storing.
  """
  @spec session_token(map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def session_token(record, opts \\ []) do
    with {:ok, id_token} <- refresh(record, opts),
         {:ok, session} <- exchange(record["plane"], id_token, opts) do
      {:ok, session["token"]}
    end
  end

  defp refresh(record, opts) do
    form = %{
      "grant_type" => "refresh_token",
      "refresh_token" => record["refresh_token"],
      "client_id" => record["client_id"]
    }

    case request(:post, record["token_endpoint"], form: form, opts: opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        # Most providers *rotate*: the refresh token that was just spent is dead and a new
        # one comes back with the response. A client that did not store it would work once
        # and then send everybody back to `troupe login`.
        rotate(record, body, opts)

        case body["id_token"] || body["access_token"] do
          nil -> {:error, "the identity provider returned no token"}
          token -> {:ok, token}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, "the identity provider refused the refresh (#{status}): #{describe(body)}. Run: troupe login #{record["plane"]}"}

      {:error, reason} ->
        {:error, "could not reach the identity provider: #{inspect(reason)}"}
    end
  end

  defp rotate(record, %{"refresh_token" => rotated}, opts)
       when is_binary(rotated) and rotated != "" do
    if rotated != record["refresh_token"] do
      Credentials.put(record["plane"], Map.put(record, "refresh_token", rotated), opts)
    end
  end

  defp rotate(_record, _body, _opts), do: :ok

  defp exchange(plane, id_token, opts) do
    case request(:post, plane <> "/auth/exchange", json: %{"id_token" => id_token}, opts: opts) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, "the plane refused the login (#{status}): #{describe(body)}"}
      {:error, reason} -> {:error, "could not reach the plane: #{inspect(reason)}"}
    end
  end

  # -- the plane's public API -------------------------------------------------

  defp endpoint(record, token, opts) do
    plane = record["plane"]

    case Keyword.get(opts, :session_id) do
      nil -> create(plane, token, record, opts)
      session_id -> rpc(plane, token, "session.open", %{"session_id" => session_id}, opts)
    end
  end

  defp create(plane, token, record, opts) do
    with {:ok, profile} <- profile_for(plane, token, record, opts) do
      params =
        %{"profile" => profile}
        |> put_unless_nil("title", Keyword.get(opts, :title))
        |> put_unless_nil("prompt", Keyword.get(opts, :task))

      case rpc(plane, token, "session.create", params, opts) do
        {:ok, endpoint} -> {:ok, Map.put(endpoint, "profile", profile)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # A person with one profile does not have to name it; a person with several does,
  # because picking for them would be picking which team's budget to spend.
  #
  # Asked of the plane rather than read from what login stored: a grant made this morning
  # is a profile you can use this afternoon, and `troupe login` is not something anybody
  # should have to run again to find that out.
  defp profile_for(plane, token, record, opts) do
    granted =
      case rpc(plane, token, "me", %{}, opts) do
        {:ok, %{"profiles" => profiles}} when is_list(profiles) -> profiles
        _other -> record["profiles"]
      end

    case Keyword.get(opts, :profile) || granted do
      profile when is_binary(profile) -> {:ok, profile}
      [only] -> {:ok, only}
      [] -> {:error, "no profiles are granted to your teams on this plane yet"}
      nil -> {:error, "no profiles are granted to your teams on this plane yet"}
      many -> {:error, "several profiles are available (#{Enum.join(many, ", ")}); name one with --agent"}
    end
  end

  defp rpc(plane, token, method, params, opts) do
    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    case request(:post, plane <> "/rpc", json: body, auth: {:bearer, token}, opts: opts) do
      {:ok, %{status: 200, body: %{"result" => result}}} ->
        {:ok, result}

      {:ok, %{status: 200, body: %{"error" => error}}} ->
        {:error, "the plane refused #{method}: #{describe(error)}"}

      {:ok, %{status: status, body: body}} ->
        {:error, "the plane answered #{status} to #{method}: #{describe(body)}"}

      {:error, reason} ->
        {:error, "could not reach the plane: #{inspect(reason)}"}
    end
  end

  # -- where the pod is -------------------------------------------------------

  # A plane that publishes a whole URL is believed. An older one publishes a bare host,
  # and the only thing it could have meant is the standard one.
  defp url_of(%{"endpoint" => endpoint}) when is_binary(endpoint) do
    cond do
      String.starts_with?(endpoint, "ws://") or String.starts_with?(endpoint, "wss://") -> endpoint
      String.starts_with?(endpoint, "http://") -> String.replace_prefix(endpoint, "http://", "ws://") <> path_of(endpoint)
      String.starts_with?(endpoint, "https://") -> String.replace_prefix(endpoint, "https://", "wss://") <> path_of(endpoint)
      true -> "wss://" <> endpoint <> "/v1/socket"
    end
  end

  defp path_of(url), do: if(URI.parse(url).path in [nil, "/"], do: "/v1/socket", else: "")

  defp request(method, url, opts) do
    {extra, options} = Keyword.pop(opts, :opts, [])

    [method: method, url: url, decode_body: true, retry: false, receive_timeout: 30_000]
    |> Keyword.merge(options)
    |> Keyword.merge(Keyword.take(extra, [:plug, :base_url]))
    |> Req.request()
  end

  defp describe(%{"message" => message, "data" => data}) when is_map(data) and map_size(data) > 0 do
    "#{message} (#{Enum.map_join(data, ", ", fn {k, v} -> "#{k}: #{inspect(v)}" end)})"
  end

  defp describe(%{"message" => message}), do: message
  defp describe(%{"reason" => reason}), do: to_string(reason)
  defp describe(%{"error_description" => description}), do: description
  defp describe(%{"error" => error}) when is_binary(error), do: error
  defp describe(other), do: inspect(other)

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
