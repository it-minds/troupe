defmodule Troupe.Protocol.Sensitive do
  @moduledoc """
  A sensitive session, in the words the plane, a pod and a daemon share.

  A worker profile's `spec.sensitive` says which tool calls make a session on its pods
  sensitive (`markedBy`), which calls a sensitive session is refused (`deny`), and what a
  person may do with a sensitive session beyond the people who read it now (`sharing`).
  Both lists are rules in the per-tool rule grammar (`Troupe.Protocol.PermissionRule`), so
  `mcp(records.*)`, `read_file(/mnt/records/**)` and `shell(psql)` mean what they mean
  under `permissions`. Nothing clears the mark: a sensitive session is sensitive until it
  is erased.

  `sharing` is an order, the loosest first: `allow` (the default), `ask` (a team
  administrator's yes first) and `deny`. A profile that extends another may only tighten
  its parent's.
  """

  alias Troupe.Protocol.PermissionRule

  @lists ~w(markedBy deny)
  @keys @lists ++ ["sharing"]
  @sharings ~w(allow ask deny)
  @max_rules 200

  @doc "What `sharing` may be, the loosest first."
  @spec sharings() :: [String.t()]
  def sharings, do: @sharings

  @doc "The keys `spec.sensitive` takes."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc "How many rules each list may hold, as each list of `permissions` may."
  @spec max_rules() :: pos_integer()
  def max_rules, do: @max_rules

  @doc "`sharing` as a profile's `spec.sensitive` says it, `allow` where it says none."
  @spec sharing(map() | nil) :: String.t()
  def sharing(%{"sharing" => sharing}) when sharing in @sharings, do: sharing
  def sharing(_sensitive), do: "allow"

  @doc "The tighter of two `sharing` words: `deny` over `ask` over `allow`."
  @spec tighter(String.t() | nil, String.t() | nil) :: String.t()
  def tighter(a, b) do
    Enum.max_by([word(a), word(b)], &rank/1)
  end

  defp rank(sharing), do: Enum.find_index(@sharings, &(&1 == sharing))

  defp word(sharing) when sharing in @sharings, do: sharing
  defp word(_none), do: "allow"

  @doc "Whether `a` is looser than `b` in the order of `sharings/0`."
  @spec looser?(String.t(), String.t()) :: boolean()
  def looser?(a, b), do: rank(word(a)) < rank(word(b))

  @doc """
  Why a profile's `spec.sensitive` could not stand, one sentence each, or `[]`. A rule the
  pods could not read is refused with the reader's sentence, and `markedBy` without `deny`
  is refused, because a session marked sensitive with nothing refused is a mark that does
  nothing the administrator could have meant.
  """
  @spec problems(term()) :: [String.t()]
  def problems(nil), do: []

  def problems(sensitive) when is_map(sensitive) do
    unknown =
      for key <- Map.keys(sensitive),
          key not in @keys,
          do: "sensitive takes markedBy, deny and sharing, not #{key}"

    unknown ++
      Enum.flat_map(@lists, &list_problems(&1, sensitive[&1])) ++
      sharing_problems(Map.get(sensitive, "sharing")) ++ explicit(sensitive)
  end

  def problems(_sensitive),
    do: [
      "sensitive is a map of markedBy, deny and sharing, such as " <>
        "{\"markedBy\": [\"mcp(records.*)\"], \"deny\": [\"publish_artifact\"]}"
    ]

  defp list_problems(_key, nil), do: []

  defp list_problems(key, rules) when is_list(rules) do
    count =
      if length(rules) > @max_rules,
        do: ["sensitive.#{key} holds at most #{@max_rules} rules, not #{length(rules)}"],
        else: []

    count ++
      for text <- rules,
          {:error, why} <- [PermissionRule.parse(text)],
          do: "sensitive.#{key}: #{why}"
  end

  defp list_problems(key, _rules),
    do: ["sensitive.#{key} is a list of rules, such as [\"mcp(records.*)\"]"]

  defp sharing_problems(nil), do: []
  defp sharing_problems(sharing) when sharing in @sharings, do: []

  defp sharing_problems(sharing),
    do: ["sensitive.sharing must be allow, ask or deny, not #{inspect(sharing)}"]

  defp explicit(%{"markedBy" => [_ | _]} = sensitive) do
    case sensitive["deny"] do
      [_ | _] ->
        []

      _none ->
        [
          "sensitive.markedBy is set and sensitive.deny is not: say which tools a sensitive " <>
            "session is refused in sensitive.deny, such as [\"publish_artifact\", " <>
            "\"web_fetch\", \"remember\"], or take markedBy out"
        ]
    end
  end

  defp explicit(_sensitive), do: []

  @doc """
  The sentence a share of a sensitive session beyond its present readers is refused with
  where its profile's `sharing` is `deny`, naming the profile and the team or teams that
  read it now.
  """
  @spec sharing_refused(String.t() | nil, [String.t()]) :: String.t()
  def sharing_refused(profile, teams) do
    readers =
      case teams do
        [] -> "the people who already read it"
        [team] -> "the team that already reads it, #{team}"
        teams -> "the teams that already read it, " <> Troupe.Protocol.Words.and_list(teams)
      end

    "This session is sensitive and #{profile || "its profile"} does not allow sharing it " <>
      "outside #{readers}"
  end

  @doc "What the owner is told while a share of a sensitive session waits."
  @spec waiting() :: String.t()
  def waiting,
    do:
      "This session is sensitive, so sharing it wider is waiting on a team administrator: " <>
        "the people who read it now go on reading it"

  @doc """
  The sentence a sensitive session's proposal for a team's or the organisation's memory is
  refused with, for its agent to relay. The person's own memory is still its to write
  where the profile does not refuse `remember`.
  """
  @spec no_proposals() :: String.t()
  def no_proposals,
    do:
      "this session is sensitive, and a sensitive session proposes nothing for a team's or " <>
        "the organisation's memory: what it read must not leave it; nothing was proposed. " <>
        "Say what you would have proposed to the person instead"

  @doc "The sentence a sensitive session's publication is refused with, naming the profile."
  @spec no_publication(String.t() | nil) :: String.t()
  def no_publication(profile),
    do:
      "this session is sensitive, and #{profile || "its profile"} refuses publish_artifact in " <>
        "a sensitive session: nothing was published"
end
