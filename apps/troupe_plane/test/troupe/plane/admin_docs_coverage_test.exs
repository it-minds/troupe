defmodule Troupe.Plane.AdminDocsCoverageTest do
  @moduledoc """
  Every method the admin API serves is named on a page under `docs/admin/`, beside the task
  it serves, so an administrator who reads those pages finds every method there is. The
  names come from `Troupe.Plane.Admin.API.list/0`, the declarations `mix troupe.admin.reference`
  renders PROTOCOL.md's table from.
  """

  use ExUnit.Case, async: true

  alias Troupe.Plane.Admin.API

  @docs Path.expand("../../../../../docs/admin", __DIR__)

  # Methods deliberately on no admin page, each with the reason. None today: a method added
  # here is one an administrator never needs to know by name.
  @undocumented %{}

  defp pages do
    @docs
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.map_join("\n", &File.read!/1)
  end

  # A name counts where it is not part of a longer one: `admin.team.unlink` inside
  # `admin.team.unlink.preview` names only the preview.
  defp named?(text, name) do
    Regex.match?(~r/(?<![a-z_.])#{Regex.escape(name)}(?![a-z_]|\.[a-z])/, text)
  end

  test "every admin method is named on an admin page, or listed here with the reason" do
    text = pages()

    missing =
      for %{name: name} <- API.list(),
          not Map.has_key?(@undocumented, name),
          not named?(text, name),
          do: name

    assert missing == [],
           "these admin methods are on no page under docs/admin/; name each beside the task it serves: " <>
             Enum.join(missing, ", ")
  end

  test "a method listed as undocumented is one the plane serves" do
    served = MapSet.new(API.list(), & &1.name)
    assert Enum.reject(Map.keys(@undocumented), &MapSet.member?(served, &1)) == []
  end

  test "a name inside a longer one does not count as naming it" do
    refute named?("run `admin.team.unlink.preview` first", "admin.team.unlink")
    assert named?("then `admin.team.unlink`.", "admin.team.unlink")
    refute named?("`troupe.admin.overview`", "admin.overview")
  end
end
