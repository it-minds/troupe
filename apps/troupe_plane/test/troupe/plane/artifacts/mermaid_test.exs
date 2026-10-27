defmodule Troupe.Plane.Artifacts.MermaidTest do
  @moduledoc """
  A flowchart's edges drawn as their operator says (#62): a dot in an inline label's text is
  the label's, not the edge's, so `-- v1.2 -->` is a solid arrow and only `-.->` is dotted.
  """

  use ExUnit.Case, async: true

  alias Troupe.Plane.Artifacts.Mermaid

  test "a dot inside an inline label leaves the edge solid, and the label whole" do
    assert {:ok, svg} = Mermaid.render("graph LR\n  a -- v1.2 --> b")
    refute svg =~ "m-dotted"
    assert svg =~ "marker-end"
    assert svg =~ ">v1.2</text>"
  end

  test "a dotted edge is dotted, with an inline label or a piped one" do
    assert {:ok, dotted} = Mermaid.render("graph LR\n  a -.-> b")
    assert dotted =~ "m-dotted"

    assert {:ok, piped} = Mermaid.render("graph LR\n  a -.->|v1.2| b")
    assert piped =~ "m-dotted"
    assert piped =~ ">v1.2</text>"
  end

  test "a thick edge with a dot in its label stays thick" do
    assert {:ok, svg} = Mermaid.render("graph LR\n  a == v1.2 ==> b")
    refute svg =~ "m-dotted"
    assert svg =~ ">v1.2</text>"
  end
end
