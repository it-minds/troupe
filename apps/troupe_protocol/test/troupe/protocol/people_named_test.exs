defmodule Troupe.Protocol.PeopleNamedTest do
  @moduledoc """
  Every event that names a person by subject carries their name beside it.

  A subject is often an opaque id or an email; a client shows a person by name, and falls
  back to the subject only where no name was known. The guard is over both halves of the
  promise: the shapes the server validates against, and the table in `PROTOCOL.md` a
  client is written from. An event type that gains a `subject` without a `display_name`
  fails here before a client has to show the subject.
  """

  use ExUnit.Case, async: true

  alias Troupe.Protocol.Event.Actor
  alias Troupe.Protocol.Schema

  @protocol Path.expand("../../../../../PROTOCOL.md", __DIR__)

  test "each event shape with a subject has a display_name beside it" do
    shapes = Map.merge(Schema.events(), Schema.ephemeral_events())

    unnamed =
      for {type, shape} <- shapes,
          Map.has_key?(shape, "subject"),
          not Map.has_key?(shape, "display_name"),
          do: type

    assert unnamed == []
    # The guard is about something: there are such events.
    assert Enum.any?(shapes, fn {_type, shape} -> Map.has_key?(shape, "subject") end)
  end

  test "each row of PROTOCOL.md's event table that lists subject lists display_name" do
    rows =
      @protocol
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "| `"))
      |> Enum.map(&String.split(&1, "|", parts: 3))
      |> Enum.flat_map(fn
        ["", type, data] -> [{String.trim(type), data}]
        _ -> []
      end)
      |> Enum.filter(fn {type, data} ->
        Enum.any?(event_types(type), &Map.has_key?(Schema.events(), &1)) and
          data =~ ~r/^\s*`subject`/
      end)

    assert rows != []

    for {type, data} <- rows do
      assert data =~ "`display_name`", "#{type} lists `subject` and not `display_name`"
    end
  end

  test "the actor every event carries names the person where the connection knew a name" do
    assert Actor.to_json(Actor.user("idp|7f3a", "Alice Example")) ==
             %{"kind" => "user", "subject" => "idp|7f3a", "display_name" => "Alice Example"}

    assert Actor.to_json(Actor.user("idp|7f3a")) == %{"kind" => "user", "subject" => "idp|7f3a"}
  end

  # A row's first cell, `acl_granted` / `acl_revoked`, as the type names it lists.
  defp event_types(cell) do
    ~r/`([a-z_]+)`/
    |> Regex.scan(cell)
    |> Enum.map(fn [_, name] -> name end)
  end
end
