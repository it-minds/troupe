defmodule Troupe.Plane.ConsoleAssetsTest do
  @moduledoc """
  The console's document asks for files, and those files exist and are served.

  This suite exists because they did not. `root.ex` had named
  `/admin/static/app.js` since the panel was written; there was no `app.js`, no
  `priv/static` directory at all, and `Plug.Static` was mounted with `only: ~w(app.css)`
  — a file that also did not exist. So the script 404'd, the LiveView socket was never
  opened, and every page of the console was a single server-rendered snapshot whose
  buttons did nothing.

  `panel_test.exs` has thirty-five interactions and could not have caught it: `live/2`
  mounts a LiveView in-process, so it never fetches the document and never asks for
  anything the document references. The gap was not a missing assertion, it was a
  missing *kind* of assertion — nothing checked the contract between the HTML and the
  file system.

  So these tests read the rendered document, extract every asset it names, and check
  each one against the static plug's allowlist and against the disk.
  """

  use ExUnit.Case, async: true

  alias Phoenix.HTML.Safe
  alias Troupe.Plane.Web.Live.Root

  @static_root Application.app_dir(:troupe_plane, "priv/static")

  defp document do
    %{inner_content: {:safe, "<main></main>"}}
    |> Root.root()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  # `/admin/static/app.js?v=0.2.0` is the reference; the file on disk is `app.js`.
  defp referenced_assets do
    ~r{/admin/static/(?<file>[A-Za-z0-9._-]+)}
    |> Regex.scan(document(), capture: ["file"])
    |> List.flatten()
    |> Enum.uniq()
  end

  test "the document references at least a stylesheet and a script" do
    assets = referenced_assets()

    assert "app.js" in assets, "the console must load LiveView's JavaScript or nothing works"
    assert Enum.any?(assets, &String.ends_with?(&1, ".css"))
  end

  test "every asset the document names exists on disk" do
    for asset <- referenced_assets() do
      path = Path.join(@static_root, asset)

      assert File.exists?(path), """
      The console's document references /admin/static/#{asset} and there is no such file.

      Generated assets are built by `mix troupe.admin.assets` and
      `mix troupe.admin.tokens`, and are committed.
      """

      assert File.stat!(path).size > 0, "#{asset} is empty"
    end
  end

  test "every asset the document names is in the static plug's allowlist" do
    # Reaching into the endpoint's compiled plug list would test Plug rather than this
    # code, so the allowlist is read from the source — which is the thing that was wrong.
    source = File.read!(Path.join(__DIR__, "../../../lib/troupe/plane/web/endpoint.ex"))
    [_all, allowed] = Regex.run(~r/only: ~w\(([^)]+)\)/, source)
    allowed = String.split(allowed, ~r/\s+/, trim: true)

    for asset <- referenced_assets() do
      assert asset in allowed, """
      /admin/static/#{asset} is referenced by the document but not in the static plug's
      `only:` list, so it is served as a 404 however present the file is.

      Allowed: #{inspect(allowed)}
      """
    end
  end

  test "the vendored script defines the socket the document needs" do
    js = File.read!(Path.join(@static_root, "app.js"))

    # The three bundles and the boot, in the order they must load.
    assert js =~ "/* phoenix */"
    assert js =~ "/* phoenix_live_view */"
    assert js =~ "LiveView.LiveSocket"
    assert js =~ ~s{socket.connect()}
  end

  test "the document carries the CSRF token the socket needs to connect" do
    assert document() =~ ~s(name="csrf-token")
  end

  describe "the stylesheet against the tokens" do
    @tokens File.read!(Path.join(@static_root, "tokens.css"))
    @console File.read!(Path.join(@static_root, "console.css"))

    test "every custom property the console uses is defined by the generated tokens" do
      defined =
        ~r/^\s*(--[a-zA-Z0-9-]+)\s*:/m
        |> Regex.scan(@tokens, capture: :all_but_first)
        |> List.flatten()
        |> MapSet.new()

      used =
        ~r/var\((--[a-zA-Z0-9-]+)\)/
        |> Regex.scan(@console, capture: :all_but_first)
        |> List.flatten()
        |> MapSet.new()

      missing = MapSet.difference(used, defined)

      assert MapSet.size(missing) == 0, """
      The console's stylesheet uses custom properties the tokens do not define, so those
      rules silently do nothing:

      #{missing |> MapSet.to_list() |> Enum.sort() |> Enum.join("\n")}
      """
    end

    test "the console's stylesheet contains no colour of its own" do
      # The design's rule is that if something has colour it is telling you the state of
      # a thing, and the way to keep that true is for every colour to come from a token.
      # A hex code here is a colour outside the system.
      hexes = Regex.scan(~r/#[0-9a-fA-F]{3,8}\b/, @console) |> List.flatten()

      assert hexes == [], """
      #{length(hexes)} literal colour(s) in console.css: #{inspect(Enum.uniq(hexes))}

      Add a token to docs/design/admin/tokens.json and regenerate instead.
      """
    end
  end
end
