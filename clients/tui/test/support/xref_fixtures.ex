defmodule Troupe.XrefFixtures do
  @moduledoc """
  Two modules for `mix troupe.xref` to judge: one that reaches past
  `Troupe.Client` and one that only uses the client and the pure data modules a
  renderer needs.

  They are named outside `Troupe.UI` on purpose — the check finds real UI
  modules by name, and a fixture in that namespace would fail the very
  assertion it exists to support.
  """

  defmodule Offender do
    @moduledoc false
    def windows(sid), do: Troupe.Remote.Worker.whereis(sid)
    def fine(sid), do: Troupe.Client.events(sid)
  end

  defmodule Renderer do
    @moduledoc false
    def text(blocks), do: Troupe.Client.Message.text(blocks)
    def fields, do: Troupe.Settings.fields()
    def events(sid), do: Troupe.Client.events(sid)
  end
end
