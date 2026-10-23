defmodule Troupe.PlaneKeysTest do
  @moduledoc """
  The key each plane signs with, as this machine pinned it (#657): pinned the first time,
  a changed one offered and refused until a person accepts it by its fingerprint, and every
  signed answer checked against the pin.
  """

  use ExUnit.Case, async: true

  alias Troupe.PlaneKeys
  alias Troupe.Protocol.{ClientUpdate, PlaneSignature}

  @plane "https://plane.example.test"

  setup do
    dir = Path.join(System.tmp_dir!(), "troupe-plane-keys-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: Path.join(dir, "plane-keys.json")}
  end

  defp keypair do
    {public, secret} = :crypto.generate_key(:eddsa, :ed25519)

    %{
      served: PlaneSignature.key_json(public),
      secret: secret,
      fingerprint: PlaneSignature.fingerprint(public)
    }
  end

  defp signed(key, kind, body, opts \\ []) do
    document = PlaneSignature.document(kind, body, opts)
    signature = :crypto.sign(:eddsa, :none, document, [key.secret, :ed25519])
    Map.put(body, "signed", PlaneSignature.envelope(document, signature, key.fingerprint))
  end

  test "the first key seen is pinned; the same again changes nothing", %{path: path} do
    key = keypair()

    assert {:ok, {:pinned, fingerprint}} = PlaneKeys.see(@plane <> "/", key.served, path)
    assert fingerprint == key.fingerprint
    assert %{"fingerprint" => ^fingerprint, "pinned_at" => _} = PlaneKeys.pinned(@plane, path)
    assert {:ok, {:same, ^fingerprint}} = PlaneKeys.see(@plane, key.served, path)
  end

  test "a changed key is offered and not trusted until accepted by its fingerprint", %{path: path} do
    old = keypair()
    new = keypair()
    {:ok, _} = PlaneKeys.see(@plane, old.served, path)

    assert {:ok, {:changed, pinned, offered}} = PlaneKeys.see(@plane, new.served, path)
    assert {pinned, offered} == {old.fingerprint, new.fingerprint}
    assert PlaneKeys.pinned(@plane, path)["fingerprint"] == old.fingerprint

    answer = signed(new, "client_versions", %{"versions" => %{}})
    assert {:error, sentence} = PlaneKeys.check(@plane, answer, "client_versions", path: path)
    assert sentence =~ "is signed by the key #{new.fingerprint}, not by #{old.fingerprint}"
    assert sentence =~ "troupe plane-key accept #{new.fingerprint}"

    assert {:error, refused} = PlaneKeys.accept(@plane, old.fingerprint <> "x", path: path)
    assert refused =~ "offers the key #{new.fingerprint}, not"
    assert PlaneKeys.pinned(@plane, path)["fingerprint"] == old.fingerprint

    assert {:ok, accepted} = PlaneKeys.accept(@plane, new.fingerprint, path: path)
    assert accepted == new.fingerprint
    refute Map.has_key?(PlaneKeys.pinned(@plane, path), "offered")

    assert {:ok, %{"versions" => %{}}, :signed} =
             PlaneKeys.check(@plane, answer, "client_versions", path: path)
  end

  test "accepting a key the plane serves now offers it first", %{path: path} do
    old = keypair()
    new = keypair()
    {:ok, _} = PlaneKeys.see(@plane, old.served, path)

    assert {:ok, _} = PlaneKeys.accept(@plane, new.fingerprint, path: path, served: new.served)
    assert PlaneKeys.pinned(@plane, path)["fingerprint"] == new.fingerprint
  end

  test "a signed answer is the body the plane signed; an edited one is refused", %{path: path} do
    key = keypair()
    {:ok, _} = PlaneKeys.see(@plane, key.served, path)
    answer = signed(key, "client_defaults", %{"enforced" => %{"max_turns" => 10}})

    assert {:ok, %{"enforced" => %{"max_turns" => 10}}, :signed} =
             PlaneKeys.check(@plane, answer, "client_defaults", path: path)

    edited = update_in(answer, ["signed", "document"], &String.replace(&1, "10", "900"))
    assert {:error, sentence} = PlaneKeys.check(@plane, edited, "client_defaults", path: path)
    assert sentence =~ "the organisation's document from #{@plane} does not match its signature"
  end

  test "once a key is pinned an unsigned answer is refused; with none it is taken as it is", %{
    path: path
  } do
    assert {:ok, %{"tui" => %{}}, :unsigned} =
             PlaneKeys.check(@plane, %{"tui" => %{}, "signed" => nil}, "client_versions",
               path: path
             )

    key = keypair()
    {:ok, _} = PlaneKeys.see(@plane, key.served, path)

    assert {:error, sentence} =
             PlaneKeys.check(@plane, %{"tui" => %{}}, "client_versions", path: path)

    assert sentence =~ "the version policy from #{@plane} is not signed"
    assert sentence =~ key.fingerprint
  end

  test "a signed answer from a plane nothing is pinned for pins the key it serves", %{path: path} do
    key = keypair()
    answer = signed(key, "client_versions", %{"versions" => %{}})

    get = fn url ->
      if url == @plane <> "/.well-known/troupe-signing-key",
        do: {:ok, key.served},
        else: :not_found
    end

    assert {:ok, _body, :signed} =
             PlaneKeys.check(@plane, answer, "client_versions", path: path, get: get)

    assert PlaneKeys.pinned(@plane, path)["fingerprint"] == key.fingerprint
  end

  test "a refusal of this version is taken as the pinned key signed it, for this client, and not otherwise",
       %{path: path} do
    key = keypair()
    other = keypair()
    {:ok, _} = PlaneKeys.see(@plane, key.served, path)

    refusal =
      ClientUpdate.refusal("daemon", "0.21.0-beta", %{"minimum" => "0.22.0-beta"}, :below_minimum)

    held = &PlaneKeys.held_refusal(@plane, &1, "daemon", "0.21.0-beta", path: path)

    assert {:refused, sentence} = held.(signed(key, "update_required", refusal))
    assert sentence =~ "needs troupe-daemon 0.22.0-beta or later, and this is 0.21.0-beta"

    # Unsigned, by another key, edited, or another version's: not the plane's word.
    assert {:not_taken, why} = held.(refusal)
    assert why =~ "the plane's refusal of this version from #{@plane} is not signed"

    assert {:not_taken, why} = held.(signed(other, "update_required", refusal))
    assert why =~ "is signed by the key #{other.fingerprint}"

    edited = put_in(signed(key, "update_required", refusal), ["signed", "document"], "{}")
    assert {:not_taken, _why} = held.(edited)

    assert {:not_taken, why} =
             held.(signed(key, "update_required", %{refusal | "version" => "0.20.0-beta"}))

    assert why =~ "another client or version"

    # One copied off the wire past its hour.
    an_hour_ago = DateTime.add(DateTime.utc_now(), -3601, :second)

    assert {:not_taken, why} = held.(signed(key, "update_required", refusal, now: an_hour_ago))
    assert why =~ "was the plane's word until"

    # A plane nothing is pinned for, which signs nothing: taken as it always was.
    assert {:refused, ^sentence} =
             PlaneKeys.held_refusal("https://old.example.test", refusal, "daemon", "0.21.0-beta",
               path: path
             )
  end

  test "a plane with no key path signs nothing", %{path: _path} do
    assert :unsigned = PlaneKeys.fetch(@plane, get: fn _url -> :not_found end)

    assert {:error, _} =
             PlaneKeys.fetch(@plane, get: fn _url -> {:ok, %{"algorithm" => "rsa"}} end)

    assert PlaneKeys.unsigned_line(@plane, "client_versions") =~ "signs nothing it tells clients"
  end
end
