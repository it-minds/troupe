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

  # Credential Manager holds 2560 bytes in an entry: a value past that is kept in parts
  # under the entry's name and read back whole, and deleting it takes every part. On
  # Windows the store is the OS's, under this test's own service; elsewhere the VM's.
  test "a value of four kilobytes round-trips and is deleted whole" do
    backend = if match?({:win32, _}, :os.type()), do: OS, else: Memory
    entry = Keyring.entry("steering-long")
    value = "eyJ" <> String.duplicate("a1B2-c3_D", 455)
    assert byte_size(value) > 4_096

    on_exit(fn -> backend.delete(entry) end)

    assert :ok = backend.put(entry, value)
    assert {:ok, ^value} = backend.get(entry)

    # In two parts under the entry's name, each read as an entry of its own.
    if backend == OS do
      assert {:ok, first} = OS.get(entry <> "/0")
      assert {:ok, second} = OS.get(entry <> "/1")
      assert byte_size(first) == 2_560 and first <> second == value
      assert OS.get(entry <> "/2") == :none
    end

    assert :ok = backend.put(entry, "short")
    assert {:ok, "short"} = backend.get(entry)
    assert :ok = backend.put(entry, value)
    assert :ok = backend.delete(entry)
    assert backend.get(entry) == :none

    if backend == OS do
      for part <- 0..1, do: assert(OS.get(entry <> "/#{part}") == :none, "part #{part} was left")
    end
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
