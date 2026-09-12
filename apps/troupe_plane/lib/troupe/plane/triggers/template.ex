defmodule Troupe.Plane.Triggers.Template do
  @moduledoc """
  The smallest useful subset of Mustache: `{{a.b.c}}` and nothing else.

  A prompt template needs to say `{{event.issue.key}}`; anything that can loop, branch
  or call is more than a prompt template should be able to do, and every construct left
  out is one an event cannot smuggle behaviour through. Nothing is escaped, because the
  output is a prompt and not HTML. A path that leads nowhere renders as nothing rather
  than as an error: a template written for one provider's events should survive another
  provider's leaving a field out.
  """

  @placeholder ~r/\{\{\s*([A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*)\s*\}\}/

  @doc "Render a template against a map of string-keyed values."
  @spec render(String.t() | nil, map()) :: String.t()
  def render(nil, _values), do: ""

  def render(template, values) when is_binary(template) and is_map(values) do
    Regex.replace(@placeholder, template, fn _whole, path ->
      path |> String.split(".") |> lookup(values) |> text()
    end)
  end

  defp lookup([], value), do: value

  defp lookup([key | rest], %{} = map) do
    case Map.fetch(map, key) do
      {:ok, value} -> lookup(rest, value)
      :error -> nil
    end
  end

  # A list is addressed by position, so `{{event.labels.0}}` works the way a person
  # reading the event JSON would expect.
  defp lookup([key | rest], list) when is_list(list) do
    case Integer.parse(key) do
      {index, ""} when index >= 0 -> lookup(rest, Enum.at(list, index))
      _ -> nil
    end
  end

  defp lookup(_path, _other), do: nil

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp text(value), do: Jason.encode!(value)
end
