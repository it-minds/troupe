defmodule Troupe.Config.JSONC do
  @moduledoc "Lenient JSON: strips `//` and `/* */` comments and trailing commas, then decodes with Jason."

  @spec decode(String.t()) :: {:ok, term()} | {:error, term()}
  def decode(text) when is_binary(text) do
    text |> strip_comments() |> strip_trailing_commas() |> Jason.decode()
  end

  @doc false
  def strip_comments(text), do: do_strip(text, :code, [])

  # states: :code | :string | :line_comment | :block_comment
  defp do_strip(<<>>, _state, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp do_strip(<<"\\", c, rest::binary>>, :string, acc),
    do: do_strip(rest, :string, [<<"\\", c>> | acc])

  defp do_strip(<<"\"", rest::binary>>, :string, acc), do: do_strip(rest, :code, ["\"" | acc])

  defp do_strip(<<c::utf8, rest::binary>>, :string, acc),
    do: do_strip(rest, :string, [<<c::utf8>> | acc])

  defp do_strip(<<"\"", rest::binary>>, :code, acc), do: do_strip(rest, :string, ["\"" | acc])
  defp do_strip(<<"//", rest::binary>>, :code, acc), do: do_strip(rest, :line_comment, acc)
  defp do_strip(<<"/*", rest::binary>>, :code, acc), do: do_strip(rest, :block_comment, acc)

  defp do_strip(<<c::utf8, rest::binary>>, :code, acc),
    do: do_strip(rest, :code, [<<c::utf8>> | acc])

  defp do_strip(<<"\n", rest::binary>>, :line_comment, acc), do: do_strip(rest, :code, ["\n" | acc])

  defp do_strip(<<_::utf8, rest::binary>>, :line_comment, acc),
    do: do_strip(rest, :line_comment, acc)

  defp do_strip(<<"*/", rest::binary>>, :block_comment, acc), do: do_strip(rest, :code, acc)

  defp do_strip(<<_::utf8, rest::binary>>, :block_comment, acc),
    do: do_strip(rest, :block_comment, acc)

  @doc false
  def strip_trailing_commas(text), do: Regex.replace(~r/,(\s*[}\]])/, text, "\\1")
end
