defmodule Troupe.Gateway.SchemaTest do
  @moduledoc """
  Every method the dispatcher serves is described in `Troupe.Protocol.Schema`, and so
  published in `protocol/schema/v1/`. A method a client can call but cannot look up is
  how `agents.list` and the three `identity.*` methods went without a schema.
  """

  use ExUnit.Case, async: true

  alias Troupe.Gateway.Dispatch
  alias Troupe.Protocol.Schema

  test "every method the dispatcher serves has a published schema" do
    missing = Enum.sort(Map.keys(Dispatch.methods()) -- Map.keys(Schema.commands()))

    assert missing == [],
           "no schema for #{Enum.join(missing, ", ")}: add it to Troupe.Protocol.Schema.commands/0 " <>
             "and run `mix troupe.schema.gen`"
  end
end
