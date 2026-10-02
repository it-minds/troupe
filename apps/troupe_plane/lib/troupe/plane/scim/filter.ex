defmodule Troupe.Plane.SCIM.Filter do
  @moduledoc """
  The one SCIM filter the plane answers: `<attribute> eq "<value>"` (RFC 7644 §3.4.2.2).

  It is what a provisioning client asks before it creates somebody — is there already a
  user with this `userName`, a group with this `displayName` — and what a `PATCH` path
  uses to pick one member out of a group. Anything else is refused as `invalidFilter`
  rather than half-read: an endpoint that dropped a clause it did not understand would
  answer a wider question than the one asked, and the client reads the answer as a match.

  Attribute names and the operator are case-insensitive, as the RFC has them; the value is
  a JSON string, escapes and all.
  """

  @eq ~r/\A\s*([A-Za-z][A-Za-z0-9_$-]*)\s+eq\s+("(?:[^"\\]|\\.)*")\s*\z/iu

  @doc """
  Read a filter against the attributes it may name, given as `%{"userName" => :user_name}`.

  Returns the attribute's atom and the value, or the reason it was refused.
  """
  @spec parse(term(), %{String.t() => atom()}) ::
          {:ok, atom(), String.t()} | {:error, {String.t(), String.t()}}
  def parse(filter, attributes) when is_binary(filter) do
    with [_, name, literal] <- Regex.run(@eq, filter),
         {_name, attribute} <- Enum.find(attributes, &same_name?(&1, name)),
         {:ok, value} when is_binary(value) <- Jason.decode(literal) do
      {:ok, attribute, value}
    else
      _ -> refuse(attributes)
    end
  end

  def parse(_filter, attributes), do: refuse(attributes)

  defp same_name?({known, _attribute}, name), do: String.downcase(known) == String.downcase(name)

  defp refuse(attributes) do
    names = attributes |> Map.keys() |> Enum.sort() |> Enum.join(" or ")
    {:error, {"invalidFilter", "the filter supported here is #{names} eq \"<value>\""}}
  end
end
