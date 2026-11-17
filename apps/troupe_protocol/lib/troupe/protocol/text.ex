defmodule Troupe.Protocol.Text do
  @moduledoc """
  Text cut to a size in bytes without leaving half a character behind.

  A field with a byte cap (a memory document, a skill's body, an issue's text, a blob's
  preview) is cut at a byte, and a byte can fall inside a character. What a client is
  sent must be valid UTF-8, so every such cut is this one.
  """

  @doc """
  The longest prefix of `binary`, at most `bytes` long, that is valid UTF-8.

  A cut inside a multibyte character drops the whole character. A binary that is not
  UTF-8 is kept up to its first invalid byte. A valid binary within `bytes` is answered
  as it is.
  """
  @spec cut(binary(), non_neg_integer()) :: String.t()
  def cut(binary, bytes) when is_binary(binary) and is_integer(bytes) and bytes >= 0 do
    part = binary_part(binary, 0, min(byte_size(binary), bytes))

    case :unicode.characters_to_binary(part) do
      valid when is_binary(valid) -> valid
      {:incomplete, valid, _rest} -> valid
      {:error, valid, _rest} -> valid
    end
  end
end
