defmodule Troupe.Plane.CORSTest do
  @moduledoc """
  Cross-origin access to the API, over a real socket.

  What matters is what a browser would see: that an allowed origin gets its own origin
  back and nothing wider, that a preflight is answered before it reaches a route, that
  an origin not on the list gets nothing, and that the API never claims to accept
  credentials. Against the same router the plane serves, on a port of its own.
  """

  use ExUnit.Case, async: false

  alias Troupe.Plane.Web.Router

  @moduletag timeout: 60_000

  @gui "https://gui.example.test"
  @tauri "tauri://localhost"

  setup do
    {:ok, listener} =
      start_supervised({Bandit, plug: Router, scheme: :http, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

    Application.put_env(:troupe_plane, :cors_origins, [@gui, @tauri])

    Application.put_env(:troupe_plane, :oidc,
      issuer: "https://issuer.example.test",
      client_id: "troupe-cli",
      device_authorization_endpoint: "https://issuer.example.test/device",
      token_endpoint: "https://issuer.example.test/token"
    )

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :cors_origins)
      Application.delete_env(:troupe_plane, :oidc)
    end)

    %{url: "http://127.0.0.1:#{port}"}
  end

  describe "preflight" do
    test "an allowed origin is answered before any route is reached", context do
      assert {:ok, %{status: 204} = response} = preflight(context, "/rpc", @gui)

      assert header(response, "access-control-allow-origin") == [@gui]
      assert header(response, "access-control-allow-methods") == ["GET, POST, OPTIONS"]
      assert header(response, "access-control-allow-headers") == ["authorization, content-type"]
      assert header(response, "access-control-max-age") == ["600"]
      assert "origin" in vary(response)
      assert header(response, "access-control-allow-credentials") == []
    end

    test "each allowed origin gets itself back, never a wildcard", context do
      assert {:ok, %{status: 204} = response} = preflight(context, "/auth/exchange", @tauri)
      assert header(response, "access-control-allow-origin") == [@tauri]
    end

    test "an origin not on the list gets no CORS answer at all", context do
      assert {:ok, %{status: 404} = response} =
               preflight(context, "/rpc", "https://evil.example.test")

      assert header(response, "access-control-allow-origin") == []
      assert header(response, "access-control-allow-methods") == []
      # But the answer still says it depends on the origin, for any cache in between.
      assert "origin" in vary(response)
    end

    test "routes a browser has no business with are left alone", context do
      # SCIM answers with its own bearer check, so the status is its 401; what matters is
      # that no CORS header was added on the way.
      assert {:ok, %{status: 401} = response} = preflight(context, "/scim/v2/Users", @gui)
      assert header(response, "access-control-allow-origin") == []
    end
  end

  describe "actual requests" do
    test "carry the allow header when the origin matches", context do
      assert {:ok, %{status: 200} = response} = get(context, "/.well-known/troupe", @gui)

      assert header(response, "access-control-allow-origin") == [@gui]
      assert "origin" in vary(response)
      assert header(response, "access-control-allow-credentials") == []
    end

    test "and not when it does not", context do
      assert {:ok, %{status: 200} = response} =
               get(context, "/.well-known/troupe", "https://evil.example.test")

      assert header(response, "access-control-allow-origin") == []
    end

    test "nor when there is no origin, which is the CLI", context do
      assert {:ok, %{status: 200} = response} = get(context, "/.well-known/troupe", nil)
      assert header(response, "access-control-allow-origin") == []
    end
  end

  test "an empty allowlist is CORS switched off", context do
    Application.put_env(:troupe_plane, :cors_origins, [])

    assert {:ok, %{status: 404} = response} = preflight(context, "/rpc", @gui)
    assert header(response, "access-control-allow-origin") == []
    refute "origin" in vary(response)
  end

  # -- helpers ----------------------------------------------------------------

  defp preflight(context, path, origin) do
    Req.request(
      method: :options,
      url: context.url <> path,
      headers: [{"origin", origin}, {"access-control-request-method", "POST"}],
      retry: false
    )
  end

  defp get(context, path, origin) do
    Req.request(
      method: :get,
      url: context.url <> path,
      headers: if(origin, do: [{"origin", origin}], else: []),
      decode_body: true,
      retry: false
    )
  end

  defp header(response, name), do: Req.Response.get_header(response, name)

  # `Vary` may arrive as one comma-joined value or several; the compression layer adds
  # `accept-encoding` of its own, so the question is whether `origin` is among them.
  defp vary(response) do
    response |> header("vary") |> Enum.flat_map(&String.split(&1, ~r/,\s*/))
  end
end
