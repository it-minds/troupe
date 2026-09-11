defmodule Troupe.Ctl.LoginTest do
  @moduledoc """
  `troupe login`, against a mock identity provider and a mock plane.

  Two things are being checked and neither is "does OAuth work". The first is that the
  user's provider credentials never reach the plane: the device grant runs against the
  provider, and what the plane receives is the token that came out. The second is where
  the result goes — a refresh token in a file only its owner can read, and a session
  token that is never written down at all.
  """

  use ExUnit.Case, async: false

  alias Troupe.Ctl.{Credentials, Login}

  @moduletag timeout: 60_000

  setup do
    test = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    base = "http://127.0.0.1:#{port}"

    state = :ets.new(:login_state, [:public, :set])
    :ets.insert(state, {:approved?, false})

    spawn_link(fn -> serve(listener, test, base, state) end)
    on_exit(fn -> :gen_tcp.close(listener) end)

    # In a directory of its own, because the test owns what it removes.
    home = Path.join(System.tmp_dir!(), "troupe-login-#{System.unique_integer([:positive])}")
    credentials = Path.join([home, "troupe", "credentials.json"])
    on_exit(fn -> File.rm_rf!(home) end)

    %{base: base, credentials: credentials, state: state}
  end

  test "runs the device grant against the provider and stores what comes back", context do
    # Approved the moment the client starts polling, which is what a person clicking the
    # link looks like from here.
    :ets.insert(context.state, {:approved?, true})

    assert {:ok, session} =
             Login.safe(context.base,
               path: context.credentials,
               open: fn _url, _code -> :ok end,
               poll_interval_ms: 10
             )

    assert session["subject"] == "ada@example.test"
    assert session["teams"] == ["engineering"]
    assert session["profiles"] == ["dev"]

    # The session token comes back to the caller and is not written down: it is short and
    # audience-bound, and there is nothing to be gained by storing one.
    assert session["token"] == "plane-session-token"
    stored = Credentials.get(context.base, path: context.credentials)
    refute Map.has_key?(stored, "token")
    assert stored["refresh_token"] == "the-refresh-token"
    assert stored["issuer"] == context.base
  end

  test "the credentials file is readable by nobody else", context do
    :ets.insert(context.state, {:approved?, true})

    assert {:ok, _} =
             Login.safe(context.base, path: context.credentials, open: fn _, _ -> :ok end, poll_interval_ms: 10)

    assert Credentials.private?(path: context.credentials)
    assert %File.Stat{mode: mode} = File.stat!(context.credentials)
    assert Bitwise.band(mode, 0o777) == 0o600

    assert %File.Stat{mode: directory} = File.stat!(Path.dirname(context.credentials))
    assert Bitwise.band(directory, 0o077) == 0
  end

  test "the plane never sees the user's provider credentials", context do
    :ets.insert(context.state, {:approved?, true})

    assert {:ok, _} =
             Login.safe(context.base, path: context.credentials, open: fn _, _ -> :ok end, poll_interval_ms: 10)

    requests = drain()

    # The device grant went to the provider.
    assert Enum.any?(requests, &(&1.path == "/device"))
    assert Enum.any?(requests, &(&1.path == "/token"))

    # And what the plane received was the token the provider issued, and nothing else.
    exchange = Enum.find(requests, &(&1.path == "/auth/exchange"))
    assert exchange.body["id_token"] == "the-id-token"
    assert Map.keys(exchange.body) == ["id_token"]
    refute exchange.raw =~ "the-refresh-token"
    refute exchange.raw =~ "device_code"
  end

  test "waits while the person has not clicked yet", context do
    # Not approved: the provider answers `authorization_pending` until it is.
    spawn(fn ->
      Process.sleep(60)
      :ets.insert(context.state, {:approved?, true})
    end)

    assert {:ok, session} =
             Login.safe(context.base, path: context.credentials, open: fn _, _ -> :ok end, poll_interval_ms: 10)

    assert session["subject"] == "ada@example.test"

    requests = drain()
    assert Enum.count(requests, &(&1.path == "/token")) > 1
  end

  test "a plane that is not a plane says so, without storing anything", context do
    assert {:error, message} =
             Login.safe("http://127.0.0.1:1", path: context.credentials, open: fn _, _ -> :ok end)

    assert message =~ "could not reach"
    refute File.exists?(context.credentials)
  end

  test "logging out forgets the plane", context do
    :ets.insert(context.state, {:approved?, true})

    assert {:ok, _} =
             Login.safe(context.base, path: context.credentials, open: fn _, _ -> :ok end, poll_interval_ms: 10)

    assert Credentials.get(context.base, path: context.credentials)
    assert :ok = Credentials.forget(context.base, path: context.credentials)
    refute Credentials.get(context.base, path: context.credentials)
  end

  # -- a mock provider and a mock plane ---------------------------------------

  defp drain(acc \\ []) do
    receive do
      {:http, request} -> drain([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp serve(listener, test, base, state) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> handle(socket, test, base, state) end)
        serve(listener, test, base, state)

      {:error, _reason} ->
        :ok
    end
  end

  defp handle(socket, test, base, state) do
    with {:ok, raw} <- read(socket),
         [head, body] <- String.split(raw, "\r\n\r\n", parts: 2) do
      [request_line | _] = String.split(head, "\r\n")
      [_method, path | _] = String.split(request_line, " ")

      send(test, {:http, %{path: path, body: decode(body), raw: raw}})
      :gen_tcp.send(socket, respond(path, base, state))
    end

    :gen_tcp.close(socket)
  end

  defp respond("/.well-known/troupe", base, _state) do
    json(%{
      "issuer" => base,
      "client_id" => "troupe-cli",
      "device_authorization_endpoint" => base <> "/device",
      "token_endpoint" => base <> "/token",
      "scopes" => ["openid", "profile", "offline_access"]
    })
  end

  defp respond("/device", base, _state) do
    json(%{
      "device_code" => "the-device-code",
      "user_code" => "WDJB-MJHT",
      "verification_uri" => base <> "/activate",
      "verification_uri_complete" => base <> "/activate?user_code=WDJB-MJHT",
      "expires_in" => 600,
      "interval" => 1
    })
  end

  defp respond("/token", _base, state) do
    case :ets.lookup(state, :approved?) do
      [{:approved?, true}] ->
        json(%{
          "access_token" => "the-access-token",
          "id_token" => "the-id-token",
          "refresh_token" => "the-refresh-token",
          "token_type" => "Bearer",
          "expires_in" => 3_600
        })

      _ ->
        json(%{"error" => "authorization_pending"}, 400)
    end
  end

  defp respond("/auth/exchange", _base, _state) do
    json(%{
      "token" => "plane-session-token",
      "expires_at" => System.system_time(:second) + 900,
      "subject" => "ada@example.test",
      "display_name" => "Ada",
      "teams" => ["engineering"],
      "profiles" => ["dev"]
    })
  end

  defp respond(_path, _base, _state), do: json(%{"error" => "not found"}, 404)

  defp json(payload, status \\ 200) do
    body = Jason.encode!(payload)

    [
      "HTTP/1.1 #{status} OK\r\n",
      "content-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ]
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> URI.decode_query(body)
    end
  end

  defp read(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        acc = acc <> data
        if complete?(acc), do: {:ok, acc}, else: read(socket, acc)

      {:error, _reason} ->
        :error
    end
  end

  defp complete?(request) do
    case String.split(request, "\r\n\r\n", parts: 2) do
      [head, body] -> byte_size(body) >= length_of(head)
      _ -> false
    end
  end

  defp length_of(head) do
    head
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(String.downcase(line), ": ", parts: 2) do
        ["content-length", value] -> String.to_integer(String.trim(value))
        _ -> nil
      end
    end)
  end
end
