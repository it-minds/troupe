defmodule Troupe.KeyringTest do
  @moduledoc """
  The operating system's credential store, as the daemon keeps its sign-in for steering in
  it (#58): an entry is written, read back, replaced and removed under the service a test
  names, and a store that is not there says so rather than falling back to a file.
  """

  use ExUnit.Case, async: false

  alias Troupe.Keyring
  alias Troupe.Keyring.{Memory, OS}

  setup do
    previous = System.get_env("TROUPE_KEYRING_SERVICE")
    System.put_env("TROUPE_KEYRING_SERVICE", "troupe-test-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if previous,
        do: System.put_env("TROUPE_KEYRING_SERVICE", previous),
        else: System.delete_env("TROUPE_KEYRING_SERVICE")
    end)
  end

  test "an entry is named under the service a test names, never the person's own" do
    assert Keyring.service() =~ "troupe-test-"
    assert Keyring.entry("steering-abc") == Keyring.service() <> "/steering-abc"

    System.delete_env("TROUPE_KEYRING_SERVICE")
    assert Keyring.entry("steering-abc") == "troupe/steering-abc"
  end

  test "the store in the VM writes, reads back, replaces and removes an entry" do
    assert Keyring.get("one") == :none
    assert :ok = Keyring.put("one", "first")
    assert {:ok, "first"} = Keyring.get("one")
    assert :ok = Keyring.put("one", "second")
    assert {:ok, "second"} = Keyring.get("one")
    assert Map.has_key?(Memory.entries(), Keyring.entry("one"))
    assert :ok = Keyring.delete("one")
    assert Keyring.get("one") == :none
    assert :ok = Keyring.delete("one"), "removing what is not there is not an error"
  end

  # The machine's own store, where it has one: Credential Manager on Windows, the keychain
  # on a Mac, the Secret Service where `secret-tool` answers. Elsewhere it says it has
  # none, and the daemon keeps the sign-in in memory.
  test "the operating system's store does the same, or says there is none" do
    entry = Keyring.entry("steering-test")

    case OS.get(entry) do
      {:error, :unavailable} ->
        assert {:error, :unavailable} = OS.put(entry, "x")

      {:error, _no_agent} ->
        :ok

      :none ->
        assert :ok = OS.put(entry, "eyJhIjoiYiJ9-value_1")
        assert {:ok, "eyJhIjoiYiJ9-value_1"} = OS.get(entry)
        assert :ok = OS.delete(entry)
        assert OS.get(entry) == :none
        assert :ok = OS.delete(entry)
    end
  end
end
