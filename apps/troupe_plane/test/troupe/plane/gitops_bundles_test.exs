defmodule Troupe.Plane.GitopsBundlesTest do
  @moduledoc """
  A channel's configuration bundle in GitOps mode (#1198): a repository holds it as a
  `ConfigBundle` resource, something else applies it, and the plane's pass publishes it as
  the channel's next version when its content changes, as `system:gitops`.
  """

  use Troupe.Plane.DataCase, async: false

  @moduletag timeout: 60_000

  describe "the CRD" do
    setup do
      crd =
        "../../../../../charts/troupe/crds/configbundle.yaml"
        |> Path.expand(__DIR__)
        |> YamlElixir.read_from_file!()

      %{crd: crd}
    end

    test "is a namespaced ConfigBundle whose spec is the bundle document as it is", %{crd: crd} do
      assert crd["spec"]["names"]["kind"] == "ConfigBundle"
      assert crd["spec"]["names"]["shortNames"] == ["cb"]
      assert crd["spec"]["scope"] == "Namespaced"
      assert crd["spec"]["group"] == "troupe.dev"

      assert [%{"name" => "v1alpha1", "schema" => %{"openAPIV3Schema" => schema}}] =
               crd["spec"]["versions"]

      spec = schema["properties"]["spec"]

      # The document's own keys, in its own spelling, and a schema it must say.
      assert Enum.sort(Map.keys(spec["properties"])) ==
               ~w(about acp_agents agents mcp_servers schema skills)

      assert spec["required"] == ["schema"]

      # Nothing a person writes is dropped before the plane can say it is wrong.
      assert spec["x-kubernetes-preserve-unknown-fields"]

      # The limit is said where `kubectl explain` shows it.
      assert spec["description"] =~ "1 MiB"
    end

    test "fills nothing in, since a default would be content nobody committed", %{crd: crd} do
      refute defaults?(crd), "the ConfigBundle CRD has a default"
    end
  end

  defp defaults?(map) when is_map(map),
    do: Map.has_key?(map, "default") or Enum.any?(Map.values(map), &defaults?/1)

  defp defaults?(list) when is_list(list), do: Enum.any?(list, &defaults?/1)
  defp defaults?(_value), do: false
end
