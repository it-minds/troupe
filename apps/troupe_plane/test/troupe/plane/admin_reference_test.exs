defmodule Troupe.Plane.AdminReferenceTest do
  @moduledoc """
  `mix troupe.admin.reference` writes PROTOCOL.md's admin method table from the methods'
  declarations, and fails `--check` when the committed table is not what they render.
  """

  use ExUnit.Case, async: false

  alias Mix.Tasks.Troupe.Admin.Reference
  alias Troupe.Plane.Admin.API
  alias Troupe.Plane.Admin.API.{Argument, Method}

  @protocol Path.expand("../../../../../PROTOCOL.md", __DIR__)

  @methods [
    %Method{
      name: "admin.thing.put",
      function: :thing_put,
      role: :platform_admin,
      risk: :write,
      summary: "Put a thing for team:<name>, a | b, `code | span`, owner/* too.",
      arguments: [
        %Argument{name: "name", type: :string, required: true, description: "Its name."},
        %Argument{
          name: "attrs",
          type: :object,
          description: "What it is.",
          properties: [
            %Argument{name: "size", type: :string, values: ["small", "large"], description: "How big."},
            %Argument{name: "count", type: :integer, description: "How many."}
          ]
        }
      ]
    },
    %Method{
      name: "admin.thing.delete",
      function: :thing_delete,
      risk: :destructive,
      confirm: "name",
      summary: "Remove a thing.",
      arguments: [%Argument{name: "name", type: :string, required: true, description: "Its name."}]
    },
    %Method{name: "admin.things.list", function: :things_list, summary: "Every thing."}
  ]

  @expected """
  | method | role | risk | takes | what it does |
  | --- | --- | --- | --- | --- |
  | `admin.thing.delete` | either | destructive, confirm `name` | `{name: string}` | Remove a thing. |
  | `admin.thing.put` | platform | write | `{name: string, attrs?: {size?: small/large, count?: integer}}` | Put a thing for team:&lt;name>, a \\| b, `code \\| span`, owner/\\* too. |
  | `admin.things.list` | either | read | `{}` | Every thing. |
  """

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    dir = Path.join(System.tmp_dir!(), "admin-reference-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "a fixture list of methods renders as the expected table, sorted by name" do
    assert Reference.render(@methods) == @expected
  end

  test "the table goes between the markers and the hand-written text around it stays" do
    page = "before\n<!-- admin-methods:begin -->\nold\n<!-- admin-methods:end -->\nafter\n"

    assert Reference.splice(page, @expected) ==
             "before\n<!-- admin-methods:begin -->\n" <> @expected <> "<!-- admin-methods:end -->\nafter\n"
  end

  test "--check fails on a stale table and passes once it is written", %{dir: dir} do
    page = Path.join(dir, "PROTOCOL.md")
    File.write!(page, "# Page\n\n<!-- admin-methods:begin -->\n| stale |\n<!-- admin-methods:end -->\n")

    assert_raise Mix.Error, ~r/stale/, fn ->
      Reference.run(["--check", "--page", page])
    end

    Reference.run(["--page", page])
    assert File.read!(page) =~ "| `admin.overview` | either | read | `{}` |"

    Reference.run(["--check", "--page", page])
    assert_received {:mix_shell, :info, ["wrote the admin method table" <> _]}
    assert_received {:mix_shell, :info, [current]}
    assert current =~ "is current"
  end

  test "a page without the markers is refused rather than written", %{dir: dir} do
    page = Path.join(dir, "PROTOCOL.md")
    File.write!(page, "# Page\n")

    assert_raise Mix.Error, ~r/admin-methods:begin/, fn ->
      Reference.run(["--page", page])
    end
  end

  test "the committed PROTOCOL.md carries the table the methods render" do
    page = File.read!(@protocol)

    assert Reference.splice(page, Reference.render(API.list())) == page,
           "PROTOCOL.md's admin method table is stale: run `mix troupe.admin.reference` and commit it"
  end
end
