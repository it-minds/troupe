defmodule Troupe.Plane.NamespacesTest do
  @moduledoc """
  The chart's `namespace` and `policy.namespacePrefix` reach the plane (D125): where it
  writes WorkerProfiles and Triggers (`Troupe.Plane.Provision.namespace/0`), and the prefix
  it takes off an enrolling pod's namespace to name its profile
  (`Troupe.Plane.Enrolment.namespace_prefix/0`). `config/runtime.exs` read as a release
  reads it, in the environment the chart's Deployment gives the plane.
  """

  # The process environment and the application's are global.
  use ExUnit.Case, async: false

  alias Troupe.Plane.{Enrolment, Provision}

  test "a release reads the chart's namespace and worker prefix" do
    config =
      read(%{"TROUPE_PLANE_NAMESPACE" => "acme-system", "TROUPE_NAMESPACE_PREFIX" => "acme-w-"})

    assert config[:namespace] == "acme-system"
    assert config[:namespace_prefix] == "acme-w-"

    with_plane_env(config, fn ->
      assert Provision.namespace() == "acme-system"
      assert Enrolment.namespace_prefix() == "acme-w-"
    end)
  end

  test "and the defaults where the chart says nothing" do
    config = read(%{"TROUPE_PLANE_NAMESPACE" => nil, "TROUPE_NAMESPACE_PREFIX" => nil})

    assert config[:namespace] == "troupe-system"
    assert config[:namespace_prefix] == "troupe-w-"
  end

  # `config/runtime.exs` read as a release reads it, with `vars` set (a `nil` unset) and put
  # back afterwards, and the plane's settings out of it.
  defp read(vars) do
    previous = Map.new(vars, fn {name, _value} -> {name, System.get_env(name)} end)
    Enum.each(vars, fn {name, value} -> put_env(name, value) end)

    try do
      "../../../../../config/runtime.exs"
      |> Path.expand(__DIR__)
      |> Config.Reader.read!(env: :prod, target: :host)
      |> Keyword.fetch!(:troupe_plane)
    after
      Enum.each(previous, fn {name, value} -> put_env(name, value) end)
    end
  end

  defp with_plane_env(config, fun) do
    keys = [:namespace, :namespace_prefix]
    previous = Map.new(keys, &{&1, Application.fetch_env(:troupe_plane, &1)})
    Enum.each(keys, &Application.put_env(:troupe_plane, &1, config[&1]))

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:troupe_plane, key, value)
        {key, :error} -> Application.delete_env(:troupe_plane, key)
      end)
    end
  end

  defp put_env(name, nil), do: System.delete_env(name)
  defp put_env(name, value), do: System.put_env(name, value)
end
