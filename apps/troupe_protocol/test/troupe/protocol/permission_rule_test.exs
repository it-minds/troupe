defmodule Troupe.Protocol.PermissionRuleTest do
  @moduledoc "One per-tool rule as a file writes it (#658)."

  use ExUnit.Case, async: true

  alias Troupe.Protocol.PermissionRule

  test "a tool alone, or with a pattern its kind takes" do
    assert {:ok, %{tool: "shell", pattern: nil, text: "shell"}} = PermissionRule.parse("shell")
    assert {:ok, %{tool: "shell", pattern: nil}} = PermissionRule.parse("shell(*)")

    assert {:ok, %{tool: "shell", pattern: "git push --force", text: "shell(git push --force)"}} =
             PermissionRule.parse("  shell( git   push  --force )")

    assert {:ok, %{pattern: "git push*"}} = PermissionRule.parse("shell(git push*)")
    assert {:ok, %{pattern: "git push *"}} = PermissionRule.parse("shell(git push *)")

    assert {:ok, %{tool: "read_file", pattern: "secrets/**"}} =
             PermissionRule.parse("read_file(./secrets/**)")

    assert {:ok, %{pattern: "C:/keys/**"}} = PermissionRule.parse("read_file(C:\\keys\\**)")

    assert {:ok, %{tool: "mcp", pattern: "github.create_*"}} =
             PermissionRule.parse("mcp(github.create_*)")

    assert {:ok, %{tool: "mcp", pattern: "github"}} = PermissionRule.parse("mcp(github)")
    assert {:ok, %{tool: "web_fetch", pattern: nil}} = PermissionRule.parse("web_fetch")
  end

  test "a malformed rule is refused with what to write instead" do
    for {text, says} <- [
          {"", "names a tool"},
          {"shell(git push", "does not close"},
          {"Bash(npm test)", "Troupe's is shell"},
          {"WebFetch", "Troupe's is web_fetch"},
          {"Grep", "lower case: grep"},
          {"mcp.github.create_issue", "mcp(github.create_issue)"},
          {"client.notes.search", "mcp(notes.search)"},
          {"shell()", "empty pattern"},
          {"shell(git * --force)", "may only end"},
          {"shell(npm test:*)", "drop the :*"},
          {"web_fetch(example.com)", "takes no pattern"},
          {"mcp(git hub)", "server.tool"}
        ] do
      assert {:error, why} = PermissionRule.parse(text), text
      assert why =~ says, "#{text}: #{why}"
    end

    assert {:error, _} = PermissionRule.parse(42)
  end

  test "the more specific rule is the one with a pattern, then the longer one" do
    {:ok, bare} = PermissionRule.parse("shell")
    {:ok, git} = PermissionRule.parse("shell(git)")
    {:ok, push} = PermissionRule.parse("shell(git push*)")

    assert PermissionRule.specificity(bare) < PermissionRule.specificity(git)
    assert PermissionRule.specificity(git) < PermissionRule.specificity(push)
  end

  test "a set is allow, ask and deny, each a list of rules" do
    assert {:ok, _set} = PermissionRule.check_set(%{"deny" => ["shell"], "allow" => nil})
    assert {:error, [_]} = PermissionRule.check_set(%{"deny" => "shell"})
    assert {:error, [_, _]} = PermissionRule.check_set(%{"deny" => ["Bash", "shell()"]})
    assert {:error, [_]} = PermissionRule.check_set(["shell"])
  end

  # The console's rules editor checks a rule with its own reading of this module, held to
  # the same cases, so a rule it accepts is one the plane accepts, refused in the same words.
  @cases_file Path.expand("../../support/permission_rules.json", __DIR__)
  @external_resource @cases_file
  @cases @cases_file |> File.read!() |> Jason.decode!()

  test "every rule and set the console's editor is held to reads as it says" do
    for %{"text" => text} = case <- @cases["rules"] do
      case case do
        %{"reads" => reads} -> assert {:ok, %{text: ^reads}} = PermissionRule.parse(text), text
        %{"refused" => why} -> assert {:error, ^why} = PermissionRule.parse(text), text
      end
    end

    for %{"set" => set, "refused" => reasons} <- @cases["sets"] do
      case reasons do
        [] -> assert {:ok, _set} = PermissionRule.check_set(set)
        reasons -> assert {:error, ^reasons} = PermissionRule.check_set(set)
      end
    end
  end
end
