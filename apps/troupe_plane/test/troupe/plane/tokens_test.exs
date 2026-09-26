defmodule Troupe.Plane.TokensTest do
  @moduledoc """
  Session tokens, against a real OpenBao transit engine.

  The properties that matter are refusals, and none of them can be checked against a
  double: that a token minted for one pod is rejected by another, that nothing is
  accepted past `exp`, and that the plane can sign without being able to export the key
  it signs with.
  """

  use ExUnit.Case, async: false

  alias Troupe.Plane.Tokens
  alias Troupe.Protocol.Token

  @moduletag timeout: 60_000

  setup_all do
    if reachable?() do
      :ok
    else
      IO.puts(:stderr, "\nSKIPPED: no OpenBao. Bring one up with `scripts/dev-up`.\n")
      {:ok, skip: true}
    end
  end

  setup context do
    if context[:skip], do: flunk("no OpenBao; see the message from setup_all"), else: :ok
  end

  describe "minting" do
    test "a minted token verifies against the published JWKS" do
      {:ok, jwt, payload} = Tokens.mint(claims(), audience: "worker-dev-0")
      {:ok, jwks} = Tokens.jwks()

      assert {:ok, claims} = Token.verify(jwt, jwks, audience: "worker-dev-0")
      assert claims["sub"] == "someone@example.test"
      assert claims["session_id"] == "s-1"
      assert claims["role"] == "owner"
      assert claims["aud"] == "worker-dev-0"
      assert claims["jti"] == payload["jti"]
    end

    test "the kid in the header is the thumbprint of the key in the JWKS" do
      {:ok, jwt, _} = Tokens.mint(claims(), audience: "worker-dev-0")
      {:ok, %{"keys" => [current | _]}} = Tokens.jwks()

      assert Token.peek_kid(jwt) == current["kid"]
      assert current["kid"] == Token.thumbprint(current)
      assert current["kty"] == "EC"
      assert current["crv"] == "P-256"

      # The public half and nothing else. A JWKS carrying `d` would be the private key
      # on a public endpoint.
      refute Map.has_key?(current, "d")
    end

    test "a lifetime longer than the ceiling is cut down to it" do
      {:ok, _jwt, payload} = Tokens.mint(claims(), audience: "worker-dev-0", lifetime: 86_400)
      assert payload["exp"] - payload["iat"] == Token.max_lifetime_seconds()
    end
  end

  describe "refusals" do
    test "a token minted for a ux pod is rejected by a dev pod" do
      {:ok, jwt, _} = Tokens.mint(claims(), audience: "worker-ux-0")
      {:ok, jwks} = Tokens.jwks()

      assert {:ok, _} = Token.verify(jwt, jwks, audience: "worker-ux-0")
      assert {:error, :wrong_audience} = Token.verify(jwt, jwks, audience: "worker-dev-0")
    end

    test "nothing is accepted past exp" do
      {:ok, jwt, payload} = Tokens.mint(claims(), audience: "worker-dev-0", lifetime: 60)
      {:ok, jwks} = Tokens.jwks()

      just_before = payload["exp"] - 1
      well_after = payload["exp"] + 3_600

      assert {:ok, _} = Token.verify(jwt, jwks, audience: "worker-dev-0", now: just_before)
      assert {:error, :expired} = Token.verify(jwt, jwks, audience: "worker-dev-0", now: well_after)
    end

    test "a tampered payload does not verify" do
      {:ok, jwt, _} = Tokens.mint(claims(), audience: "worker-dev-0")
      {:ok, jwks} = Tokens.jwks()

      [header, payload, signature] = String.split(jwt, ".")
      {:ok, decoded} = Token.peek(jwt)

      forged =
        decoded
        |> Map.put("role", "owner")
        |> Map.put("sub", "someone-else@example.test")
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      assert {:error, :bad_signature} =
               Token.verify(Enum.join([header, forged, signature], "."), jwks,
                 audience: "worker-dev-0"
               )

      # And the original still does, so the test is about the tampering and not about
      # the token being broken to begin with.
      assert {:ok, _} =
               Token.verify(Enum.join([header, payload, signature], "."), jwks,
                 audience: "worker-dev-0"
               )
    end

    test "a token signed by somebody else's key is rejected" do
      other = JOSE.JWK.generate_key({:ec, "P-256"})

      jwt =
        other
        |> JOSE.JWT.sign(%{"alg" => "ES256"}, %{
          "sub" => "someone@example.test",
          "aud" => "worker-dev-0",
          "exp" => System.system_time(:second) + 600
        })
        |> JOSE.JWS.compact()
        |> elem(1)

      {:ok, jwks} = Tokens.jwks()
      assert {:error, :bad_signature} = Token.verify(jwt, jwks, audience: "worker-dev-0")
    end

    test "an audience must be given: a verifier that does not care is refused" do
      {:ok, jwt, _} = Tokens.mint(claims(), audience: "worker-dev-0")
      {:ok, jwks} = Tokens.jwks()

      assert {:error, :no_audience_given} = Token.verify(jwt, jwks, [])
    end
  end

  describe "what the plane may not do" do
    test "the signing key cannot be exported" do
      # The Forbidden list's shape, checked against the engine rather than assumed: a
      # transit key created without `exportable` cannot be read out even by the token
      # that created it.
      response =
        Req.request(
          method: :get,
          url: "#{address()}/v1/transit/export/signing-key/troupe-session-tokens",
          headers: [{"x-vault-token", "troupe-dev-root"}],
          decode_body: true,
          retry: false
        )

      assert {:ok, %{status: status}} = response
      assert status >= 400
    end
  end

  describe "roles and scopes" do
    test "roles map to the same three scopes the local daemon uses" do
      assert Token.scopes_for("owner") == [:observe, :control, :admin]
      assert Token.scopes_for("collaborator") == [:observe, :control]
      assert Token.scopes_for("viewer") == [:observe]
      assert Token.scopes_for("nonsense") == []
    end
  end

  defp claims do
    %{
      "sub" => "someone@example.test",
      "session_id" => "s-1",
      "role" => "owner",
      "scopes" => ["observe", "control", "admin"],
      "team" => "team-alpha"
    }
  end

  defp address, do: Application.get_env(:troupe_plane, :transit, [])[:address] || "http://localhost:28200"

  defp reachable? do
    match?({:ok, %{status: 200}}, Req.request(method: :get, url: address() <> "/v1/sys/health", retry: false))
  rescue
    _ -> false
  end
end
