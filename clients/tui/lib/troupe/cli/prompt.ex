defmodule Troupe.CLI.Prompt do
  @moduledoc """
  A line typed at the console on Windows, read key by key (#231, TUI Decision 128).

  There the binary's VM reads nothing from the console until asked, and the console makes
  no line end of Enter while troupe runs (`rel/vm.args.eex`): a cooked read waits for one
  that never comes. So a question turns the VM's reader on raw, takes the keys one at a
  time, and does what the console's own line editing would have done: echoes them, or
  not for a secret; lets Backspace take the last one back; drops the escape sequence an
  arrow key sends; and ends at Enter. Ctrl-C, a key there too, does what a Ctrl-C does to
  a command at a prompt: ends it, with status 130.
  """

  @doc """
  Ask, and return the line typed, or `nil` at the end of input.

  `:echo` (default `true`) shows what is typed. `:key` reads one key, `:raw` switches the
  reader between raw and cooked, and `:interrupt` is what Ctrl-C does once the reader is
  cooked again (it halts the VM), so a test can play the keyboard.
  """
  @spec read(String.t(), keyword()) :: String.t() | nil
  def read(prompt, opts \\ []) do
    raw = Keyword.get(opts, :raw, &raw/1)
    raw.(true)

    line =
      try do
        IO.write(prompt)
        keys(Keyword.get(opts, :key, &key/0), Keyword.get(opts, :echo, true), [])
      after
        raw.(false)
      end

    if line == :interrupted, do: Keyword.get(opts, :interrupt, &interrupted/0).(), else: line
  end

  defp keys(key, echo?, typed) do
    case key.() do
      enter when enter in ["\r", "\n"] ->
        IO.write("\r\n")
        typed |> Enum.reverse() |> Enum.join()

      <<3>> ->
        IO.write("^C\r\n")
        :interrupted

      erase when erase in ["\d", "\b"] ->
        case typed do
          [] ->
            keys(key, echo?, typed)

          [_ | rest] ->
            if echo?, do: IO.write("\b \b")
            keys(key, echo?, rest)
        end

      "\e" ->
        skip_sequence(key)
        keys(key, echo?, typed)

      <<c::utf8>> = char when c >= 0x20 ->
        if echo?, do: IO.write(char)
        keys(key, echo?, [char | typed])

      char when is_binary(char) ->
        keys(key, echo?, typed)

      _eof ->
        IO.write("\r\n")
        nil
    end
  end

  # `ESC [ … final` or `ESC O final`: what an arrow, Home or a function key sends.
  defp skip_sequence(key) do
    case key.() do
      intro when intro in ["[", "O"] -> skip_to_final(key)
      _other -> :ok
    end
  end

  defp skip_to_final(key) do
    case key.() do
      <<c>> when c in 0x40..0x7E -> :ok
      char when is_binary(char) -> skip_to_final(key)
      _eof -> :ok
    end
  end

  defp key, do: IO.getn("", 1)

  defp interrupted, do: System.halt(130)

  defp raw(true) do
    :shell.start_interactive({:noshell, :raw})
    :io.setopts(echo: false)
  end

  defp raw(false), do: :shell.start_interactive({:noshell, :cooked})
end
