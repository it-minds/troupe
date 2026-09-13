defmodule Mix.Tasks.Troupe.Theme do
  @shortdoc "Generate the brand stylesheet from a theme kit's tokens"

  @moduledoc """
  Turn one of `docs/design/themes/*.tokens.json` into
  `apps/troupe_plane/priv/static/theme.css`.

      mix troupe.theme
      mix troupe.theme --theme limelight
      mix troupe.theme --check

  ## What this is, and what it is not

  `docs/design/themes/THEMES.md` describes three themes over one token contract —
  Footlight, Limelight and Signal — of which **Signal** is the one the platform wears in
  public: neutral graphite with no blue cast, cyan for the machine working and magenta,
  the reserved colour, for a person being asked to decide. This task writes that theme
  out as the stylesheet the plane's front page loads.

  It is a *sibling* of `mix troupe.admin.tokens`, not a replacement. The console reads
  `docs/design/admin/tokens.json`, whose status vocabulary is the fleet's — healthy,
  degraded, draining, broken — and which a theme kit does not define. Both documents
  share the same shape, so both go through the same walk in
  `Mix.Tasks.Troupe.Admin.Tokens.render/2`, and the two stylesheets are never loaded by
  the same page.

  ## The naming

  As the console's: a variable is its path through the document, hyphenated.
  `color.status.waiting.solid` becomes `--color-status-waiting-solid`,
  `typography.role.body` becomes both the five parts and the CSS `font` shorthand. Dark
  values land on `:root`, light under `:root[data-theme="light"]` and the system
  preference — Signal's own `defaultMode` is dark.

  Generated and committed, with `--check` for CI, so the bytes a browser is served
  cannot drift from the kit a designer edits.
  """

  use Mix.Task

  alias Mix.Tasks.Troupe.Admin.Tokens

  @output_path Path.join(~w(apps troupe_plane priv static theme.css))
  @themes_dir Path.join(~w(docs design themes))

  # The main theme. Changing this line changes what the front page wears; the other two
  # kits stay in `docs/` and stay renderable through `--theme`.
  @default_theme "signal"

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv, strict: [check: :boolean, theme: :string])

    theme = opts[:theme] || @default_theme
    source = Path.join(@themes_dir, "#{theme}.tokens.json")

    css =
      source
      |> Tokens.read!()
      |> Tokens.render(source: source, task: task_line(theme))

    if opts[:check], do: check(css), else: write(css)
  end

  defp task_line(@default_theme), do: "mix troupe.theme"
  defp task_line(theme), do: "mix troupe.theme --theme #{theme}"

  defp write(css) do
    File.mkdir_p!(Path.dirname(@output_path))
    File.write!(@output_path, css)
    Mix.shell().info("wrote #{@output_path} (#{byte_size(css)} bytes)")
  end

  defp check(expected) do
    case File.read(@output_path) do
      {:ok, ^expected} ->
        Mix.shell().info("theme.css is current")

      {:ok, _stale} ->
        Mix.raise("#{@output_path} is stale: run `mix troupe.theme` and commit it")

      {:error, _reason} ->
        Mix.raise("#{@output_path} is missing: run `mix troupe.theme`")
    end
  end
end
