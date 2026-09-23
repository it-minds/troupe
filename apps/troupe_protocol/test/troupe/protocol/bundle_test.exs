defmodule Troupe.Protocol.BundleTest do
  use ExUnit.Case, async: true

  alias Troupe.Protocol.Bundle

  @skill_md """
  ---
  name: review-checklist
  description: How we review a pull request
  ---
  Read the diff twice. The second time, read only the tests.
  """

  @reviewer """
  ---
  description: Reviews a change.
  mode: primary
  skills: [review-checklist]
  permissions:
    shell: deny
  ---
  You review code. Report what is wrong and where, and nothing else.
  """

  defp document(overrides \\ %{}) do
    Map.merge(
      %{
        "schema" => 1,
        "agents" => [%{"name" => "reviewer", "definition" => @reviewer}],
        "skills" => [
          %{
            "name" => "review-checklist",
            "description" => "How we review a pull request",
            "files" => %{"SKILL.md" => @skill_md, "checklist.md" => "- tests first\n"}
          }
        ],
        "mcp_servers" => [
          %{
            "name" => "jira",
            "url" => "https://mcp.jira.example/mcp",
            "credential_ref" => "JIRA_MCP_TOKEN",
            "permission" => "auto",
            "tools" => ["search_issues"]
          }
        ]
      },
      overrides
    )
  end

  describe "schema 1" do
    test "a well-formed document parses, and the summary names what it carries" do
      assert {:ok, bundle} = Bundle.validate(document())

      assert [%{name: "reviewer", parsed: %{mode: :primary, skills: ["review-checklist"]}}] =
               bundle.agents

      assert [%{name: "review-checklist"}] = bundle.skills
      assert [%{name: "jira", permission: :auto, tools: ["search_issues"]}] = bundle.mcp_servers

      assert Bundle.summary(bundle) == %{
               "schema" => 1,
               "agents" => ["reviewer"],
               "skills" => ["review-checklist"],
               "mcp_servers" => ["jira"],
               "acp_agents" => []
             }
    end

    test "an agent may not list a skill the bundle lacks" do
      doc = document(%{"skills" => []})
      assert {:error, [message]} = Bundle.validate(doc)
      assert message =~ "review-checklist"
    end

    test "a built-in name needs override: true" do
      build = %{"name" => "build", "definition" => "You build."}
      doc = document(%{"agents" => [build], "skills" => []})

      assert {:error, [message]} = Bundle.validate(doc, builtin_agents: ["build"])
      assert message =~ "override"

      overriding = %{build | "definition" => "---\noverride: true\n---\nYou build."}

      assert {:ok, _} =
               Bundle.validate(document(%{"agents" => [overriding], "skills" => []}),
                 builtin_agents: ["build"]
               )
    end

    test "a skill needs a SKILL.md, relative file names, and a matching name" do
      no_manifest = %{"name" => "x", "files" => %{"notes.md" => "…"}}

      assert {:error, [m1]} =
               Bundle.validate(document(%{"agents" => [], "skills" => [no_manifest]}))

      assert m1 =~ "SKILL.md"

      escaping = %{"name" => "x", "files" => %{"SKILL.md" => "hi", "../etc/passwd" => "…"}}
      assert {:error, [m2]} = Bundle.validate(document(%{"agents" => [], "skills" => [escaping]}))
      assert m2 =~ "relative"

      wrong_name = %{"name" => "x", "files" => %{"SKILL.md" => "---\nname: y\n---\nhi"}}

      assert {:error, [m3]} =
               Bundle.validate(document(%{"agents" => [], "skills" => [wrong_name]}))

      assert m3 =~ "says its name"
    end

    test "an MCP server must be https, inside egress, and reference a credential by name" do
      plain = %{"name" => "a", "url" => "http://mcp.example/mcp"}
      assert {:error, [m1]} = Bundle.validate(document(%{"mcp_servers" => [plain]}))
      assert m1 =~ "plain http"

      internal = %{"name" => "a", "url" => "http://mcp.troupe-system.svc:8080/mcp"}
      assert {:ok, _} = Bundle.validate(document(%{"mcp_servers" => [internal]}))

      outside = %{"name" => "a", "url" => "https://mcp.example/mcp"}

      assert {:error, [m2]} =
               Bundle.validate(document(%{"mcp_servers" => [outside]}),
                 egress_allowed?: fn host -> host != "mcp.example" end
               )

      assert m2 =~ "cluster policy"

      leaked = %{
        "name" => "a",
        "url" => "https://mcp.example/mcp",
        "credential_ref" => "sk-live-0123456789abcdef"
      }

      assert {:error, [m3]} = Bundle.validate(document(%{"mcp_servers" => [leaked]}))
      assert m3 =~ "does not go in a bundle"
    end

    test "names are unique per kind and unknown keys are refused" do
      twice = [
        %{"name" => "a", "url" => "https://x.example/"},
        %{"name" => "a", "url" => "https://y.example/"}
      ]

      assert {:error, [m]} = Bundle.validate(document(%{"mcp_servers" => twice}))
      assert m =~ "duplicate"

      assert {:error, [m2]} = Bundle.validate(document(%{"extra" => 1}))
      assert m2 =~ "unknown keys"
    end
  end

  describe "schema 0" do
    test "a legacy document is its mcp_servers and nothing else" do
      legacy = %{
        "agents" => ["build"],
        "mcp_servers" => [%{"name" => "n", "url" => "https://n.example/"}]
      }

      assert {:ok, %{schema: 0, agents: [], skills: [], mcp_servers: [%{name: "n"}]}} =
               Bundle.validate(legacy)
    end
  end

  test "the hash is over canonical JSON, so key order does not matter" do
    a = %{"schema" => 1, "agents" => [], "skills" => [], "mcp_servers" => []}
    b = %{"mcp_servers" => [], "skills" => [], "agents" => [], "schema" => 1}
    assert Bundle.hash(a) == Bundle.hash(b)
    assert "sha256:" <> _ = Bundle.hash(a)
  end

  test "materialise writes agents and skills once, and reads them back" do
    dir = Path.join(System.tmp_dir!(), "troupe-bundle-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, bundle} = Bundle.validate(document())
    assert :ok = Bundle.materialize(bundle, document(), dir)
    assert File.exists?(Path.join(dir, "agents/reviewer.md"))
    assert File.exists?(Path.join(dir, "skills/review-checklist/checklist.md"))
    assert File.exists?(Path.join(dir, "bundle.json"))

    # A second materialisation of the same hash is a no-op, not an overwrite.
    assert :ok = Bundle.materialize(bundle, document(), dir)

    assert {:ok, %{name: "review-checklist", body: body, files: files}} =
             Bundle.read_skill(dir, "review-checklist")

    assert body =~ "Read the diff twice"
    assert files == ["SKILL.md", "checklist.md"]
    assert {:error, :not_found} = Bundle.read_skill(dir, "../agents")

    assert [%{name: "review-checklist", description: "How we review a pull request"}] =
             Bundle.list_skills(dir)
  end

  # A materialised bundle's skills are found by globbing its directory. On Windows that
  # directory is written with backslashes, which a glob reads as escapes, and a `[` or a
  # `{` in it is read as a wildcard: either way a bundle had no skills (#98).
  for name <- ["bundle[1]", "bundle{a,b}"] do
    test "a bundle directory called #{name}, written with backslashes, lists and reads its skills" do
      base = Path.join(System.tmp_dir!(), "troupe-bundle-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(base) end)
      dir = Path.join(base, unquote(name))

      {:ok, bundle} = Bundle.validate(document())
      assert :ok = Bundle.materialize(bundle, document(), dir)

      # The directory as Windows spells it. A glob reads a backslash as a separator on
      # every host, as `Troupe.Paths` does, so under Linux this is the same directory.
      windows = String.replace(dir, "/", "\\")

      assert {:ok, %{name: "review-checklist", files: ["SKILL.md", "checklist.md"]}} =
               Bundle.read_skill(windows, "review-checklist")

      assert [%{name: "review-checklist", description: "How we review a pull request"}] =
               Bundle.list_skills(windows)
    end
  end

  describe "whose credential an MCP server uses" do
    test "profile is the default, and is what every bundle meant before there was a mode" do
      content = %{
        "schema" => 1,
        "mcp_servers" => [
          %{
            "name" => "jira",
            "url" => "https://mcp.jira.example/mcp",
            "credential_ref" => "JIRA_MCP_TOKEN"
          }
        ]
      }

      assert {:ok, %{mcp_servers: [server]}} = Bundle.validate(content)
      assert server.credential_mode == :profile
      assert server.credential_ref == "JIRA_MCP_TOKEN"
    end

    test "person mode reads credential_ref as a slot, defaulting to the server's name" do
      assert {:ok, %{mcp_servers: [jira, pager]}} =
               Bundle.validate(%{
                 "schema" => 1,
                 "mcp_servers" => [
                   %{
                     "name" => "jira",
                     "url" => "https://mcp.jira.example/mcp",
                     "credential_mode" => "person"
                   },
                   %{
                     "name" => "pager",
                     "url" => "https://mcp.pager.example/mcp",
                     "credential_mode" => "person",
                     "credential_ref" => "on-call"
                   }
                 ]
               })

      assert jira.credential_mode == :person
      assert jira.credential_ref == "jira"
      assert pager.credential_ref == "on-call"
    end

    test "a slot is a name under a person, not an environment variable" do
      assert {:error, [reason]} =
               Bundle.validate(%{
                 "schema" => 1,
                 "mcp_servers" => [
                   %{
                     "name" => "jira",
                     "url" => "https://mcp.jira.example/mcp",
                     "credential_mode" => "person",
                     "credential_ref" => "JIRA_MCP_TOKEN"
                   }
                 ]
               })

      assert reason =~ "is not a slot name"

      # And nothing that could be a path segment separator, because the slot becomes one.
      assert {:error, [escaped]} =
               Bundle.validate(%{
                 "schema" => 1,
                 "mcp_servers" => [
                   %{
                     "name" => "jira",
                     "url" => "https://mcp.jira.example/mcp",
                     "credential_mode" => "person",
                     "credential_ref" => "../other"
                   }
                 ]
               })

      assert escaped =~ "is not a slot name"
    end

    test "a mode that is neither is refused with both names" do
      assert {:error, [reason]} =
               Bundle.validate(%{
                 "schema" => 1,
                 "mcp_servers" => [
                   %{
                     "name" => "jira",
                     "url" => "https://mcp.jira.example/mcp",
                     "credential_mode" => "whoever"
                   }
                 ]
               })

      assert reason =~ "is not profile or person"
    end
  end
end
