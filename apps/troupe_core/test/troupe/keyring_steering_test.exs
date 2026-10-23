defmodule Troupe.Keyring.SteeringTest do
  @moduledoc """
  The daemon's sign-in for steering as the credential store keeps it (#58): one entry per
  state directory, read back as it was written, and forgotten from outside the daemon
  only where it is for the plane and the person signing out.
  """

  use ExUnit.Case, async: false

  alias Troupe.Keyring.Steering

  @sign_in %{url: "https://plane.example.test", subject: "ada@example.test", grant: "rg_1.secret"}

  setup do
    name = Steering.name(Path.join(System.tmp_dir!(), "troupe-steering-#{System.unique_integer([:positive])}"))
    on_exit(fn -> Steering.delete(name) end)
    %{name: name}
  end

  test "each state directory has an entry of its own" do
    assert Steering.name("/home/ada/.local/state/troupe") =~ ~r/^steering-[0-9a-f]{12}$/
    refute Steering.name("/home/ada/.local/state/troupe") == Steering.name("/tmp/scratch/state")
  end

  test "a sign-in is read back as it was written, and is printable in the store", %{name: name} do
    assert Steering.read(name) == :none
    assert :ok = Steering.write(name, @sign_in)
    assert {:ok, @sign_in} = Steering.read(name)

    {:ok, raw} = Troupe.Keyring.get(name)
    assert raw =~ ~r/^[A-Za-z0-9_-]+$/
  end

  test "forgetting takes it out only for its plane and its person", %{name: name} do
    :ok = Steering.write(name, @sign_in)

    assert Steering.forget("https://other.example.test", "ada@example.test", name) == :none
    assert Steering.forget("https://plane.example.test", "bea@example.test", name) == :none
    assert {:ok, @sign_in} = Steering.read(name)

    assert {:ok, @sign_in} = Steering.forget("https://plane.example.test/", "ada@example.test", name)
    assert Steering.read(name) == :none
    assert Steering.forget("https://plane.example.test", nil, name) == :none
  end
end
