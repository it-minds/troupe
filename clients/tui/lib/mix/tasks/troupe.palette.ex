defmodule Mix.Tasks.Troupe.Palette do
  @moduledoc """
  Generate `lib/troupe/ui/tui/palette.ex` from the design tokens of every theme.

      mix troupe.palette
      mix troupe.palette --check

  The design is the theme files in `clients/gui/docs/design/themes/`, one
  `<theme>.tokens.json` each — Afterglow, Signal, Footlight and Limelight: the GUI's
  stylesheet and mask are generated from them by `pnpm tokens`, the plane's front page
  by `mix troupe.theme`, and the TUI's colours and its mask by this. A colour typed into
  the TUI by hand is how the two clients stop being one product, the way the app icon
  once did (root Decision 703), so the palette is generated and committed, and
  `--check` (in `mix check`, which CI runs) fails when it is not what the tokens say. A
  theme file added there is a theme here at the next run.

  ## What it writes

  **The themes, in the order the desktop app offers them**, Afterglow first, since it is
  the default (`theme.ts`), and any other theme file after those four by name. Each
  with the name it gives itself and its description, for the settings page's menu.

  **Roles, not colour names.** The view asks for `:needs_you` or `:muted`, never for
  pink or grey; the table below says which token each role is and which of the sixteen
  named colours stands in for it on a terminal that has no more. For every role in every
  theme the module carries the token's dark and light values, and the nearest colour in
  the xterm-256 palette to each (`Troupe.UI.TUI.Theme.nearest256/1`): the cube and the
  grey ramp only, because 0 to 15 are whatever the person's terminal theme made them. A
  token with an alpha channel is laid over the theme's `bg.canvas`, as it is in the GUI.

  **The reserved colour means one thing.** `status.waiting` is each theme's reserved
  colour — Afterglow's pink, Signal's magenta, Footlight's amber, Limelight's lime — and
  means a person is needed. Two roles carry it for that — `:needs_you` and its border
  — and `:brand` carries it for the one other use the design allows, the mask's lit
  half (`views/brand.tsx`). No other role takes it: a role whose token is the reserved
  colour in some theme names a second token for there (Limelight's focus ring is its
  lime, so the accent is its link blue), and at 256 a role whose nearest is the reserved
  colour's takes its next nearest. Magenta in the sixteen goes to those three and nothing
  else, in every theme: with sixteen colours the terminal's own theme decides what each
  looks like, so a stand-in is chosen for what the role means, not for the hue a theme
  gives it, and the rule holds at every depth.

  **The mask**, rasterised from `mark.path` and the two eyes: one character per pixel
  (`o` the edge, `f` the lit half, `e` an eye on the hollow half, `c` an eye cut out of
  the lit half, `.` nothing), at two cuts, for half-blocks to draw two pixels to a cell.
  The design's rules are the rasteriser's: light from the right, so the right half is
  lit; an eye on the lit half is cut out of it and one on the hollow half is solid; no
  mouth, because there is none in the path; never mirrored. At these sizes the design
  drops the seam and lets the colour change be the seam, and draws the edge at its
  small stroke. The mark is the same in every theme file (`pnpm tokens` refuses one
  whose structure differs), so it is drawn once, from the first; this refuses a theme
  whose mark is not that one too.
  """

  use Mix.Task

  alias Troupe.UI.TUI.Theme

  @shortdoc "Generate the TUI's palette and mask from the design tokens"

  @source Path.join(~w(.. gui docs design themes))
  @output Path.join(~w(lib troupe ui tui palette.ex))

  # The order the desktop app's appearance screen offers them in (`theme.ts`).
  @order ~w(afterglow signal footlight limelight)

  # {role, token, the sixteen-colour stand-in, what it is for}. A token may be a list:
  # the first that is not the theme's reserved colour, for a role that is not one of
  # the three that carry it — Limelight's focus ring is its lime, and the TUI's accent
  # is on every heading, so there it is the link blue, as the theme's own `accent` is.
  @reserved_roles [:needs_you, :needs_you_edge, :brand]

  @roles [
    {:needs_you, "status.waiting.fg", :magenta,
     "a person is needed: an approval, a question, the budget question, the window and status that say so"},
    {:needs_you_edge, "status.waiting.border", :magenta, "the border of a window that needs you"},
    {:brand, "status.waiting.solid", :magenta,
     "the mask's lit half, the one use of the reserved colour that is not a request"},
    {:working, "status.running.fg", :cyan,
     "the machine working: the activity line, a running tool"},
    {:working_edge, "status.running.border", :cyan, "the border of a window that is working"},
    {:accent, ["border.focus", "text.link"], :cyan,
     "the light that is not a status: headings, bullets, code labels, your marker, the selected row"},
    {:ok, "status.allowed.fg", :green, "a tool that succeeded, a window done and not yet read"},
    {:error, "status.error.fg", :red, "a tool that failed, a window that failed"},
    {:offline, "status.offline.fg", :yellow, "a plane that does not answer"},
    {:stale, ["status.offline.fg", "status.error.fg"], :yellow,
     "a fact that may no longer be true: an anchor of it changed or went"},
    {:added, "diff.addedText", :green, "a line a diff adds"},
    {:removed, "diff.removedText", :red, "a line a diff removes"},
    {:hunk, "diff.hunkHeader", :dark_gray, "a diff's file and hunk headers"},
    {:muted, "text.muted", :dark_gray,
     "what is there to be read second: the status line, greyed rows, reasoning, tool notes"},
    {:rail, "border.strong", :dark_gray,
     "code and quote rails, line numbers, the scrollbar, an unfocused box"}
  ]

  # Two cuts of the mask, by width in cells: the empty screen's and HQ's header.
  @cuts [large: 16, small: 10]
  # The design's small stroke, for a mark drawn under 24px.
  @stroke "sm"
  @samples 5

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [check: :boolean])
    source = render(read_all!())
    if opts[:check], do: check(source), else: write(source)
  end

  @doc "Reads a tokens file."
  @spec read!(Path.t()) :: map()
  def read!(path), do: path |> File.read!() |> Jason.decode!()

  @doc "Every theme's tokens in `dir`, in the order the desktop app offers them."
  @spec read_all!(Path.t()) :: [map()]
  def read_all!(dir \\ @source) do
    dir
    |> Path.join("*.tokens.json")
    |> Path.wildcard()
    |> Enum.map(&read!/1)
    |> Enum.sort_by(fn tokens ->
      id = tokens["$meta"]["id"]
      {Enum.find_index(@order, &(&1 == id)) || length(@order), id}
    end)
  end

  @doc "The generated module's source, formatted, for the themes' tokens documents."
  @spec render([map()]) :: String.t()
  def render([first | _] = themes) do
    for tokens <- themes, tokens["mark"] != first["mark"] do
      Mix.raise("#{id(tokens)}'s mark is not #{id(first)}'s: the mark is one in every theme")
    end

    themes = Enum.map(themes, &theme/1)
    masks = Enum.map(@cuts, fn {cut, cols} -> {cut, mask(first["mark"], cols)} end)

    themes
    |> module(masks)
    |> Code.format_string!(line_length: 100)
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  defp id(tokens), do: tokens["$meta"]["id"]

  # A theme as the module carries it: what it calls itself, and its roles.
  defp theme(tokens) do
    meta = tokens["$meta"]
    {reserved, others} = Enum.split_with(@roles, &(elem(&1, 0) in @reserved_roles))
    reserved = Enum.map(reserved, &role(&1, tokens, []))
    roles = reserved ++ Enum.map(others, &role(&1, tokens, reserved))

    %{
      id: String.to_atom(id(tokens)),
      name: meta["name"] |> String.split(" — ") |> List.last(),
      description: meta["description"],
      reserved: reserved(meta["reservedColour"]),
      roles:
        Enum.sort_by(roles, fn role -> Enum.find_index(@roles, &(elem(&1, 0) == role.name)) end)
    }
  end

  # The word for the reserved colour: "status.waiting — stage amber #FFB43D / ..." says
  # "stage amber".
  defp reserved(text) do
    case Regex.run(~r/—\s*([^#]+?)\s*#/u, text || "") do
      [_, word] -> word
      nil -> Mix.raise("$meta.reservedColour does not name the reserved colour: #{inspect(text)}")
    end
  end

  defp write(source) do
    File.write!(@output, source)
    Mix.shell().info("wrote #{@output} (#{byte_size(source)} bytes)")
  end

  defp check(expected) do
    case File.read(@output) do
      {:ok, ^expected} ->
        Mix.shell().info("#{@output} is current")

      {:ok, _stale} ->
        Mix.raise("#{@output} is stale: run `mix troupe.palette` and commit it")

      {:error, _reason} ->
        Mix.raise("#{@output} is missing: run `mix troupe.palette`")
    end
  end

  ## Roles

  # The role's values from the first of its tokens whose values are not the reserved
  # roles' (`reserved`, empty for those three themselves); the last when none is free.
  # At 256 a role that is not reserved never lands on the reserved colour's index either:
  # two near colours can share their nearest, and then it takes its next nearest.
  defp role({name, paths, x16, use}, tokens, reserved) do
    candidates = Enum.map(List.wrap(paths), &{&1, modes(&1, tokens, reserved)})

    {path, modes} =
      Enum.find(candidates, List.last(candidates), fn {_path, modes} -> free?(modes, reserved) end)

    %{name: name, token: path, use: use, dark: modes.dark, light: modes.light, x16: x16}
  end

  defp free?(modes, reserved) do
    Enum.all?([:dark, :light], fn mode ->
      modes[mode].rgb not in Enum.map(reserved, & &1[mode].rgb)
    end)
  end

  defp modes(path, tokens, reserved) do
    token = get_in(tokens, ["color" | String.split(path, ".")])
    canvas = get_in(tokens, ~w(color bg canvas))

    unless is_map(token) and is_binary(token["dark"]) and is_binary(token["light"]),
      do: Mix.raise("#{id(tokens)}: #{path} is not a colour token with a dark and a light value")

    for mode <- [:dark, :light], into: %{} do
      rgb = over(parse(token[to_string(mode)]), parse(canvas[to_string(mode)]))
      except = reserved |> Enum.map(& &1[mode].x256) |> Enum.uniq() |> Enum.sort()
      {mode, %{rgb: rgb, x256: Theme.nearest256(rgb, except)}}
    end
  end

  defp parse("#" <> hex) when byte_size(hex) == 6 do
    <<r::binary-2, g::binary-2, b::binary-2>> = hex
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16), 1.0}
  end

  defp parse("rgba(" <> rest) do
    [r, g, b, a] = rest |> String.trim_trailing(")") |> String.split(",") |> Enum.map(&number/1)
    {round(r), round(g), round(b), a / 1}
  end

  defp parse(other), do: Mix.raise("cannot read the colour #{inspect(other)}")

  defp number(text) do
    text = String.trim(text)
    if String.contains?(text, "."), do: String.to_float(text), else: String.to_integer(text)
  end

  # An alpha colour as it lands on the canvas, which is what a terminal cell can show.
  defp over({r, g, b, a}, {br, bg, bb, _}),
    do: {round(a * r + (1 - a) * br), round(a * g + (1 - a) * bg), round(a * b + (1 - a) * bb)}

  ## The mask

  # One character per pixel, rows top to bottom, at `cols` pixels across the silhouette
  # and its edge. Pixels are square and a cell is two of them stacked, so the row count
  # is even and the picture is `cols` cells wide and half as many cells tall as it has rows.
  defp mask(mark, cols) do
    outline = flatten(mark["path"])
    eyes = {flatten(mark["eyeLeft"]), flatten(mark["eyeRight"])}
    stroke = mark |> get_in(["strokeWidth", @stroke]) |> number()
    seam = seam_x(mark["seam"]["path"])

    {xs, ys} = Enum.unzip(outline)
    {x0, x1} = {Enum.min(xs) - stroke / 2, Enum.max(xs) + stroke / 2}
    {y0, y1} = {Enum.min(ys) - stroke / 2, Enum.max(ys) + stroke / 2}
    scale = cols / (x1 - x0)
    rows = ceil((y1 - y0) * scale)
    top = y0 - (rows / scale - (y1 - y0)) / 2
    shape = %{outline: outline, eyes: eyes, half: stroke / 2, seam: seam}

    for row <- 0..(rows - 1) do
      for col <- 0..(cols - 1), into: "" do
        pixel(shape, fn a, b -> {x0 + (col + a) / scale, top + (row + b) / scale} end)
      end
    end
    |> trim_rows()
  end

  # The seam is the vertical line the lit half starts at.
  defp seam_x(path) do
    [{x, _} | _] = flatten(path)
    x
  end

  defp pixel(shape, at) do
    counts =
      for i <- 0..(@samples - 1), j <- 0..(@samples - 1), reduce: %{} do
        acc ->
          {x, y} = at.((i + 0.5) / @samples, (j + 0.5) / @samples)
          Map.update(acc, sample(shape, x, y), 1, &(&1 + 1))
      end

    share = fn kind -> Map.get(counts, kind, 0) / (@samples * @samples) end

    cond do
      share.(?e) >= 0.4 -> "e"
      share.(?c) >= 0.4 -> "c"
      share.(?o) >= 0.4 -> "o"
      share.(?f) >= 0.5 -> "f"
      true -> "."
    end
  end

  defp sample(%{outline: outline, eyes: {left, right}} = shape, x, y) do
    cond do
      edge_distance(outline, x, y) <= shape.half -> ?o
      not inside?(outline, x, y) -> ?.
      x >= shape.seam -> if inside?(right, x, y), do: ?c, else: ?f
      inside?(left, x, y) -> ?e
      true -> ?.
    end
  end

  defp trim_rows(rows) do
    blank? = &(String.trim(&1, ".") == "")

    rows =
      rows
      |> Enum.drop_while(blank?)
      |> Enum.reverse()
      |> Enum.drop_while(blank?)
      |> Enum.reverse()

    if rem(length(rows), 2) == 1,
      do: rows ++ [String.duplicate(".", String.length(hd(rows)))],
      else: rows
  end

  # An SVG path of M, L, Q and Z, as a closed polyline; each curve in sixteen steps, so
  # the same pixels come out on every machine.
  defp flatten(path) do
    ~r/[MLQZ]|-?\d+(?:\.\d+)?/
    |> Regex.scan(path)
    |> List.flatten()
    |> points([], nil, nil)
  end

  defp points([], acc, _cur, _start), do: Enum.reverse(acc)

  defp points(["M", x, y | rest], acc, _cur, _start) do
    p = {number(x) / 1, number(y) / 1}
    points(rest, [p | acc], p, p)
  end

  defp points(["L", x, y | rest], acc, _cur, start) do
    p = {number(x) / 1, number(y) / 1}
    points(rest, [p | acc], p, start)
  end

  defp points(["Q", cx, cy, x, y | rest], acc, {px, py}, start) do
    {cx, cy, ex, ey} = {number(cx), number(cy), number(x) / 1, number(y) / 1}

    curve =
      for k <- 1..16 do
        u = k / 16
        v = 1 - u
        {v * v * px + 2 * v * u * cx + u * u * ex, v * v * py + 2 * v * u * cy + u * u * ey}
      end

    points(rest, Enum.reverse(curve) ++ acc, {ex, ey}, start)
  end

  defp points(["Z" | rest], [last | _] = acc, _cur, start) do
    acc = if last == start, do: acc, else: [start | acc]
    points(rest, acc, start, start)
  end

  defp inside?(poly, x, y) do
    poly
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(false, fn [{x1, y1}, {x2, y2}], inside ->
      if y1 > y != y2 > y and x < x1 + (y - y1) * (x2 - x1) / (y2 - y1),
        do: not inside,
        else: inside
    end)
  end

  defp edge_distance(poly, x, y) do
    poly
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> segment_distance(a, b, x, y) end)
    |> Enum.min()
  end

  defp segment_distance({x1, y1}, {x2, y2}, x, y) do
    {dx, dy} = {x2 - x1, y2 - y1}
    len = dx * dx + dy * dy
    u = if len == 0, do: 0, else: max(0, min(1, ((x - x1) * dx + (y - y1) * dy) / len))
    :math.sqrt(:math.pow(x - (x1 + u * dx), 2) + :math.pow(y - (y1 + u * dy), 2))
  end

  ## The module

  defp module([default | _] = themes, masks) do
    names = Enum.map_join(themes, ", ", & &1.name)
    files = Enum.map_join(themes, "\n", &"#   #{&1.id}.tokens.json")
    uses = Enum.map_join(default.roles, "\n    ", &"* `#{inspect(&1.name)}` — #{&1.use}")

    """
    # Generated from clients/gui/docs/design/themes/
    #{files}
    # by `mix troupe.palette`. Do not edit by hand: change the tokens, or the role table in
    # lib/mix/tasks/troupe.palette.ex, and run it again. `mix troupe.palette --check`
    # fails when this file is not what they say.
    defmodule Troupe.UI.TUI.Palette do
      @moduledoc \"\"\"
      The themes for a terminal — #{names}: every colour the TUI
      draws, by role, in each theme, and the mask.

      `Troupe.UI.TUI.Theme` chooses from this what a terminal can show. Generated by
      `mix troupe.palette`; see that task for what each part is.
      \"\"\"

      @typedoc "A theme, by the id its tokens file gives it."
      @type theme :: #{Enum.map_join(themes, " | ", &inspect(&1.id))}

      @typedoc \"\"\"
      What a colour is for. The view names a role, never a colour:

        #{uses}
      \"\"\"
      @type role :: #{Enum.map_join(default.roles, " | ", &inspect(&1.name))}

      @typedoc "A pixel of the mask: `?o` edge, `?f` lit half, `?e` solid eye, `?c` cut eye, `?.` none."
      @type mask :: [String.t()]

      @themes [
        #{Enum.map_join(themes, ",\n", &theme_source/1)}
      ]

      @roles %{
        #{Enum.map_join(themes, ",\n", &roles_source/1)}
      }

      @doc "Every theme, in the order the desktop app offers them; the first is the default."
      @spec themes() :: [%{id: theme(), name: String.t(), description: String.t(), reserved: String.t()}]
      def themes, do: @themes

      @doc "A theme's roles: each one's token, dark and light values with their xterm-256 nearest, and its stand-in among the sixteen."
      @spec roles(theme()) :: %{role() => map()}
      def roles(theme \\\\ #{inspect(default.id)}), do: Map.fetch!(@roles, theme)

      @doc "The mask at a cut: `:large` is #{@cuts[:large]} cells wide, `:small` #{@cuts[:small]}."
      @spec mask(:large | :small) :: mask()
      #{Enum.map_join(masks, "\n", &mask_source/1)}
    end
    """
  end

  defp theme_source(theme) do
    """
    %{
      id: #{inspect(theme.id)},
      name: #{inspect(theme.name)},
      description: #{inspect(theme.description)},
      reserved: #{inspect(theme.reserved)}
    }
    """
    |> String.trim_trailing()
  end

  defp roles_source(theme) do
    """
    #{theme.id}: %{
      #{Enum.map_join(theme.roles, ",\n", &role_source/1)}
    }
    """
    |> String.trim_trailing()
  end

  defp role_source(role) do
    """
    #{role.name}: %{
      token: #{inspect(role.token)},
      dark: #{mode_source(role.dark)},
      light: #{mode_source(role.light)},
      x16: #{inspect(role.x16)}
    }
    """
    |> String.trim_trailing()
  end

  # Written out key by key: `inspect/1` orders a small map's atom keys by when the atoms
  # were made, which differs between a mix task and a test run.
  defp mode_source(%{rgb: rgb, x256: n}), do: "%{rgb: #{inspect(rgb)}, x256: #{n}}"

  defp mask_source({cut, rows}) do
    "def mask(#{inspect(cut)}), do: [\n#{Enum.map_join(rows, ",\n", &inspect/1)}\n]"
  end
end
