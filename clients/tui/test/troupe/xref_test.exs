defmodule Troupe.XrefTest do
  @moduledoc """
  Done item 11: the build fails if the TUI or HQ call anything but
  `Troupe.Client`.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Troupe.Xref

  test "every UI module passes the rule as the tree stands" do
    modules = Xref.ui_modules()

    assert Troupe.UI.TUI.Server in modules
    assert Troupe.UI.HQ in modules
    assert Troupe.UI.TUI.View in modules
    assert Troupe.UI.Headless.Printer in modules

    offenders = Enum.flat_map(modules, &Xref.offending_calls/1)
    assert offenders == []
  end

  test "the rule catches a UI module that reaches past the client" do
    alias Troupe.XrefFixtures.Offender

    assert [{Offender, {Troupe.Session.Dispatcher, :windows, 1}}] =
             Xref.offending_calls(Offender)
  end

  test "pure data modules a renderer needs are allowed" do
    assert Xref.offending_calls(Troupe.XrefFixtures.Renderer) == []
  end
end
