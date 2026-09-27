defmodule Troupe.TUIThemeTest do
  @moduledoc """
  Afterglow in the TUI (issue #228): the palette generated from the design tokens, the
  depth a terminal gets, the reserved pink kept to what needs a person, and the mask.

  The screens are drawn the way the server draws them — `View.render/2` into a headless
  `CellSession` — from a model folded out of the worker's events, at each depth, and read
  back cell by cell with their colours.
  """

  use ExUnit.Case, async: true

  alias ExRatatui.CellSession
  alias ExRatatui.Frame
  alias ExRatatui.Style
  alias Mix.Tasks.Troupe.Palette, as: Generate
  alias Troupe.Remote.Translate
  alias Troupe.UI.TUI.{Model, Palette, Theme, View}

  @tokens Path.join(~w(.. gui docs design themes afterglow.tokens.json))
  @reserved [:needs_you, :needs_you_edge, :brand]

  ## The palette is the tokens

  test "the committed palette is what the generator makes of the tokens" do
    committed = String.split(File.read!("lib/troupe/ui/tui/palette.ex"), "\n")
    generated = String.split(Generate.render(Generate.read!(@tokens)), "\n")

    first =
      committed
      |> Enum.zip(generated)
      |> Enum.find(fn {a, b} -> a != b end)

    assert first == nil and length(committed) == length(generated),
           "lib/troupe/ui/tui/palette.ex is stale (first difference: #{inspect(first)}): " <>
             "run `mix troupe.palette` and commit it"
  end

  test "each role carries its token's two values, and the reserved one is the tokens' pink" do
    tokens = Generate.read!(@tokens)

    for {role, %{token: path, dark: dark, light: light}} <- Palette.roles() do
      token = get_in(tokens, ["color" | String.split(path, ".")])

      for {mode, %{rgb: rgb}} <- [dark: dark, light: light],
          String.starts_with?(token[to_string(mode)], "#") do
        assert hex(rgb) == String.upcase(token[to_string(mode)]), "#{role} #{mode}"
      end
    end

    assert Palette.roles().needs_you.token == "status.waiting.fg"
    assert Palette.roles().needs_you.dark.rgb == {255, 0, 128}
  end

  test "no role falls back to one of the terminal's own sixteen at 256, and magenta is reserved" do
    for {role, %{dark: dark, light: light, x16: x16}} <- Palette.roles() do
      assert dark.x256 in 16..255 and light.x256 in 16..255, "#{role}"
      assert x16 == :magenta == role in @reserved, "#{role} is #{x16} in sixteen colours"
    end
  end

  ## What the terminal gets

  describe "detect/1" do
    test "the sixteen when the terminal says nothing, dark when it says nothing of its background" do
      assert Theme.detect(%{}) == %{depth: :x16, mode: :dark}
      assert Theme.detect(%{"TERM" => "xterm"}).depth == :x16
    end

    test "truecolor from COLORTERM, and from Windows Terminal, which does not set it" do
      assert Theme.detect(%{"COLORTERM" => "truecolor"}).depth == :truecolor
      assert Theme.detect(%{"COLORTERM" => "24bit"}).depth == :truecolor
      assert Theme.detect(%{"WT_SESSION" => "8e1d-4c0a"}).depth == :truecolor
    end

    test "256 from a TERM that names it" do
      assert Theme.detect(%{"TERM" => "xterm-256color"}).depth == :x256

      assert Theme.detect(%{"TERM" => "tmux-256color", "COLORTERM" => "truecolor"}).depth ==
               :truecolor
    end

    test "no colour under NO_COLOR, or on a dumb terminal" do
      assert Theme.detect(%{"NO_COLOR" => "1", "COLORTERM" => "truecolor"}).depth == :none
      assert Theme.detect(%{"NO_COLOR" => "", "TERM" => "xterm-256color"}).depth == :x256
      assert Theme.detect(%{"TERM" => "dumb"}).depth == :none
    end

    test "TROUPE_COLORS forces a depth and a mode, whatever the terminal says" do
      env = %{"COLORTERM" => "truecolor", "NO_COLOR" => "1"}

      assert Theme.detect(Map.put(env, "TROUPE_COLORS", "256")) == %{depth: :x256, mode: :dark}
      assert Theme.detect(Map.put(env, "TROUPE_COLORS", "16, light")).mode == :light
      assert Theme.detect(Map.put(env, "TROUPE_COLORS", "truecolor")).depth == :truecolor
      assert Theme.detect(%{"TROUPE_COLORS" => "none", "COLORTERM" => "24bit"}).depth == :none
      assert Theme.detect(%{"TROUPE_COLORS" => "light"}) == %{depth: :x16, mode: :light}
    end

    test "the light values when the terminal reports a light background" do
      assert Theme.detect(%{"COLORFGBG" => "0;15"}).mode == :light
      assert Theme.detect(%{"COLORFGBG" => "0;default;7"}).mode == :light
      assert Theme.detect(%{"COLORFGBG" => "15;0"}).mode == :dark
    end
  end

  test "a role at each depth: exact, nearest of 256, its stand-in among sixteen, or none" do
    assert Theme.color(:needs_you, %{depth: :truecolor, mode: :dark}) == {:rgb, 255, 0, 128}
    assert Theme.color(:needs_you, %{depth: :truecolor, mode: :light}) == {:rgb, 196, 0, 95}
    assert Theme.color(:needs_you, %{depth: :x256, mode: :dark}) == {:indexed, 198}
    assert Theme.color(:needs_you, %{depth: :x16, mode: :dark}) == :magenta
    assert Theme.color(:needs_you, %{depth: :none, mode: :dark}) == nil
    assert Theme.color(:working, %{depth: :x16, mode: :light}) == :cyan
  end

  test "painting resolves every role in a frame and leaves every other colour alone" do
    theme = %{depth: :x256, mode: :dark}
    line = ExRatatui.Text.Line.new([ExRatatui.Text.Span.new("x", style: Theme.style(:error))])

    frame = [
      {%ExRatatui.Widgets.Paragraph{text: [line], style: %Style{fg: :blue, bg: {:role, :rail}}},
       %ExRatatui.Layout.Rect{x: 0, y: 0, width: 1, height: 1}}
    ]

    [{%{text: [%{spans: [span]}], style: style}, _rect}] = Theme.paint(frame, theme)
    assert span.style.fg == {:indexed, Palette.roles().error.dark.x256}
    assert style.fg == :blue
    assert style.bg == {:indexed, Palette.roles().rail.dark.x256}
  end

  test "a highlighter's own colours degrade with the depth, and its backgrounds are dropped" do
    code = %Style{fg: {:rgb, 191, 97, 106}, bg: {:rgb, 43, 48, 59}}
    paint = fn depth -> Theme.paint(code, %{depth: depth, mode: :dark}) end

    assert paint.(:truecolor) == %Style{fg: {:rgb, 191, 97, 106}}
    assert paint.(:x256) == %Style{fg: {:indexed, Theme.nearest256({191, 97, 106})}}
    assert paint.(:x16) == %Style{}
    assert paint.(:none) == %Style{}
    assert Theme.nearest256({255, 0, 128}) == 198
    assert Theme.nearest256({0, 0, 0}) == 16
  end

  ## The pink means one thing

  test "no tag the model draws is pink, except the ones that wait on a person" do
    tags =
      ~r/\{:([a-z_]+), /
      |> Regex.scan(File.read!("lib/troupe/ui/tui/model.ex"), capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.map(&String.to_atom/1)

    assert :pending in tags and :activity in tags and :heading in tags

    for tag <- tags, tag != :pending do
      role = role_of(View.segment_style(tag, tag, "anything"))
      refute role in @reserved, "#{tag} is drawn in #{role}"
    end

    assert role_of(View.segment_style(:pending, :pending, "APPROVAL: x")) == :needs_you
    assert role_of(View.segment_style(:activity, :activity, "waiting for you")) == :needs_you
    assert role_of(View.segment_style(:activity, :activity, "thinking (00:03)")) == :working
  end

  defp role_of(%Style{fg: {:role, role}}), do: role
  defp role_of(%Style{}), do: nil

  ## On screen, at each depth

  @depths [
    truecolor: {:rgb, 255, 0, 128},
    x256: {:indexed, 198},
    x16: :magenta
  ]

  for {depth, pink} <- @depths do
    test "an approval at #{depth}: the pink is on what waits on you, and nowhere else" do
      depth = unquote(depth)
      pink = unquote(Macro.escape(pink))
      cells = draw(approval_model(), %{depth: depth, mode: :dark})
      rows = Enum.group_by(cells, & &1.row)

      # The tray over the pane is the window's tile, three rows: its border, its title and
      # "waiting for you" are all the reserved colour. Below it, every run of pink cells is
      # part of what asks: the pending line in the pane and in the side panel, and the
      # status line's count and how to answer.
      allowed = [
        "APPROVAL: edit_file (y allow / n deny / a allow for session)",
        "approval: edit_file (y / n / a)",
        "1 need input · press 1 (or Enter, or click the window) to answer"
      ]

      runs = pink_runs(cells, pink)
      assert runs != []

      for {row, text} <- runs, row > 2 do
        assert Enum.any?(allowed, &String.contains?(&1, String.trim(text))),
               "#{inspect(text)} on row #{row} is pink"
      end

      assert at(rows, row_containing(rows, "APPROVAL: edit_file"), "APPROVAL").fg == pink
      assert at(rows, row_containing(rows, "to answer"), "1 need input").fg == pink
      assert at(rows, 1, "waiting for you").fg == pink

      # The other lights are still there: the accent on the heading, the diff's colours.
      assert at(rows, row_containing(rows, "The plan"), "The plan").fg ==
               Theme.color(:accent, %{depth: depth, mode: :dark})

      assert at(rows, row_containing(rows, "+def parse"), "+def").fg ==
               Theme.color(:added, %{depth: depth, mode: :dark})
    end
  end

  test "an approval with no colour: every cell in the terminal's own ink, the words still there" do
    cells = draw(approval_model(), %{depth: :none, mode: :dark})

    assert Enum.all?(cells, &(&1.fg == :reset and &1.bg == :reset))
    text = cells |> Enum.group_by(& &1.row) |> Enum.map_join("\n", fn {_r, cs} -> line(cs) end)
    assert text =~ "APPROVAL: edit_file"
    assert text =~ "1 need input"
  end

  test "the light values on a light terminal" do
    cells = draw(approval_model(), %{depth: :truecolor, mode: :light})
    rows = Enum.group_by(cells, & &1.row)
    assert at(rows, row_containing(rows, "APPROVAL"), "APPROVAL").fg == {:rgb, 196, 0, 95}
  end

  ## The mask

  test "the empty screen is the mask over the word, its lit half in the brand's pink" do
    cells = draw(Model.new("s-1", "/w"), %{depth: :truecolor, mode: :dark}, focus: :command)
    blocks = Enum.filter(cells, &(&1.symbol in ["▀", "▄", "█"]))
    {mask_w, _} = Theme.mask_size(:large)

    assert blocks != []
    left = blocks |> Enum.map(& &1.col) |> Enum.min()
    lit = Enum.filter(blocks, &({:rgb, 255, 0, 128} in [&1.fg, &1.bg]))

    # Light from the right: every lit cell is in the right half, and never mirrored.
    assert lit != []
    assert Enum.all?(lit, &(&1.col >= left + div(mask_w, 2)))

    text = cells |> Enum.group_by(& &1.row) |> Enum.map_join("\n", fn {_r, cs} -> line(cs) end)
    assert text =~ "troupe"
    assert text =~ "No branches. Type a command:"
  end

  test "HQ wears the lockup over its lists, and a session waiting on you is pink in it" do
    session = fn id, status ->
      %{
        id: id,
        title: "session #{id}",
        owner: "martin",
        team: "core",
        profile: "build",
        state: :active,
        status: status,
        origin: {:remote, "https://plane.example.test"},
        branches: []
      }
    end

    hq = %{
      origin: {:remote, "https://plane.example.test"},
      workspace: "/w",
      teams: [%{id: "core", name: "core"}],
      profiles: [],
      sessions: [session.("s-2", "waiting"), session.("s-3", "working")],
      column: :sessions,
      cursors: %{teams: 0, profiles: 0, sessions: 1},
      status: %{up?: true},
      error: nil,
      create: nil
    }

    pink = {:rgb, 255, 0, 128}
    cells = draw(Model.new("s-1", "/w"), %{depth: :truecolor, mode: :dark}, focus: :hq, hq: hq)
    rows = Enum.group_by(cells, & &1.row)

    assert Enum.any?(cells, &(&1.bg == pink or (&1.fg == pink and &1.symbol in ["▀", "▄", "█"])))
    assert at(rows, row_containing(rows, "troupe"), "troupe").fg == :reset
    assert at(rows, row_containing(rows, "need you"), "1 need you").fg == pink
    assert at(rows, row_containing(rows, "session s-2"), "session s-2").fg == pink
    refute at(rows, row_containing(rows, "session s-3"), "session s-3").fg == pink
  end

  test "with no colour, the mask's lit half is solid ink against the hollow one" do
    cells = draw(Model.new("s-1", "/w"), %{depth: :none, mode: :dark}, focus: :command)
    assert Enum.count(cells, &(&1.symbol == "█")) > 20
    assert Enum.all?(cells, &(&1.fg == :reset and &1.bg == :reset))
  end

  test "the mask keeps the design's rules: lit on the right, eyes and nothing else inside" do
    for cut <- [:large, :small] do
      rows = Palette.mask(cut)
      width = String.length(hd(rows))
      assert rem(length(rows), 2) == 0

      pixels =
        for {row, y} <- Enum.with_index(rows),
            {p, x} <- Enum.with_index(String.to_charlist(row)),
            do: {p, x, y}

      assert Enum.all?(for({?f, x, _} <- pixels, do: x >= div(width, 2)))
      assert Enum.all?(for({?c, x, _} <- pixels, do: x >= div(width, 2)))
      assert Enum.all?(for({?e, x, _} <- pixels, do: x < div(width, 2)))

      # Two eyes, one to a half, on the same rows, and no mouth: nothing else is cut out.
      eye_rows = for {p, _x, y} <- pixels, p in [?e, ?c], uniq: true, do: y
      assert eye_rows != [] and Enum.max(eye_rows) - Enum.min(eye_rows) <= 1
      assert Enum.min(eye_rows) < div(length(rows), 2), "the eyes sit in the upper half"
    end
  end

  ## Drawing

  defp draw(model, theme, opts \\ []) do
    {width, height} = {120, 40}

    state = %{
      session_id: "s-1",
      workspace: "/w",
      model: model,
      focus: Keyword.get(opts, :focus, {:window, "root"}),
      cmd_text: "",
      cmd_pos: 0,
      win_text: "",
      win_pos: 0,
      agents: ["code", "plan"],
      commands: [],
      palette: nil,
      tick: 0,
      now: 0,
      quit_armed: false,
      win_armed: nil,
      expanded: true,
      pane: %{agent: nil, scroll: :follow, seen_entries: 0},
      selection: nil,
      answer: nil,
      size: {width, height},
      hq: Keyword.get(opts, :hq),
      theme: theme
    }

    session = CellSession.new(width, height)
    :ok = CellSession.draw(session, View.render(state, %Frame{width: width, height: height}))
    CellSession.take_cells(session).cells
  end

  # Runs of horizontally adjacent cells drawn in `pink`, as `{row, text}`.
  defp pink_runs(cells, pink) do
    cells
    |> Enum.filter(&(&1.fg == pink or &1.bg == pink))
    |> Enum.sort_by(&{&1.row, &1.col})
    |> Enum.chunk_while(
      [],
      fn
        cell, [prev | _] = run when cell.row == prev.row and cell.col == prev.col + 1 ->
          {:cont, [cell | run]}

        cell, [] ->
          {:cont, [cell]}

        cell, run ->
          {:cont, Enum.reverse(run), [cell]}
      end,
      fn
        [] -> {:cont, []}
        run -> {:cont, Enum.reverse(run), []}
      end
    )
    |> Enum.map(fn [first | _] = run -> {first.row, Enum.map_join(run, & &1.symbol)} end)
  end

  defp row_containing(rows, text) do
    Enum.find_value(rows, fn {row, cells} -> if line(cells) =~ text, do: row end)
  end

  defp line(cells), do: cells |> Enum.sort_by(& &1.col) |> Enum.map_join("", & &1.symbol)

  # The cell where `text` starts on a row.
  defp at(rows, row, text) do
    cells = rows |> Map.fetch!(row) |> Enum.sort_by(& &1.col)
    {prefix, _} = cells |> Enum.map_join("", & &1.symbol) |> :binary.match(text)
    Enum.at(cells, String.length(binary_part(line(cells), 0, prefix)))
  end

  defp hex({r, g, b}),
    do: "#" <> Enum.map_join([r, g, b], &String.pad_leading(Integer.to_string(&1, 16), 2, "0"))

  # A turn with the kinds of line a reply has — a heading, a list, inline and fenced code,
  # a command that worked and one that failed — ending in an edit that waits for approval.
  defp approval_model do
    reply = """
    ## The plan

    The failure is in `parse/1`:

    - it drops the last line
    - and the test says so

    ```elixir
    def parse(x), do: x
    ```
    """

    diff = """
    --- a/lib/p.ex
    +++ b/lib/p.ex
    @@ -1 +1 @@
    -def parse(x), do: nil
    +def parse(x), do: x\
    """

    fold([
      {"user_input", %{"source" => "user", "text" => "fix the failing test"}},
      {"llm_response",
       %{"message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => reply}]}}},
      {"tool_call_started",
       %{"call_id" => "c1", "name" => "shell", "args" => %{"command" => "mix test"}}},
      {"tool_call_completed",
       %{"call_id" => "c1", "name" => "shell", "ok" => true, "content" => "1 failure"}},
      {"tool_call_started",
       %{"call_id" => "c2", "name" => "read_file", "args" => %{"path" => "nope"}}},
      {"tool_call_completed",
       %{"call_id" => "c2", "name" => "read_file", "ok" => false, "content" => "no such file"}},
      {"tool_call_started",
       %{"call_id" => "c3", "name" => "edit_file", "args" => %{"path" => "lib/p.ex"}}},
      {"approval_requested",
       %{"call_id" => "c3", "tool" => "edit_file", "agent_path" => ["root"], "preview" => diff}}
    ])
  end

  defp fold(events) do
    {model, _memory} =
      events
      |> Enum.with_index(1)
      |> Enum.reduce({Model.new("s-1", "/w"), Translate.memory()}, fn {{type, data}, seq},
                                                                      {model, memory} ->
        {local, memory} = Translate.durable("s-1", durable(type, data, seq), memory)
        {Enum.reduce(local, model, &Model.apply(&2, &1)), memory}
      end)

    model
  end

  defp durable(type, data, seq) do
    %{
      "seq" => seq,
      "prev_hash" => "sha256:abc",
      "ts" => "2026-09-27T10:00:00.000Z",
      "actor" => %{"kind" => "user", "subject" => "idp|martin", "display_name" => "Martin"},
      "agent" => ["root"],
      "type" => type,
      "v" => 1,
      "data" => data
    }
  end
end
