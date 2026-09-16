defmodule Troupe.Remote.Auth do
  @moduledoc """
  OAuth 2.0 device authorization grant (RFC 8628) against the plane's issuer.

  The endpoints come from the issuer's OIDC discovery document, as the contract
  says; a plane that advertises them itself is used as the fallback, because the
  deployment this was developed against publishes them in
  `/.well-known/troupe` and an issuer behind a split-horizon DNS may not be
  reachable under the name its discovery document uses (Decision 70).

  `start/1` asks for a code and returns immediately, so the caller can put the
  verification URL on screen before polling; `poll/2` blocks until the user
  finishes, the code expires, or the deadline passes.
  """

  alias Troupe.Remote.{Discovery, HTTP}

  require Logger

  @grant "urn:ietf:params:oauth:grant-type:device_code"

  @type request :: %{
          device_code: String.t(),
          user_code: String.t(),
          verification_uri: String.t(),
          verification_uri_complete: String.t() | nil,
          interval: pos_integer(),
          expires_at: integer(),
          token_endpoint: String.t()
        }

  @type tokens :: %{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          expires_at: integer() | nil,
          id_token: String.t() | nil,
          scope: String.t() | nil
        }

  @doc "The issuer's endpoints: OIDC discovery, with the plane's own document as the fallback."
  @spec endpoints(Discovery.t()) ::
          {:ok, %{device: String.t(), token: String.t()}} | {:error, term()}
  def endpoints(%{issuer: issuer} = disc) do
    case HTTP.get_json(issuer <> "/.well-known/openid-configuration") do
      {:ok, %{} = oidc} ->
        device = oidc["device_authorization_endpoint"] || disc.device_endpoint
        token = oidc["token_endpoint"] || disc.token_endpoint
        pair(device, token)

      {:error, reason} ->
        Logger.debug("OIDC discovery failed (#{inspect(reason)}); using the plane's endpoints")
        pair(disc.device_endpoint, disc.token_endpoint)
    end
  end

  defp pair(device, token) when is_binary(device) and is_binary(token),
    do: {:ok, %{device: device, token: token}}

  defp pair(_device, _token), do: {:error, :no_device_flow}

  @doc "Asks the issuer for a device code. The caller shows the URL and then polls."
  @spec start(Discovery.t()) :: {:ok, request()} | {:error, term()}
  def start(%{} = disc) do
    with {:ok, endpoints} <- endpoints(disc),
         {:ok, body} <-
           HTTP.post_form(endpoints.device,
             client_id: disc.client_id,
             scope: Enum.join(disc.scopes, " ")
           ) do
      expires_in = int(body["expires_in"], 600)

      {:ok,
       %{
         device_code: body["device_code"],
         user_code: body["user_code"],
         verification_uri: body["verification_uri"] || body["verification_url"] || "",
         verification_uri_complete: body["verification_uri_complete"],
         interval: max(int(body["interval"], 5), 1),
         expires_at: now() + expires_in * 1000,
         token_endpoint: endpoints.token
       }}
    end
  end

  @doc """
  Polls the token endpoint until the user approves. `sleep:` is the function
  used to wait between attempts, so tests can drive the loop without real time.
  """
  @spec poll(Discovery.t(), request(), keyword()) :: {:ok, tokens()} | {:error, term()}
  def poll(%{} = disc, %{} = request, opts \\ []) do
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    do_poll(disc, request, request.interval, sleep)
  end

  defp do_poll(disc, request, interval, sleep) do
    if now() > request.expires_at do
      {:error, :expired_token}
    else
      sleep.(interval * 1000)

      case HTTP.post_form(request.token_endpoint,
             grant_type: @grant,
             device_code: request.device_code,
             client_id: disc.client_id
           ) do
        {:ok, body} ->
          {:ok, tokens(body)}

        {:error, {:http, _status, %{"error" => "authorization_pending"}}} ->
          do_poll(disc, request, interval, sleep)

        {:error, {:http, _status, %{"error" => "slow_down"}}} ->
          do_poll(disc, request, interval + 5, sleep)

        {:error, {:http, _status, %{"error" => error}}} ->
          {:error, String.to_atom(error)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Exchanges a refresh token for a fresh access token."
  @spec refresh(Discovery.t(), String.t()) :: {:ok, tokens()} | {:error, term()}
  def refresh(%{} = disc, refresh_token) do
    with {:ok, endpoints} <- endpoints(disc),
         {:ok, body} <-
           HTTP.post_form(endpoints.token,
             grant_type: "refresh_token",
             refresh_token: refresh_token,
             client_id: disc.client_id
           ) do
      # An issuer that rotates refresh tokens returns a new one; one that does
      # not leaves the old one in place rather than blanking it.
      tokens = tokens(body)
      {:ok, %{tokens | refresh_token: tokens.refresh_token || refresh_token}}
    end
  end

  defp tokens(body) do
    %{
      access_token: body["access_token"],
      refresh_token: body["refresh_token"],
      id_token: body["id_token"],
      scope: body["scope"],
      expires_at: body["expires_in"] && now() + int(body["expires_in"], 0) * 1000
    }
  end

  @doc """
  The `exp` claim of a JWT, in milliseconds, without verifying anything. The
  client never validates these tokens — the plane and the workers do — it only
  needs to know when to ask for a new one.
  """
  @spec expiry(String.t() | nil) :: integer() | nil
  def expiry(token) when is_binary(token) do
    with [_header, payload | _] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"exp" => exp}} <- Jason.decode(json),
         true <- is_integer(exp) do
      exp * 1000
    else
      _ -> nil
    end
  end

  def expiry(_token), do: nil

  defp int(value, _default) when is_integer(value), do: value

  defp int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  defp int(_value, default), do: default

  defp now, do: System.system_time(:millisecond)
end
