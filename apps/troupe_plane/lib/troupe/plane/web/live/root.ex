defmodule Troupe.Plane.Web.Live.Root do
  @moduledoc """
  The HTML document every panel page is delivered inside.

  One inline stylesheet and no JavaScript beyond LiveView's own. A panel is opened when
  something is wrong, often from a phone on a train, and the least useful thing it could
  do then is fail to render because a CDN is unreachable.
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
        <title>troupe</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 14px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; margin: 0; padding: 1.5rem; }
          header { display: flex; gap: 1.5rem; align-items: baseline; flex-wrap: wrap; margin-bottom: 1.5rem; }
          nav { display: flex; gap: 1rem; }
          nav a { text-decoration: none; opacity: 0.6; }
          nav a.here { opacity: 1; font-weight: bold; text-decoration: underline; }
          .who { margin-left: auto; opacity: 0.6; }
          table { border-collapse: collapse; width: 100%; margin: 0.5rem 0 1.5rem; }
          th, td { text-align: left; padding: 0.35rem 0.75rem 0.35rem 0; vertical-align: top; }
          th { border-bottom: 1px solid currentColor; }
          tr.good td:first-child::before { content: "● "; color: green; }
          tr.bad td:first-child::before { content: "● "; color: crimson; }
          tr.neutral td:first-child::before { content: "○ "; }
          .error { color: crimson; }
          .notice { padding: 0.5rem; border-left: 3px solid currentColor; }
          .hint { opacity: 0.6; }
          .good { color: green; }
          .bad { color: crimson; }
          .none { opacity: 0.5; }
          dl.counts { display: grid; grid-template-columns: max-content auto; gap: 0.25rem 1rem; }
          dl.counts dt { opacity: 0.6; }
          dl.counts dd { margin: 0; }
          form { display: flex; gap: 1rem; flex-wrap: wrap; align-items: flex-end; margin: 0.5rem 0; }
          label { display: flex; flex-direction: column; gap: 0.25rem; }
          pre { white-space: pre-wrap; margin: 0; }
          ul { margin: 0.25rem 0; padding-left: 1.25rem; }
        </style>
        <script defer src="/admin/static/app.js">
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
