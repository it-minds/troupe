defmodule Troupe.Plane.Web.ErrorHTML do
  @moduledoc """
  What a browser sees when something has gone wrong.

  Plain text and a status, because an error page that needed the application working to
  render it is an error page that fails when it is most needed. No stack trace and no
  detail: this is reachable without authenticating, and what went wrong inside the plane
  is not something an anonymous request is owed.
  """

  use Phoenix.Component

  alias Plug.Conn.Status

  @doc false
  def render(template, _assigns) do
    status = template |> String.split(".") |> List.first()

    """
    <!DOCTYPE html>
    <html lang="en"><head><meta charset="utf-8"><title>troupe</title></head>
    <body style="font: 14px/1.6 ui-monospace, monospace; padding: 2rem;">
      <p>#{status} — #{Status.reason_phrase(String.to_integer(status))}</p>
    </body></html>
    """
  end
end
