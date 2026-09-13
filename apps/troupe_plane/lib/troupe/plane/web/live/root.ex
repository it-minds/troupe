defmodule Troupe.Plane.Web.Live.Root do
  @moduledoc """
  The HTML document every console page is delivered inside.

  Two stylesheets and one script, all three generated and served from this release:
  `tokens.css` from `docs/design/admin/tokens.json`, `console.css` written against those
  tokens, and `app.js` vendored from the Phoenix dependencies. Nothing is fetched from a
  CDN. A console is opened when something is wrong, often from a phone on a train, and
  the least useful thing it could do then is fail to render because somebody else's
  network is having a day.

  The webfonts are the one exception and they are `optional`: IBM Plex is what the design
  specifies, and the fallback stack is a real one, so a console with no route to Google
  renders in the system's own sans and mono rather than waiting.

  The theme is the reader's. Dark is the default because the design was drawn in dark
  first, and `data-theme` on the root element is what a light choice sets.
  """

  use Phoenix.Component

  @doc false
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Troupe platform console</title>

        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
        <link
          rel="stylesheet"
          media="print"
          onload="this.media='all'"
          href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans:wght@400;500;600&display=swap"
        />

        <link rel="stylesheet" href={static("/admin/static/tokens.css")} />
        <link rel="stylesheet" href={static("/admin/static/console.css")} />
        <script defer src={static("/admin/static/app.js")}>
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  # The release's version on the query string, so a browser holding last release's
  # `app.js` does not keep it for the year the cache header asks for.
  defp static(path) do
    version = to_string(Application.spec(:troupe_plane, :vsn) || "dev")
    path <> "?v=" <> version
  end
end
