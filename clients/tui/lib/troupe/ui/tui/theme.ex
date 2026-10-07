defmodule Troupe.UI.TUI.Theme do
  @moduledoc """
  The person's theme — Afterglow, Signal, Footlight or Limelight — at whatever depth the
  terminal can draw, from `Troupe.UI.TUI.Palette`.

  Which theme is the person's choice, and it is the desktop app's choice too: the
  `ui.theme` setting, which the daemon keeps and serves to both clients (root Decision
  761). `choose/2` reads it; one this Troupe does not know is drawn as Afterglow, the
  default, and the server says so once. The server reads it again whenever the daemon
  says a `ui` key changed, so a theme picked in either client is the one drawn, without
  a restart. `ui.blink` (on by default) says whether what waits on you blinks.

  The view never names a colour. It asks for a role — `style(:needs_you, [:bold])` —
  and gets a style whose colour is a placeholder; `paint/2` replaces every placeholder
  in a frame's widgets with what this terminal can show in the theme, once, as the frame
  is handed over. So the choice is made in one function and each depth is tested there:

    * `:truecolor` — the token's exact value, `{:rgb, r, g, b}`.
    * `:x256` — the nearest of xterm's fixed 240, chosen when the palette was generated.
    * `:x16` — the role's stand-in among the sixteen named colours: what the terminal's
      own theme says those are, which is the honest floor for a carefully tuned terminal.
    * `:none` — no colour at all. Bold, dim and reversed stay: they are not colour.

  **The canvas is not painted.** A terminal has a background of its own, and a dark
  slab laid over it fights whatever the person chose, so nothing here sets one; text
  that is not in a role keeps the terminal's own ink. Which of the tokens' two modes the
  colours come from follows the background the terminal reports, dark when it says
  nothing.

  **The reserved colour means one thing.** `:needs_you` and `:needs_you_edge` are for a
  person being needed and `:brand` for the mask's lit half — Afterglow's pink, Signal's
  magenta, Footlight's amber, Limelight's lime; the view uses them for nothing else, and
  a test reads every tag the model draws to hold it to that.

  What the terminal can draw comes from its environment, read once (`detect/1`); light
  or dark is the terminal's background, not the desktop app's `ui.mode`, which is about
  a window:

    * `TROUPE_COLORS` — `truecolor`, `256`, `16` or `none`, and `light` or `dark`, in
      any order (`TROUPE_COLORS=256,light`): what to use, whatever the terminal says.
    * `NO_COLOR` — any value: no colour (no-color.org).
    * `COLORTERM=truecolor` or `24bit`, or Windows Terminal (`WT_SESSION`): truecolor.
    * `TERM` naming `256color`: 256. Anything else: the sixteen.
    * `COLORFGBG` (`15;0`) with a light background (7 or 15): the light values.
  """

  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias Troupe.UI.TUI.Palette

  @type depth :: :truecolor | :x256 | :x16 | :none
  @type mode :: :dark | :light
  @typedoc "What the terminal can draw."
  @type terminal :: %{depth: depth(), mode: mode()}
  @typedoc "What a frame is drawn in: a theme, at the terminal's depth and mode, blinking or not."
  @type t :: %{name: Palette.theme(), depth: depth(), mode: mode(), blink: boolean()}

  @default :afterglow

  @depths %{
    "truecolor" => :truecolor,
    "24bit" => :truecolor,
    "256" => :x256,
    "16" => :x16,
    "none" => :none,
    "no" => :none,
    "off" => :none
  }

  @doc """
  The default theme for this terminal, its depth and mode read from the environment the
  first time it is asked; `choose/2` lays the person's choice over it.
  """
  @spec current() :: t()
  def current do
    terminal =
      case :persistent_term.get({__MODULE__, :current}, nil) do
        nil ->
          terminal = detect(System.get_env())
          :persistent_term.put({__MODULE__, :current}, terminal)
          terminal

        terminal ->
          terminal
      end

    Map.merge(%{name: @default, blink: true}, terminal)
  end

  @doc """
  The theme the `ui.theme` setting names, over `theme`: `{:ok, theme}`, or `{:unknown,
  theme}` in the default when the value is not a theme this Troupe knows (a newer
  desktop app's, or a typo), which is drawn rather than refused. `nil`, a setting nobody
  set, is the default.
  """
  @spec choose(t(), String.t() | nil) :: {:ok, t()} | {:unknown, t()}
  def choose(theme, nil), do: {:ok, Map.put(theme, :name, @default)}

  def choose(theme, value) when is_binary(value) do
    wanted = value |> String.trim() |> String.downcase()

    case Enum.find(Palette.themes(), &(Atom.to_string(&1.id) == wanted)) do
      nil -> {:unknown, Map.put(theme, :name, @default)}
      %{id: name} -> {:ok, Map.put(theme, :name, name)}
    end
  end

  def choose(theme, _other), do: {:unknown, Map.put(theme, :name, @default)}

  @doc "The themes there are, the default first: the values `ui.theme` takes."
  @spec names() :: [Palette.theme()]
  def names, do: Enum.map(Palette.themes(), & &1.id)

  @doc "Whether what waits on a person blinks: `ui.blink`, on unless it is `false`."
  @spec blinking(t(), term()) :: t()
  def blinking(theme, value), do: Map.put(theme, :blink, value != false)

  @doc """
  Whether what blinks is lit at `now`: on for half a second and off for half, about once
  a second, off the clock rather than the frame rate; always, with blinking off.
  """
  @spec lit?(map(), integer()) :: boolean()
  def lit?(theme, now), do: Map.get(theme, :blink, true) == false or rem(div(now, 500), 2) == 0

  @doc "What a terminal with this environment can draw; see the moduledoc for the order."
  @spec detect(%{optional(String.t()) => String.t()}) :: terminal()
  def detect(env) do
    words =
      env
      |> Map.get("TROUPE_COLORS", "")
      |> String.downcase()
      |> String.split(~r/[\s,;]+/, trim: true)

    %{depth: forced_depth(words) || depth(env), mode: forced_mode(words) || mode(env)}
  end

  defp forced_depth(words), do: Enum.find_value(words, &Map.get(@depths, &1))

  defp forced_mode(words) do
    cond do
      "light" in words -> :light
      "dark" in words -> :dark
      true -> nil
    end
  end

  defp depth(env) do
    term = Map.get(env, "TERM", "")

    cond do
      Map.get(env, "NO_COLOR", "") != "" -> :none
      term == "dumb" -> :none
      Map.get(env, "COLORTERM") in ["truecolor", "24bit"] -> :truecolor
      Map.get(env, "WT_SESSION", "") != "" -> :truecolor
      String.contains?(term, "256color") -> :x256
      true -> :x16
    end
  end

  # rxvt's convention, which several terminals follow: `fg;bg` or `fg;default;bg`, in
  # the sixteen's numbers. 7 and 15 are the light greys and white.
  defp mode(env) do
    bg = env |> Map.get("COLORFGBG", "") |> String.split(";") |> List.last()
    if bg in ["7", "15"], do: :light, else: :dark
  end

  ## Roles

  @doc "A style in a role, with modifiers. `nil` is the terminal's own ink."
  @spec style(Palette.role() | nil, [atom()]) :: Style.t()
  def style(role, modifiers \\ [])
  def style(nil, modifiers), do: %Style{modifiers: modifiers}
  def style(role, modifiers), do: %Style{fg: {:role, role}, modifiers: modifiers}

  @doc """
  The colour a role is drawn in, in a theme at its depth and mode; `nil` is the terminal
  default. A theme with no name is the default one.
  """
  @spec color(Palette.role(), map()) :: Style.color() | nil
  def color(_role, %{depth: :none}), do: nil
  def color(role, %{depth: :x16} = theme), do: role(role, theme).x16

  def color(role, %{depth: :x256, mode: mode} = theme),
    do: {:indexed, role |> role(theme) |> Map.fetch!(mode) |> Map.fetch!(:x256)}

  def color(role, %{depth: :truecolor, mode: mode} = theme) do
    {r, g, b} = role |> role(theme) |> Map.fetch!(mode) |> Map.fetch!(:rgb)
    {:rgb, r, g, b}
  end

  defp role(role, theme),
    do: theme |> Map.get(:name, @default) |> Palette.roles() |> Map.fetch!(role)

  @doc """
  Every colour in a frame's widgets resolved for a theme. Walks whatever it is given —
  the `{widget, rect}` list, a widget, a line — and leaves everything but a style's
  colours as it was.

  Roles become the theme's colour for them. A colour that arrived as a value — the code
  highlighter's, which are exact — is kept at truecolor, becomes its nearest of 256 at
  256, and is dropped for the terminal's ink with the sixteen or none: there is no
  honest sixteen-colour version of a syntax theme, and the code still reads without it.
  A background that arrives as a value is dropped at every depth: the canvas is the
  terminal's.
  """
  @spec paint(term(), t()) :: term()
  def paint(%Style{} = s, theme) do
    %{
      s
      | fg: resolve(s.fg, theme),
        bg: background(s.bg, theme),
        underline_color: resolve(s.underline_color, theme)
    }
  end

  def paint(list, theme) when is_list(list), do: Enum.map(list, &paint(&1, theme))
  def paint({a, b}, theme), do: {paint(a, theme), paint(b, theme)}

  def paint(%{__struct__: _} = struct, theme) do
    struct
    |> Map.from_struct()
    |> Enum.reduce(struct, fn {key, value}, acc -> Map.put(acc, key, paint(value, theme)) end)
  end

  def paint(other, _theme), do: other

  # The canvas is the terminal's: a background is only ever a role's (the mask's lit
  # half), never one a highlighter brought with it.
  defp background({:role, _} = role, theme), do: resolve(role, theme)
  defp background(_color, _theme), do: nil

  defp resolve({:role, role}, theme), do: color(role, theme)
  defp resolve(nil, _theme), do: nil
  defp resolve(_color, %{depth: :none}), do: nil
  defp resolve({:rgb, r, g, b}, %{depth: :x256}), do: {:indexed, nearest256({r, g, b})}
  defp resolve({:rgb, _r, _g, _b}, %{depth: :x16}), do: nil
  defp resolve(color, _theme), do: color

  ## xterm-256

  @doc """
  The nearest of xterm's 240 fixed colours — the 6x6x6 cube and the grey ramp — to an
  sRGB colour, by CIELAB distance, other than those in `except`; ties go to the lower
  index. 0 to 15 are never the answer: they are whatever the terminal's own theme made
  them. `mix troupe.palette` uses this for the roles, with the reserved colour's own
  index kept from every other role, and `paint/2` for a colour that arrives as a value,
  remembered per process since a frame repeats the few a highlighter uses.
  """
  @spec nearest256({0..255, 0..255, 0..255}, [16..255]) :: 16..255
  def nearest256(rgb, except \\ []) do
    key = {__MODULE__, :nearest256, rgb, except}

    with nil <- Process.get(key) do
      {l, a, b} = lab(rgb)

      {n, _lab} =
        xterm_lab()
        |> Enum.reject(fn {n, _lab} -> n in except end)
        |> Enum.min_by(fn {_n, {l2, a2, b2}} ->
          (l - l2) * (l - l2) + (a - a2) * (a - a2) + (b - b2) * (b - b2)
        end)

      Process.put(key, n)
      n
    end
  end

  defp xterm_lab do
    with nil <- :persistent_term.get({__MODULE__, :xterm_lab}, nil) do
      table = for n <- 16..255, do: {n, lab(xterm(n))}
      :persistent_term.put({__MODULE__, :xterm_lab}, table)
      table
    end
  end

  @doc false
  @spec xterm(16..255) :: {0..255, 0..255, 0..255}
  def xterm(n) when n >= 232, do: {8 + 10 * (n - 232), 8 + 10 * (n - 232), 8 + 10 * (n - 232)}

  def xterm(n) do
    level = {0, 95, 135, 175, 215, 255}
    i = n - 16
    {elem(level, div(i, 36)), elem(level, rem(div(i, 6), 6)), elem(level, rem(i, 6))}
  end

  # sRGB to CIELAB under D65.
  defp lab({r, g, b}) do
    {lr, lg, lb} = {linear(r), linear(g), linear(b)}
    x = (0.4124564 * lr + 0.3575761 * lg + 0.1804375 * lb) / 0.95047
    y = 0.2126729 * lr + 0.7151522 * lg + 0.0721750 * lb
    z = (0.0193339 * lr + 0.1191920 * lg + 0.9503041 * lb) / 1.08883
    {fx, fy, fz} = {f(x), f(y), f(z)}
    {116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)}
  end

  defp linear(c) do
    c = c / 255
    if c <= 0.04045, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
  end

  defp f(t) when t > 216 / 24_389, do: :math.pow(t, 1 / 3)
  defp f(t), do: (24_389 / 27 * t + 16) / 116

  ## The mask

  @doc """
  The mask in half-blocks: one `Line` per two rows of `Palette.mask/1`, two pixels to a
  cell. The edge and the eye on the hollow half are the terminal's own ink; the lit
  half is `:brand`; the eye on the lit half is cut out of it, so it shows the terminal's
  background. With no colour the lit half is drawn in ink, solid against the hollow one,
  which is the mark in one colour.
  """
  @spec mask(:large | :small, t()) :: [Line.t()]
  def mask(cut, theme) do
    cut
    |> Palette.mask()
    |> Enum.chunk_every(2)
    |> Enum.map(fn [top, bottom] ->
      top
      |> pixels(theme)
      |> Enum.zip(pixels(bottom, theme))
      |> Enum.map(&cell/1)
      |> Enum.chunk_by(&elem(&1, 1))
      |> Enum.map(fn [{_, style} | _] = run ->
        Span.new(Enum.map_join(run, &elem(&1, 0)), style: style)
      end)
      |> Line.new()
    end)
  end

  @doc "How many cells wide and tall a cut of the mask is."
  @spec mask_size(:large | :small) :: {pos_integer(), pos_integer()}
  def mask_size(cut) do
    rows = Palette.mask(cut)
    {String.length(hd(rows)), div(length(rows), 2)}
  end

  defp pixels(row, theme) do
    for <<p <- row>> do
      case p do
        p when p in [?o, ?e] -> :ink
        ?f -> if theme.depth == :none, do: :ink, else: :fill
        _ -> :empty
      end
    end
  end

  # Two stacked pixels in one cell: the upper half-block draws the top in the
  # foreground over the bottom in the background, the lower the other way round. Ink is
  # only ever a foreground, since the terminal's own ink cannot be a background.
  defp cell({same, same}) when same != :empty, do: {"█", %Style{fg: ink(same)}}
  defp cell({:empty, :empty}), do: {" ", %Style{}}
  defp cell({top, :empty}), do: {"▀", %Style{fg: ink(top)}}
  defp cell({:empty, bottom}), do: {"▄", %Style{fg: ink(bottom)}}
  defp cell({:ink, :fill}), do: {"▀", %Style{bg: ink(:fill)}}
  defp cell({:fill, :ink}), do: {"▄", %Style{bg: ink(:fill)}}

  defp ink(:ink), do: nil
  defp ink(:fill), do: {:role, :brand}
end
