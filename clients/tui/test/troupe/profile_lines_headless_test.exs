defmodule Troupe.ProfileLinesHeadlessTest do
  @moduledoc """
  The plain lines the headless printer makes of `profile.get`'s answer, which `troupe
  profiles` prints: every group present in reading order, null fields said to be not said
  rather than filled in, the access words for each kind of server, and a long tool list
  wrapped under its server. Pure: no plane, no session.
  """

  use ExUnit.Case, async: true

  alias Troupe.UI.Headless.Printer

  @bare %{"name" => "bare"}

  test "an answer with nothing said says not said in every group" do
    lines = Printer.profile_lines(@bare)
    assert hd(lines) == "profile bare"

    for group <- ~w(Agents Tools Model Reach Limits Who), do: assert(group in lines)
    assert "  rules not said" in lines
    assert Enum.count(lines, &(&1 == "  not said")) == 3
    assert "  team         not said" in lines

    assert Printer.profiles_lines([@bare]) == [
             "bare      agents not said · reach not said · sessions not said"
           ]
  end

  test "each access is said in the person's words and a long tool list wraps" do
    tools = for n <- 1..30, do: "tool_number_#{n}"

    page = %{
      "name" => "p",
      "tools" => %{
        "rules" => [],
        "mcp" => [
          %{
            "name" => "a",
            "host" => "a.example",
            "access" => "yours",
            "permission" => "auto",
            "tools" => tools,
            "offered" => true
          },
          %{
            "name" => "b",
            "host" => "b.example",
            "access" => "profile",
            "permission" => "ask",
            "tools" => [],
            "offered" => true
          },
          %{
            "name" => "c",
            "host" => nil,
            "access" => "system",
            "permission" => nil,
            "tools" => nil,
            "offered" => true
          }
        ]
      },
      "reach" => [],
      "teams" => []
    }

    lines = Printer.profile_lines(page, 80)
    assert "    a · a.example · as you, once you connect it · automatic" in lines
    assert "    b · b.example · as the profile · asked first" in lines

    assert "    c · host not said · as the profile's own identity · asked or automatic not said" in lines

    assert "      tools: none" in lines
    assert "      tools: not said" in lines

    wrapped = Enum.filter(lines, &String.contains?(&1, "tool_number_"))
    assert length(wrapped) > 2
    assert Enum.all?(wrapped, &(String.length(&1) <= 80 and String.starts_with?(&1, "      ")))
    assert "  no host: a session here reaches nothing outside its pod" in lines
    assert "  your teams   none of your teams: those of yours that may use it" in lines
  end
end
