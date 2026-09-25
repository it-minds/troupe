defmodule Troupe.UI.ModelError do
  @moduledoc """
  What a person does about a failed model request, where there is one obvious thing.

  A machine with no usable model settings is the commonest first run, and it fails on
  the first model request with "no API key is configured"; `troupe config` is what sets
  a provider up. The headless printer and the terminal UI print the step under the
  error in the same words, and they are the words `troupe config` ends with. The desktop
  app puts its own step under the same two errors, for a session on that computer.

  A session on a plane's worker uses the plane's key, which `troupe config` cannot
  change: its translation (`Troupe.Remote.Translate`) gives the error a `next_step` of its
  own, which wins.
  """

  @doc """
  The next step for a model error — its message, or the `:llm_error` event's data — or
  `nil` when there is no obvious one.
  """
  @spec next_step(String.t() | map()) :: String.t() | nil
  def next_step(%{next_step: step}) when is_binary(step), do: step
  def next_step(%{message: message}), do: next_step(message)
  def next_step("no API key is configured" <> _), do: "run `troupe config` to set up a provider"

  def next_step("the provider rejected the credentials" <> _),
    do: "check the provider's key: `troupe config` shows what is set"

  def next_step(_message), do: nil
end
