defmodule Troupe.Plane.NamesTest do
  @moduledoc """
  People by name beside their subject, from the plane's identity record: one query for a
  whole answer, and nothing put where there is no name worth showing.
  """

  use Troupe.Plane.DataCase, async: true

  alias Troupe.Plane.{Identity, Names}

  setup do
    {:ok, _} = Identity.upsert_user(%{subject: "idp|ada", display_name: "Ada Lovelace"})
    # A record whose name is its subject again, as a break-glass sign-in leaves one.
    {:ok, _} = Identity.upsert_user(%{subject: "root", display_name: "root"})
    {:ok, _} = Identity.upsert_user(%{subject: "idp|blank", display_name: nil})
    :ok
  end

  test "of/1 answers the names it has and leaves out the rest" do
    assert Names.of(["idp|ada", "root", "idp|blank", "idp|nobody", nil, "idp|ada"]) ==
             %{"idp|ada" => "Ada Lovelace"}

    assert Names.of([]) == %{}
  end

  test "decorate/2 puts the name beside each subject a row names, string or atom keys" do
    rows = [
      %{"id" => "s-1", "owner" => "idp|ada"},
      %{"id" => "s-2", "owner" => "idp|nobody"},
      %{"id" => "s-3", "owner" => nil}
    ]

    assert Names.decorate(rows, [{"owner", "owner_name"}]) == [
             %{"id" => "s-1", "owner" => "idp|ada", "owner_name" => "Ada Lovelace"},
             %{"id" => "s-2", "owner" => "idp|nobody"},
             %{"id" => "s-3", "owner" => nil}
           ]

    assert Names.decorate(%{actor: "idp|ada", action: "x"}, actor: :actor_name) ==
             %{actor: "idp|ada", action: "x", actor_name: "Ada Lovelace"}
  end

  test "decorate/2 names several people in one row" do
    row = %{"owner" => "idp|ada", "invited_by" => "root"}

    assert Names.decorate(row, [{"owner", "owner_name"}, {"invited_by", "invited_by_name"}]) ==
             %{"owner" => "idp|ada", "invited_by" => "root", "owner_name" => "Ada Lovelace"}
  end
end
