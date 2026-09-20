defmodule Troupe.Plane.Web.Live.Layout do
  @moduledoc """
  The chrome every console page sits in: a nav rail, a content column, and the two
  banners that are allowed to interrupt.

  A control room, not a dashboard. The rail is a fixed 216px column at desktop widths
  and wraps above the content below 900px, where the console is in checking-in mode —
  overview, status lists and the session list stay usable, and the forms are reachable
  without being the point. Every region declares a flex basis or an auto-fit grid and
  the browser decides; nothing measures a width, because the console is server-rendered
  and patched over a live connection and layout that depends on client state is a
  liability on reconnect.

  ## The two banners

  **Console offline** is the only thing in the product driven from the browser rather
  than the server, for the obvious reason: when it matters, the server is what cannot be
  reached. `app.js` sets `data-console-offline` on the root element and CSS reveals the
  banner. It leads with what is *not* affected, which the design calls the single most
  consequential sentence here — an operator who believes the platform is down at three in
  the morning does something expensive.

  **Break-glass** says the reader is an administrator because they presented a token, not
  because anybody says they are one.
  """

  use Phoenix.Component

  @pages [
    {:overview, "Overview", "/admin"},
    {:workers, "Workers", "/admin/workers"},
    {:provisioners, "Provisioners", "/admin/provisioners"},
    {:teams, "Teams", "/admin/teams"},
    {:identity, "Identity", "/admin/identity"},
    {:provider, "Identity provider", "/admin/provider"},
    {:bundles, "Configuration bundles", "/admin/bundles"},
    {:integrations, "Integrations", "/admin/integrations"},
    {:triggers, "Triggers", "/admin/triggers"},
    {:review, "Review", "/admin/review"},
    {:sessions, "Sessions and spend", "/admin/sessions"},
    {:budgets, "Budgets", "/admin/budgets"},
    {:connections, "Connections", "/admin/connections"},
    {:audit, "Audit", "/admin/audit"},
    {:policy, "Policy", "/admin/policy"}
  ]

  @doc "Every page in the rail, in the order it appears."
  @spec pages() :: [{atom(), String.t(), String.t()}]
  def pages, do: @pages

  @doc "The shell: the rail, who you are, the banners, and the page."
  attr(:actor, :map, required: true)
  attr(:page, :atom, required: true)
  # Defaulted rather than required so a page rendered outside the console's own mount —
  # a test, a preview — does not have to know the door exists.
  attr(:breakglass, :boolean, default: false)
  slot(:inner_block, required: true)

  def shell(assigns) do
    assigns = assign(assigns, :pages, @pages)

    ~H"""
    <div class="shell">
      <nav class="rail" aria-label="Console">
        <div class="rail__brand">Troupe</div>
        <.rail_item :for={{page, label, href} <- @pages} page={@page} this={page} href={href}>
          {label}
        </.rail_item>
      </nav>

      <main class="content">
        <p class="banner banner--offline" role="status">
          <strong>Console offline.</strong>
          No answer from the plane. <strong>Sessions and workers are unaffected</strong> —
          this console going dark is not an outage of the platform. You are reading the
          values it last received; it is retrying.
        </p>

        <p :if={@breakglass} class="banner banner--breakglass">
          <strong>Break-glass session.</strong>
          You are a platform admin because you presented the break-glass token, not because
          anyone says you are one. This is in the audit log and it expires on its own.
          <a href="/admin/logout">End it now</a>
        </p>

        {render_slot(@inner_block)}

        <p class="micro" style="margin-top: var(--space-9)">
          {@actor.subject} · {role_name(@actor.role)}
          · <a href="/admin/logout">sign out</a>
        </p>
      </main>
    </div>
    """
  end

  attr(:page, :atom, required: true)
  attr(:this, :atom, required: true)
  attr(:href, :string, required: true)
  slot(:inner_block, required: true)

  defp rail_item(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class="rail__item"
      aria-current={if @page == @this, do: "page", else: "false"}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Which rung decided a value.

  Rule 1 of the console: every effective value names the rung that decided it. The chip
  lives here rather than on the Policy screen because the ladder is a property of the
  value and not of one page — a team's idle timeout carries the same claim on the Teams
  screen as it does on Policy, and two spellings of it would eventually disagree.

  **Text, not colour.** "Who decided this" is an assertion, and the design's rule that
  the console's assertions must be readable without colour applies to assertions about
  provenance exactly as it does to a health status. The class exists so a chip can be set
  apart from the number beside it, and the rung's name is in the element either way.
  """
  attr(:rung, :atom, required: true)

  def rung(assigns) do
    ~H"""
    <span class={"rung rung--#{@rung}"}>{@rung}</span>
    """
  end

  @doc """
  A labelled field grid: what a thing is configured as, readable without scrolling.

  Borrowed from the drafting sheets in the platform's own documentation, and used here
  because the answer to "what is this thing" should be in a fixed place, in the same
  order, every time.
  """
  slot(:field, required: true) do
    attr(:label, :string, required: true)
  end

  def title_block(assigns) do
    ~H"""
    <div class="title-block">
      <div :for={field <- @field} class="title-block__field">
        <span class="title-block__label">{field.label}</span>
        <span class="title-block__value">{render_slot(field)}</span>
      </div>
    </div>
    """
  end

  @doc """
  A number worth four of on Overview, and never one without a line of context.

  "14" alone is not information; the design forbids a metric with no context line, so
  the slot is required rather than optional.
  """
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  slot(:context, required: true)

  def metric(assigns) do
    ~H"""
    <div class="metric">
      <span class="metric__label">{@label}</span>
      <span class="metric__value" aria-live="polite">{@value}</span>
      <span class="metric__context">{render_slot(@context)}</span>
    </div>
    """
  end

  @doc """
  A Kubernetes condition, rendered so its status is readable at a glance.

  The console's own states are `Troupe.Plane.Web.Live.Status`; these are the cluster's,
  reported verbatim on a profile, and they keep the cluster's vocabulary rather than
  being translated into a state the cluster did not claim.
  """
  attr(:conditions, :list, default: [])

  def conditions(assigns) do
    ~H"""
    <ul class="conditions">
      <li :for={condition <- @conditions} class={condition_class(condition)}>
        {condition["type"]}
        <span :if={condition["message"]}>— {condition["message"]}</span>
      </li>
      <li :if={@conditions == []} class="muted">no conditions reported</li>
    </ul>
    """
  end

  defp condition_class(%{"type" => type, "status" => "True"}) when type in ["Ready"], do: "good"
  defp condition_class(%{"status" => "True"}), do: "bad"
  defp condition_class(_condition), do: "neutral"

  @doc """
  Bytes, for a person.

  Binary units, because what is being measured is a volume and a disk, and a reader
  comparing this against `kubectl` should see the same number.
  """
  @spec bytes(integer() | nil) :: String.t()
  def bytes(nil), do: "—"
  def bytes(count) when count < 1024, do: "#{count} B"
  def bytes(count) when count < 1024 * 1024, do: "#{Float.round(count / 1024, 1)} KiB"

  def bytes(count) when count < 1024 * 1024 * 1024,
    do: "#{Float.round(count / 1024 / 1024, 1)} MiB"

  def bytes(count), do: "#{Float.round(count / 1024 / 1024 / 1024, 2)} GiB"

  @doc """
  Micros, as money.

  Two decimal places and no unit: the unit is `kr` and it belongs in muted text beside
  the figure so the figure stays the figure, which is what `amount/1` renders. A caller
  that only needs the number — a table cell already in a column headed with the unit —
  uses this.
  """
  @spec money(integer() | nil) :: String.t()
  def money(nil), do: "—"
  def money(0), do: "unlimited"
  def money(micros), do: figure(micros)

  @doc """
  The same number, with none of `money/1`'s opinion about zero.

  `money/1` reads a zero as *no ceiling*, which is right for a ceiling and wrong for
  everything else: a team that has spent nothing was reported as having spent
  "unlimited". A ceiling and a spend are two different quantities and only one of them
  means something by being absent.
  """
  @spec figure(integer() | nil) :: String.t()
  def figure(nil), do: "—"
  def figure(micros), do: :erlang.float_to_binary(micros / 1_000_000, decimals: 2)

  @doc """
  An amount with its unit set quietly beside it, tabular so a column lines up.

  `figure/1` rather than `money/1`, because every caller renders a spend or a reservation
  and none of them renders a ceiling — a team that had spent nothing was being reported as
  having spent "unlimited" on Overview, on Teams and on Budgets, which is the one word that
  should never appear in a spend column.
  """
  attr(:micros, :integer, default: nil)

  def amount(assigns) do
    ~H"""
    <span class="mono" style="font-variant-numeric: tabular-nums">
      {figure(@micros)}<span :if={is_integer(@micros) and @micros > 0} class="muted">&nbsp;kr</span>
    </span>
    """
  end

  @doc """
  A team's spend against its ceiling: a bar, and the figures beside it in text.

  The figures are not optional. A bar alone says "quite full", which is not a number
  anybody can act on, and a bar alone is also nothing at all to a reader who cannot see
  the colour. Reserved money counts towards the fill because it is money the platform has
  already promised on this team's behalf — a team whose bar looked comfortable while its
  next session was about to be refused would be worse than no bar.
  """
  attr(:team, :map, required: true)

  def budget(assigns) do
    assigns =
      assigns
      |> assign(:committed, assigns.team.spent_micros + assigns.team.reserved_micros)
      |> then(&assign(&1, :fraction, fraction(&1.committed, &1.team.budget_micros)))

    ~H"""
    <span :if={@team.budget_micros == 0} class="muted">no ceiling</span>

    <div :if={@team.budget_micros > 0} class={"budget budget--#{level(@fraction)}"}>
      <span class="budget__track">
        <span class="budget__fill" style={"width: #{min(round(@fraction * 100), 100)}%"}></span>
      </span>
      <span class="budget__figures">
        {figure(@committed)} / {money(@team.budget_micros)} {@team.budget_period}
      </span>
    </div>
    """
  end

  defp fraction(_committed, 0), do: 0.0
  defp fraction(committed, budget), do: committed / budget

  # The three the design names, and the thresholds are the same ones Overview sorts by.
  defp level(fraction) when fraction >= 1.0, do: "over"
  defp level(fraction) when fraction >= 0.8, do: "near"
  defp level(_fraction), do: "under"

  @doc "A role, as a person would say it."
  @spec role_name(atom()) :: String.t()
  def role_name(:platform_admin), do: "platform admin"
  def role_name(:team_admin), do: "team admin"
  def role_name(_other), do: "no role"
end
