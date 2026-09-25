defmodule Troupe.UI.ModelError do
  @moduledoc """
  What a person does about a failed model request, where there is one obvious thing.

  A machine with no usable model settings is the commonest first run, and it fails on
  the first model request with "no API key is configured"; `troupe config` is what sets
  a provider up. The headless printer and the terminal UI print the step under the
  error in the same words, and they are the words `troupe-daemon config` ends with.
  """

  @doc "The next step for a model error's message, or `nil` when there is no obvious one."
  @spec next_step(String.t()) :: String.t() | nil
  def next_step("no API key is configured" <> _), do: "run `troupe config` to set up a provider"

  def next_step("the provider rejected the credentials" <> _),
    do: "check the provider's key: `troupe config` shows what is set"

  def next_step(_message), do: nil
end
