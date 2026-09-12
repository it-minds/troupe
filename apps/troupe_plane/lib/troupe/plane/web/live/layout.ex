defmodule Troupe.Plane.Web.Live.Layout do
  @moduledoc """
  The chrome every panel page sits in.

  Plain HTML and one stylesheet. A panel is a tool an operator opens when something is
  wrong, and the thing that matters then is that the page renders at all — on a phone, on
  a locked-down browser, through whatever corporate proxy stands between them and the
  cluster. Every page works with JavaScript disabled except for the live updating, which
  is the part that degrades to a refresh.
  """

  use Phoenix.Component

  @doc "The shell: navigation, who you are, and the page."
  attr(:actor, :map, required: true)
  attr(:page, :atom, required: true)
  slot(:inner_block, required: true)

  def shell(assigns) do
    ~H"""
    <main>
      <header>
        <strong>troupe</strong>
        <nav>
          <.tab page={@page} this={:overview} href="/admin">overview</.tab>
          <.tab page={@page} this={:workers} href="/admin/workers">workers</.tab>
          <.tab page={@page} this={:teams} href="/admin/teams">teams</.tab>
          <.tab page={@page} this={:sessions} href="/admin/sessions">sessions</.tab>
          <.tab page={@page} this={:bundles} href="/admin/bundles">bundles</.tab>
          <.tab page={@page} this={:triggers} href="/admin/triggers">triggers</.tab>
          <.tab page={@page} this={:audit} href="/admin/audit">audit</.tab>
        </nav>
        <span class="who">
          {@actor.subject} · {role_name(@actor.role)}
        </span>
      </header>

      <section>
        {render_slot(@inner_block)}
      </section>
    </main>
    """
  end

  attr(:page, :atom, required: true)
  attr(:this, :atom, required: true)
  attr(:href, :string, required: true)
  slot(:inner_block, required: true)

  defp tab(assigns) do
    ~H"""
    <a href={@href} class={if @page == @this, do: "here"}>{render_slot(@inner_block)}</a>
    """
  end

  @doc "A condition as the operator set it, rendered so its status is readable at a glance."
  attr(:conditions, :list, default: [])

  def conditions(assigns) do
    ~H"""
    <ul class="conditions">
      <li :for={condition <- @conditions} class={condition_class(condition)}>
        {condition["type"]}
        <span :if={condition["message"]}>— {condition["message"]}</span>
      </li>
      <li :if={@conditions == []} class="none">no conditions reported</li>
    </ul>
    """
  end

  defp condition_class(%{"type" => type, "status" => "True"}) when type in ["Ready"], do: "good"
  defp condition_class(%{"status" => "True"}), do: "bad"
  defp condition_class(_condition), do: "neutral"

  @doc "Bytes, for a person."
  @spec bytes(integer() | nil) :: String.t()
  def bytes(nil), do: "—"
  def bytes(count) when count < 1024, do: "#{count} B"
  def bytes(count) when count < 1024 * 1024, do: "#{Float.round(count / 1024, 1)} KiB"

  def bytes(count) when count < 1024 * 1024 * 1024,
    do: "#{Float.round(count / 1024 / 1024, 1)} MiB"

  def bytes(count), do: "#{Float.round(count / 1024 / 1024 / 1024, 2)} GiB"

  @doc "Micros, as money."
  @spec money(integer() | nil) :: String.t()
  def money(nil), do: "—"
  def money(0), do: "unlimited"
  def money(micros), do: "#{Float.round(micros / 1_000_000, 2)}"

  @doc "A role, as a person would say it."
  @spec role_name(atom()) :: String.t()
  def role_name(:platform_admin), do: "platform admin"
  def role_name(:team_admin), do: "team admin"
  def role_name(_role), do: "no role"
end
