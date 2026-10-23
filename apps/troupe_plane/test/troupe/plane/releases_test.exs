defmodule Troupe.Plane.ReleasesTest do
  @moduledoc """
  A release mirrored into the plane's object store (#657): its manifest checked against the
  release keys before anything is copied, each file held to the manifest, the manifest
  written last, and `/downloads` handing out what was copied. `admin.releases.mirror` and
  `admin.releases.list`, audited.

  Against the development object store, for real; GitHub is a stand-in serving the shared
  release vectors (`test/fixtures/release`), signed by the throwaway test key, which this
  suite hands the mirror in place of the release keys.
  """

  use Troupe.Plane.DataCase, async: false

  import Phoenix.ConnTest

  alias Troupe.ObjectStore
  alias Troupe.Plane.{Audit, Releases}
  alias Troupe.Plane.Admin.API
  alias Troupe.Release.Minisign

  @endpoint Troupe.Plane.Web.Endpoint

  @fixtures Path.expand("../../../../../test/fixtures/release", __DIR__)
  @version "9.9.9-test"
  @artifact "troupe-9.9.9-test-linux_x86_64"

  @root %{subject: "root@example.test", role: :platform_admin, teams: []}
  @lead %{subject: "lead@example.test", role: :team_admin, teams: ["engineering"]}

  setup do
    {:ok, current} =
      Minisign.parse_public_key(File.read!(Path.join(@fixtures, "keys/current.pub")))

    store = ObjectStore.from_env()
    clear = fn -> ObjectStore.delete_prefix(store, "releases/v#{@version}/") end
    clear.()

    before = Application.get_env(:troupe_plane, :releases, [])
    Application.put_env(:troupe_plane, :releases, keys: [current], req: [plug: &github/1])

    start_supervised!({Task.Supervisor, name: Troupe.Plane.Releases.Tasks})
    start_supervised!({Registry, keys: :unique, name: Troupe.Plane.Releases.Copies})

    on_exit(fn ->
      Application.put_env(:troupe_plane, :releases, before)
      clear.()
    end)

    %{store: store, key: current}
  end

  # GitHub's release downloads, as `<source>/v<version>/<file>`: the signed release under
  # its own version, and beside it the ways a release goes wrong.
  defp github(conn) do
    case String.split(conn.request_path, "/", trim: true) do
      [_owner, _repo, "releases", "download", tag, file] -> serve(conn, tag, file)
      _other -> Plug.Conn.send_resp(conn, 404, "")
    end
  end

  defp serve(conn, "v" <> @version, file), do: file(conn, release(file))

  # The same signed release served under a newer number.
  defp serve(conn, "v9.9.10-test", file), do: file(conn, release(file))

  defp serve(conn, _tag, _file), do: Plug.Conn.send_resp(conn, 404, "")

  defp release("manifest.json"), do: "manifest.json"
  defp release("manifest.json.minisig"), do: "signatures/current.minisig"
  defp release(@artifact), do: "artifacts/#{@artifact}"
  defp release(_other), do: nil

  defp file(conn, nil), do: Plug.Conn.send_resp(conn, 404, "")

  defp file(conn, path),
    do: Plug.Conn.send_resp(conn, 200, File.read!(Path.join(@fixtures, path)))

  describe "check" do
    test "takes a manifest the release keys signed, for the version asked for", context do
      assert {:ok, %{manifest: manifest}} = Releases.check(@version)
      assert manifest.version == @version
      assert [%{file: @artifact}] = manifest.artifacts

      # Nothing is copied by a check.
      assert {:ok, []} = ObjectStore.list(context.store, "releases/v#{@version}/")
    end

    test "refuses a manifest signed by another key, one changed after it was signed, one of another version, and none" do
      {:ok, other} = Minisign.parse_public_key(File.read!(Path.join(@fixtures, "keys/other.pub")))

      assert {:error, why} = Releases.check(@version, keys: [other])
      assert why =~ "which this build does not trust"
      assert why =~ "it is not the release key's, and nothing is mirrored"

      tampered = fn conn ->
        if String.ends_with?(conn.request_path, "/manifest.json"),
          do: file(conn, "manifest-tampered.json"),
          else: github(conn)
      end

      assert {:error, why} = Releases.check(@version, req: [plug: tampered])
      assert why =~ "changed after it was signed"

      # An older signed manifest served under a newer number.
      assert {:error, why} = Releases.check("9.9.10-test")
      assert why =~ "is 9.9.9-test, not 9.9.10-test; nothing is mirrored"

      assert {:error, why} = Releases.check("9.9.11-test")
      assert why =~ "has no manifest.json"

      assert {:error, why} = Releases.check("not-a-version")
      assert why =~ "is not a version"
    end
  end

  describe "copy" do
    test "copies each file the manifest names and the manifest last; a file that is not the manifest's stops it",
         context do
      {:ok, checked} = Releases.check(@version)
      assert {:ok, %{files: 1, bytes: 48}} = Releases.copy(checked)

      for file <- [@artifact, "manifest.json", "manifest.json.minisig"] do
        assert {:ok, bytes} = ObjectStore.get(context.store, "releases/v#{@version}/#{file}")
        assert bytes == File.read!(Path.join(@fixtures, release(file)))
      end

      ObjectStore.delete_prefix(context.store, "releases/v#{@version}/")

      tampered = fn conn ->
        if String.ends_with?(conn.request_path, @artifact),
          do: file(conn, "tampered/#{@artifact}"),
          else: github(conn)
      end

      assert {:error, why} = Releases.copy(checked, req: [plug: tampered])
      assert why =~ "is not the file the signed manifest names"
      refute ObjectStore.exists?(context.store, "releases/v#{@version}/manifest.json")
      assert {:ok, listed} = Releases.list()
      refute Enum.any?(listed, &(&1["version"] == @version))
    end
  end

  describe "admin.releases" do
    test "a platform admin mirrors a release; it is listed, audited and handed out at /downloads",
         context do
      assert {:error, %{message: "forbidden"}} =
               API.call("admin.releases.mirror", %{"version" => @version}, @lead)

      assert {:ok, %{"version" => @version, "state" => "mirroring", "files" => 1}} =
               API.call("admin.releases.mirror", %{"version" => "v" <> @version}, @root)

      wait_until(fn ->
        ObjectStore.exists?(context.store, "releases/v#{@version}/manifest.json")
      end)

      # Either admin sees what is kept.
      assert {:ok, listed} = API.call("admin.releases.list", %{}, @lead)

      assert [%{"version" => @version, "state" => "mirrored", "files" => 3}] =
               Enum.filter(listed["releases"], &(&1["version"] == @version))

      assert listed["source"] == "https://github.com/it-minds/troupe/releases/download"

      wait_until(fn ->
        match?(
          [_],
          Audit.list(kind: "release") |> Enum.filter(&(&1.action == "release.mirrored"))
        )
      end)

      actions = Audit.list(kind: "release") |> Enum.map(& &1.action) |> Enum.sort()
      assert actions == ["release.mirror", "release.mirrored"]

      conn = build_conn() |> get("/downloads/v#{@version}/#{@artifact}")
      assert conn.status == 302
      [location] = Plug.Conn.get_resp_header(conn, "location")

      assert {:ok, %{status: 200, body: body}} =
               Req.get(location, retry: false, decode_body: false)

      assert body == File.read!(Path.join(@fixtures, "artifacts/#{@artifact}"))
    end

    test "a manifest the release keys did not sign is refused with the sentence, and nothing is copied or audited",
         context do
      {:ok, other} = Minisign.parse_public_key(File.read!(Path.join(@fixtures, "keys/other.pub")))
      Application.put_env(:troupe_plane, :releases, keys: [other], req: [plug: &github/1])

      assert {:error, %{message: "invalid_params", data: data}} =
               API.call("admin.releases.mirror", %{"version" => @version}, @root)

      assert data.reason =~ "it is not the release key's, and nothing is mirrored"
      assert {:ok, []} = ObjectStore.list(context.store, "releases/v#{@version}/")
      assert Audit.list(kind: "release") == []
    end
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("not done in time")
      true -> Process.sleep(50) && wait_until(fun, tries - 1)
    end
  end
end
