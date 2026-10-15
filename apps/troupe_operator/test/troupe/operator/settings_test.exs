defmodule Troupe.Operator.SettingsTest do
  @moduledoc """
  What the chart sets reaches the operator: `config/runtime.exs` as a release reads it, in
  the environment the chart's Deployment gives the operator.

  The worker container's seccomp profile above all, because a pod under the runtime's
  default refuses every command (bubblewrap cannot make its user namespace), and a profile
  the kubelet does not take is a pod that never starts, said only in an event on its
  StatefulSet.
  """

  # The process environment is global.
  use ExUnit.Case, async: false

  alias Troupe.Operator.Settings

  describe "the worker's seccomp profile" do
    test "is the runtime's default when the chart says nothing" do
      settings =
        read(%{"TROUPE_WORKER_SECCOMP_TYPE" => nil, "TROUPE_WORKER_SECCOMP_PROFILE" => nil})

      assert settings.worker_seccomp_type == "RuntimeDefault"
      assert Settings.worker_seccomp(settings) == %{"type" => "RuntimeDefault"}
    end

    test "is the chart's Localhost profile, with its path" do
      settings =
        read(%{
          "TROUPE_WORKER_SECCOMP_TYPE" => "Localhost",
          "TROUPE_WORKER_SECCOMP_PROFILE" => "troupe/worker.json"
        })

      assert Settings.worker_seccomp(settings) == %{
               "type" => "Localhost",
               "localhostProfile" => "troupe/worker.json"
             }
    end

    test "is Unconfined where the chart chose it, with no path to read" do
      settings =
        read(%{
          "TROUPE_WORKER_SECCOMP_TYPE" => "Unconfined",
          "TROUPE_WORKER_SECCOMP_PROFILE" => ""
        })

      assert Settings.worker_seccomp(settings) == %{"type" => "Unconfined"}
    end

    test "stops the operator at boot when it is no profile the kubelet takes" do
      assert_raise RuntimeError, ~r/Localhost, RuntimeDefault or Unconfined/, fn ->
        read(%{
          "TROUPE_WORKER_SECCOMP_TYPE" => "unconfined",
          "TROUPE_WORKER_SECCOMP_PROFILE" => nil
        })
      end

      assert_raise RuntimeError, ~r/TROUPE_WORKER_SECCOMP_PROFILE names no profile/, fn ->
        read(%{
          "TROUPE_WORKER_SECCOMP_TYPE" => "Localhost",
          "TROUPE_WORKER_SECCOMP_PROFILE" => ""
        })
      end
    end
  end

  describe "the worker's AppArmor profile" do
    test "is the profile the chart names, as Localhost" do
      settings = read(%{"TROUPE_WORKER_APPARMOR_PROFILE" => "troupe-worker"})

      assert Settings.worker_apparmor(settings) == %{
               "type" => "Localhost",
               "localhostProfile" => "troupe-worker"
             }
    end

    test "is none, the runtime's default, when the chart names none" do
      assert Settings.worker_apparmor(read(%{"TROUPE_WORKER_APPARMOR_PROFILE" => nil})) == nil
      assert Settings.worker_apparmor(read(%{"TROUPE_WORKER_APPARMOR_PROFILE" => ""})) == nil
    end

    test "stops the operator at boot when it is no name a kubelet takes" do
      for name <- ["unconfined/x", "../troupe-worker", "-x", "two words"] do
        assert_raise RuntimeError, ~r/TROUPE_WORKER_APPARMOR_PROFILE/, fn ->
          read(%{"TROUPE_WORKER_APPARMOR_PROFILE" => name})
        end
      end
    end
  end

  describe "a user namespace for each worker pod" do
    test "is what the chart says, and off when it says nothing" do
      assert read(%{"TROUPE_WORKER_USER_NAMESPACES" => "true"}).worker_user_namespaces == true
      assert read(%{"TROUPE_WORKER_USER_NAMESPACES" => "false"}).worker_user_namespaces == false
      assert read(%{"TROUPE_WORKER_USER_NAMESPACES" => nil}).worker_user_namespaces == false
    end
  end

  describe "the plane's CA for the pods" do
    test "is where the chart mounts it, and none when it mounts none" do
      path = "/etc/troupe/plane-control-ca/ca.crt"
      assert read(%{"TROUPE_PLANE_CONTROL_CA" => path}).plane_ca_path == path
      assert read(%{"TROUPE_PLANE_CONTROL_CA" => ""}).plane_ca_path == nil
      assert read(%{"TROUPE_PLANE_CONTROL_CA" => nil}).plane_ca_path == nil
    end

    @tag :tmp_dir
    test "is read as its certificates alone, whatever else the file holds", %{tmp_dir: dir} do
      %{cert: cert, key: key} =
        :public_key.pkix_test_root_cert(~c"troupe-plane-control-ca", [
          {:key, {:namedCurve, :secp256r1}}
        ])

      path = Path.join(dir, "ca.crt")
      certificate = {:Certificate, cert, :not_encrypted}

      key_entry = {:ECPrivateKey, :public_key.der_encode(:ECPrivateKey, key), :not_encrypted}
      File.write!(path, :public_key.pem_encode([certificate, key_entry]))

      settings = Settings.with_plane_ca(%Settings{plane_ca_path: path})
      assert settings.plane_ca == :public_key.pem_encode([certificate])
      refute settings.plane_ca =~ "PRIVATE KEY"
    end

    @tag :tmp_dir
    test "is none where the file is not there yet, or holds no certificate", %{tmp_dir: dir} do
      missing = Path.join(dir, "not-mounted/ca.crt")
      assert Settings.with_plane_ca(%Settings{plane_ca_path: missing}).plane_ca == nil

      empty = Path.join(dir, "ca.crt")
      File.write!(empty, "")
      assert Settings.with_plane_ca(%Settings{plane_ca_path: empty}).plane_ca == nil

      assert Settings.with_plane_ca(%Settings{plane_ca: "stale"}).plane_ca == nil
    end
  end

  # `config/runtime.exs` read as a release reads it, with `vars` set (a `nil` unset) and put
  # back afterwards, and the operator's settings out of it.
  defp read(vars) do
    previous = Map.new(vars, fn {name, _value} -> {name, System.get_env(name)} end)
    Enum.each(vars, fn {name, value} -> put_env(name, value) end)

    try do
      config =
        "../../../../../config/runtime.exs"
        |> Path.expand(__DIR__)
        |> Config.Reader.read!(env: :prod, target: :host)

      struct(Settings, config[:troupe_operator][:settings])
    after
      Enum.each(previous, fn {name, value} -> put_env(name, value) end)
    end
  end

  defp put_env(name, nil), do: System.delete_env(name)
  defp put_env(name, value), do: System.put_env(name, value)
end
