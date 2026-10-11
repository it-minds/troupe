defmodule Troupe.Protocol.Organisation do
  @moduledoc """
  What an organisation may hold people's own machines to (#122, Decision 869): the keys
  of `config.yaml` it may enforce, what enforcing each one means, and the check an
  enforced set is put through.

  Here rather than in the core because two parties read it the same way: the plane,
  which refuses an administrator's enforced set when it names a key that is not on the
  list, and the machine, which holds its configuration to the set it is given.
  `Troupe.Config.Schema` marks the same keys, and a test holds the two together.

  An enforced value is a ceiling. What that means depends on the key:

    * `:ceiling`, a number: a lower layer may lower it and not raise it;
    * `{:order, values}`, a value with a stricter end (`approvals`: `wait`, then `deny`;
      a switch: off, then on): a lower layer may tighten it and not loosen it;
    * `:fixed`, `provider` and `base_url`, which have no stricter end: the value is what
      the organisation says.

  Nothing else can be enforced. A key that is not on the list is refused with
  `refusal/1`, on the plane when an administrator sets it and on the machine when it
  reads it.
  """

  @type kind :: :ceiling | :fixed | {:order, [term()]}

  # In the order `troupe config --explain` and the docs list them: what may run unasked
  # first, then where the requests go, then the switches, then the budget.
  @enforceable [
    {"approvals", {:order, ["wait", "deny"]}, {:enum, ["wait", "deny"]}},
    {"provider", :fixed, {:enum, ["anthropic", "openai", "fake"]}},
    {"base_url", :fixed, :string},
    {"managed_mcp_servers_only", {:order, [false, true]}, :boolean},
    {"managed_permission_rules_only", {:order, [false, true]}, :boolean},
    {"max_tokens", :ceiling, {:integer, 1}},
    {"max_turns", :ceiling, {:integer, 1}},
    {"wall_clock_ms", :ceiling, {:integer, 1}},
    {"max_depth", :ceiling, {:integer, 0}}
  ]

  @doc "The keys an organisation may enforce, in the order they are listed."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(@enforceable, &elem(&1, 0))

  @doc "What enforcing `key` means, or `nil` for a key that cannot be enforced."
  @spec kind(String.t()) :: kind() | nil
  def kind(key) do
    case List.keyfind(@enforceable, key, 0) do
      {_key, kind, _type} -> kind
      nil -> nil
    end
  end

  @doc """
  The value type of an enforceable key, as `Troupe.Config.Schema` writes types:
  `{:enum, values}`, `:string`, `:boolean` or `{:integer, min}`.
  """
  @spec type(String.t()) :: term()
  def type(key) do
    case List.keyfind(@enforceable, key, 0) do
      {_key, _kind, type} -> type
      nil -> nil
    end
  end

  @doc "The sentence a key that cannot be enforced is refused with."
  @spec refusal(String.t()) :: String.t()
  def refusal(key) do
    {rest, [last]} = Enum.split(keys(), -1)

    "#{key} is not a key an organisation may enforce; the ones it may are " <>
      Enum.join(rest, ", ") <> " and " <> last
  end

  @doc """
  Check an enforced set as an administrator sends it: every key enforceable and every
  value of its type. `null` is a key not enforced, and is left out. Answers the set, or
  every reason it is refused.
  """
  @spec check(term()) :: {:ok, %{String.t() => term()}} | {:error, [String.t()]}
  def check(set) when is_map(set) do
    {kept, reasons} =
      set
      |> Enum.sort()
      |> Enum.reduce({%{}, []}, fn
        {_key, nil}, acc ->
          acc

        {key, value}, {kept, reasons} ->
          key = to_string(key)

          cond do
            kind(key) == nil ->
              {kept, reasons ++ [refusal(key)]}

            valid?(value, type(key)) ->
              {Map.put(kept, key, value), reasons}

            true ->
              {kept, reasons ++ ["#{key} must be #{describe(type(key))}, not #{inspect(value)}"]}
          end
      end)

    if reasons == [], do: {:ok, kept}, else: {:error, reasons}
  end

  def check(_set), do: {:error, ["the enforced set must be an object of keys and values"]}

  defp valid?(value, {:enum, values}), do: is_binary(value) and value in values
  defp valid?(value, :string), do: is_binary(value) and value != ""
  defp valid?(value, :boolean), do: is_boolean(value)
  defp valid?(value, {:integer, min}), do: is_integer(value) and value >= min

  defp describe({:enum, values}), do: "one of " <> Enum.join(values, ", ")
  defp describe(:string), do: "a non-empty string"
  defp describe(:boolean), do: "true or false"
  defp describe({:integer, 0}), do: "a whole number, 0 or more"
  defp describe({:integer, min}), do: "a whole number, at least #{min}"

  @doc """
  Whether `value` goes past `limit`: above a ceiling, looser than an order's limit, or
  anything but a fixed value. An atom is read as its name, so a struct's `:wait` is the
  file's `wait`.
  """
  @spec exceeds?(kind(), term(), term()) :: boolean()
  def exceeds?(kind, value, limit), do: past?(kind, plain(value), plain(limit))

  defp past?(:ceiling, value, limit) when is_number(value) and is_number(limit), do: value > limit
  defp past?(:ceiling, _value, _limit), do: false
  defp past?(:fixed, value, limit), do: value != limit

  defp past?({:order, values}, value, limit) do
    case {index(values, value), index(values, limit)} do
      {nil, _limit} -> false
      {_value, nil} -> false
      {v, l} -> v < l
    end
  end

  @doc "What a value is held to: itself where it is within the limit, the limit where not."
  @spec hold(kind(), term(), term()) :: term()
  def hold(kind, value, limit) do
    if exceeds?(kind, value, limit), do: plain(limit), else: plain(value)
  end

  @doc "What a kind of limit means, in words: what the value is to a lower layer."
  @spec meaning(kind()) :: String.t()
  def meaning(:ceiling), do: "the most it may be"
  def meaning(:fixed), do: "what it is"
  def meaning({:order, _values}), do: "the loosest it may be"

  defp index(values, value), do: Enum.find_index(values, &(&1 == value))

  defp plain(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp plain(value), do: value
end
