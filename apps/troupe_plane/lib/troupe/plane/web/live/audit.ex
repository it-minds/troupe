defmodule Troupe.Plane.Web.Live.Audit do
  @moduledoc """
  Who changed what, with the diff.

  The page somebody opens when a thing is not as they left it. Newest first, because that
  is almost always the answer, and narrowable by actor and subject because the second
  question is "what else did they do".

  ## And whether any of it is still true

  A table of rows is exactly as trustworthy as the database it sits in. Somebody who can
  write to PostgreSQL can change what a record says happened, and a trail that could not
  answer that is a trail that answers the easy questions only.

  So the integrity check is on this page rather than in a runbook: it walks the chain,
  says how far back the chain reaches, and — when a row does not verify — names *that row*
  with what it claims and what it actually hashes to. "The trail is wrong" is not something
  anybody can act on; "this row, at this time, by this actor" is.

  It is run on request rather than on load. The walk reads the whole trail, and a page that
  did it every time somebody filtered by actor would be a page nobody opens.
  """

  use Phoenix.LiveView, layout: false

  import Troupe.Plane.Web.Live.Layout

  alias Troupe.Plane.Admin

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(filter: %{}, integrity: nil) |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("filter", params, socket) do
    filter =
      %{}
      |> put_present(:actor, params["actor"])
      |> put_present(:kind, params["kind"])
      |> put_present(:subject_id, params["subject_id"])

    {:noreply, socket |> assign(filter: filter) |> load()}
  end

  # On request. The walk reads the whole trail, and a check that ran on every keystroke in
  # the filter would be a page nobody opens.
  def handle_event("verify", _params, socket) do
    case Admin.audit_verify(socket.assigns.actor) do
      {:ok, integrity} -> {:noreply, assign(socket, integrity: integrity, error: nil)}
      {:error, error} -> {:noreply, assign(socket, integrity: nil, error: error.message)}
    end
  end

  defp put_present(filter, _key, value) when value in [nil, ""], do: filter
  defp put_present(filter, key, value), do: Map.put(filter, key, value)

  defp load(socket) do
    case Admin.audit_list(socket.assigns.actor, Enum.to_list(socket.assigns.filter)) do
      {:ok, events} -> assign(socket, events: events, error: nil)
      {:error, error} -> assign(socket, events: [], error: error.message)
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.shell actor={@actor} breakglass={@breakglass} page={:audit}>
      <p :if={@error} class="error">{@error}</p>

      <form id="audit-filter" phx-change="filter">
        <label>actor <input name="actor" value={@filter[:actor]} /></label>
        <label>kind <input name="kind" value={@filter[:kind]} /></label>
        <label>subject <input name="subject_id" value={@filter[:subject_id]} /></label>
      </form>

      <section :if={@actor.role == :platform_admin} class="panel">
        <h2>Integrity</h2>
        <p class="hint">
          Every row carries a digest of its own content and of the row before it. This
          recomputes both, from what is stored, and stops at the first one that does not
          match. It changes nothing.
        </p>

        <form id="audit-verify" phx-submit="verify">
          <button type="submit">check the chain</button>
        </form>

        <div :if={@integrity} class="ceilings">
          <div class="ceiling">
            <h3 :if={@integrity.result == :ok and @integrity.checked > 0}>
              The chain verifies
              <span class="rung rung--platform">{@integrity.checked} rows</span>
            </h3>

            <h3 :if={@integrity.result == :ok and @integrity.checked == 0}>
              Nothing is chained yet
              <span class="rung rung--deployment">{@integrity.unchained} rows covered by nothing</span>
            </h3>

            <h3 :if={@integrity.result != :ok}>
              A row does not verify
              <span class="rung rung--deployment">{reason_of(@integrity.result)}</span>
            </h3>

            <p :if={@integrity.checked == 0} class="field-help">
              Every row here was written before the chain existed. They are left alone on
              purpose: rewriting them with hashes computed now would be a trail claiming to
              be verified back to a row nothing verified. The chain starts at the next
              change somebody makes.
            </p>

            <p class="micro">
              checked {@integrity.checked} chained
              {if @integrity.unchained > 0,
                do: "· #{@integrity.unchained} written before the chain existed and covered by nothing",
                else: "· every row is chained"}
              {if @integrity.from, do: "· back to #{@integrity.from}", else: ""}
            </p>

            <div :if={@integrity.result != :ok}>
              <p>
                <strong>{bad_row(@integrity.result).action}</strong>
                on {bad_row(@integrity.result).subject_id || "—"}
                by {bad_row(@integrity.result).actor},
                at {bad_row(@integrity.result).occurred_at}.
              </p>

              <p class="field-help">
                It says its digest is
                <code>{short(bad_row(@integrity.result).recorded_hash)}</code>
                and its content hashes to
                <code>{short(bad_row(@integrity.result).computed_hash)}</code>.
                Everything before this row still verifies; nothing after it can be trusted
                until this is explained.
              </p>
            </div>
          </div>
        </div>
      </section>

      <table>
        <thead>
          <tr>
            <th>when</th>
            <th>who</th>
            <th>what</th>
            <th>to</th>
            <th>changes</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={event <- @events}>
            <td>{event.occurred_at}</td>
            <td>{event.actor}</td>
            <td>{event.action}</td>
            <td>{event.subject_id}</td>
            <td><pre>{render_detail(event.detail)}</pre></td>
          </tr>
          <tr :if={@events == []}>
            <td colspan="5">nothing recorded</td>
          </tr>
        </tbody>
      </table>
    </.shell>
    """
  end

  # Two failures, said apart because the repairs differ: a row whose content no longer
  # hashes to what it claims has been altered, and a row whose predecessor is not the one
  # that was there means something was removed or inserted.
  defp reason_of({:error, %{reason: :altered}}), do: "altered"
  defp reason_of({:error, %{reason: :chain_broken}}), do: "a row is missing or inserted"
  defp reason_of(_other), do: "unverified"

  defp bad_row({:error, row}), do: row

  defp short(nil), do: "—"
  defp short("sha256:" <> hex), do: String.slice(hex, 0, 12)
  defp short(hash), do: String.slice(hash, 0, 12)

  # A diff reads better as `field: from → to` than as JSON, and an audit page is read by
  # somebody in a hurry.
  defp render_detail(detail) when detail == %{}, do: "—"

  defp render_detail(detail) do
    Enum.map_join(detail, "\n", fn
      {field, %{"from" => from, "to" => to}} -> "#{field}: #{inspect(from)} → #{inspect(to)}"
      {field, value} -> "#{field}: #{inspect(value)}"
    end)
  end
end
