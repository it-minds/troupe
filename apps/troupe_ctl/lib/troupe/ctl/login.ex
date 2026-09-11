defmodule Troupe.Ctl.Login do
  @moduledoc """
  `troupe login <plane-url>`: the device authorization grant, and where the result goes.

  The grant is run against the **identity provider**, not against the plane. The plane
  is asked only where its provider is and what client id to use; the user's credentials
  never pass through it. What the plane gets afterwards is the token the provider
  issued, which it exchanges for a plane token of its own.

  Two credentials come out of this, with two lifetimes and two homes:

  * the provider's **refresh token**, written to a user-only file, because it is what
    lets `troupe` work tomorrow without asking again;
  * the plane's **session token**, which is short, audience-bound and never written to
    disk — it is minted from the refresh token when it is needed.

  The file is `0600` and its directory is `0700`. That is the same trust boundary the
  local daemon's socket uses, written the same way: if you can read the file you are
  the user who owns it.
  """

  alias Troupe.Ctl.Credentials

  @poll_grace_ms 500

  @doc """
  Log in to a plane, returning what was stored.

  `:open` is called with the verification URL so a terminal can offer to open a browser;
  it defaults to printing, because a login that silently opened a browser on a remote
  machine would be a surprise.
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def run(plane_url, opts \\ []) do
    plane_url = String.trim_trailing(plane_url, "/")

    with {:ok, discovery} <- discover(plane_url),
         {:ok, authorization} <- start_device_flow(discovery, opts),
         :ok <- present(authorization, opts),
         {:ok, tokens} <- poll(discovery, authorization, opts),
         {:ok, session} <- exchange(plane_url, tokens, opts) do
      store(plane_url, discovery, tokens, session, opts)
    end
  end

  @doc "What a plane says about itself and its provider."
  @spec discover(String.t()) :: {:ok, map()} | {:error, String.t()}
  def discover(plane_url) do
    case request(:get, plane_url <> "/.well-known/troupe") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "#{plane_url} answered #{status}; is it a Troupe plane?"}
      {:error, reason} -> {:error, "could not reach #{plane_url}: #{inspect(reason)}"}
    end
  end

  defp start_device_flow(discovery, opts) do
    endpoint = discovery["device_authorization_endpoint"]

    if is_binary(endpoint) do
      form = %{
        "client_id" => discovery["client_id"],
        "scope" => Enum.join(discovery["scopes"] || ~w(openid profile email offline_access), " ")
      }

      case request(:post, endpoint, form: form, opts: opts) do
        {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
        {:ok, %{status: status, body: body}} -> {:error, "the identity provider answered #{status}: #{inspect(body)}"}
        {:error, reason} -> {:error, "could not reach the identity provider: #{inspect(reason)}"}
      end
    else
      {:error, "this plane does not publish a device authorization endpoint"}
    end
  end

  defp present(authorization, opts) do
    url = authorization["verification_uri_complete"] || authorization["verification_uri"]
    code = authorization["user_code"]

    case Keyword.get(opts, :open) do
      nil -> IO.puts("\nOpen #{url}\nand enter the code #{code}\n")
      open when is_function(open, 2) -> open.(url, code)
    end

    :ok
  end

  # The provider tells us how often to ask and for how long. Honoured rather than
  # guessed: a client that polls faster than `interval` is one the provider is entitled
  # to start refusing.
  defp poll(discovery, authorization, opts) do
    interval = (authorization["interval"] || 5) * 1_000
    deadline = System.monotonic_time(:millisecond) + (authorization["expires_in"] || 600) * 1_000

    do_poll(discovery, authorization, interval, deadline, opts)
  end

  defp do_poll(discovery, authorization, interval, deadline, opts) do
    form = %{
      "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
      "device_code" => authorization["device_code"],
      "client_id" => discovery["client_id"]
    }

    case request(:post, discovery["token_endpoint"], form: form, opts: opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{body: %{"error" => "authorization_pending"}}} ->
        wait(interval, deadline, opts)
        do_poll(discovery, authorization, interval, deadline, opts)

      # The provider is telling us we are asking too often, and the only correct answer
      # is to ask less often.
      {:ok, %{body: %{"error" => "slow_down"}}} ->
        wait(interval * 2, deadline, opts)
        do_poll(discovery, authorization, interval * 2, deadline, opts)

      {:ok, %{body: %{"error" => error} = body}} ->
        {:error, "the identity provider refused: #{error}#{detail(body)}"}

      {:error, reason} ->
        {:error, "could not reach the identity provider: #{inspect(reason)}"}
    end
  end

  defp wait(interval, deadline, opts) do
    if System.monotonic_time(:millisecond) + interval > deadline do
      throw({:login, "the login code expired before it was used"})
    end

    Process.sleep(Keyword.get(opts, :poll_interval_ms, min(interval, @poll_grace_ms)))
  end

  defp detail(%{"error_description" => description}) when is_binary(description), do: " (#{description})"
  defp detail(_body), do: ""

  defp exchange(plane_url, tokens, opts) do
    token = tokens["id_token"] || tokens["access_token"]

    case request(:post, plane_url <> "/auth/exchange", json: %{"id_token" => token}, opts: opts) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, "the plane refused the login (#{status}): #{body["reason"] || inspect(body)}"}

      {:error, reason} ->
        {:error, "could not reach the plane: #{inspect(reason)}"}
    end
  end

  defp store(plane_url, discovery, tokens, session, opts) do
    record = %{
      "plane" => plane_url,
      "issuer" => discovery["issuer"],
      "client_id" => discovery["client_id"],
      "token_endpoint" => discovery["token_endpoint"],
      "refresh_token" => tokens["refresh_token"],
      "subject" => session["subject"],
      "display_name" => session["display_name"],
      "teams" => session["teams"],
      "profiles" => session["profiles"],
      "stored_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    with :ok <- Credentials.put(plane_url, record, opts) do
      {:ok, Map.put(record, "token", session["token"])}
    end
  end

  defp request(method, url, opts \\ []) do
    options =
      [method: method, url: url, decode_body: true, retry: false, receive_timeout: 30_000]
      |> Keyword.merge(Keyword.drop(opts, [:opts]))

    Req.request(options)
  end

  @doc "Run a login, turning the expiry `throw` into an ordinary error."
  @spec safe(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def safe(plane_url, opts \\ []) do
    run(plane_url, opts)
  catch
    {:login, message} -> {:error, message}
  end
end
