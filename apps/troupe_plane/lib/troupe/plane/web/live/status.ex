defmodule Troupe.Plane.Web.Live.Status do
  @moduledoc """
  The console's status system: a glyph, a word and a colour, and never fewer than three.

  `DESIGN.md` §2 makes this the core of the product and §12 makes the rule explicit —
  *don't ship a status without all three of glyph, word and colour*, and *don't invent a
  tenth status*. Both are enforced here by construction rather than by review:

  * the states are read out of `docs/design/admin/tokens.json` **at compile time**, so
    the list in the design and the list in the code cannot drift, and adding one means
    adding a token with a glyph and a word;
  * `pill/1` and `cell/1` render all three together and there is no way to ask for one
    of them, so a bare coloured dot is not something a page can accidentally produce.

  A greyscale screenshot has to stay readable, which is why the word is not optional and
  why the glyphs are nine distinct marks rather than nine dots. That is a hard review
  criterion in the design, and the thing that makes it hold is that the word ships in the
  same function call as the colour.

  ## Mapping the platform onto the states

  The plane's own vocabulary is older than this design and does not use these words.
  `from_worker/1`, `from_session/1` and friends are the translation, in one place, so a
  page never decides for itself what "a worker with no heartbeat" looks like. Where the
  platform cannot tell the difference between two states the translation says so rather
  than guessing: silence is `unknown`, never `broken`.
  """

  use Phoenix.Component

  # `priv/design/statuses.json`, generated from the design tokens by
  # `mix troupe.admin.tokens` and committed. Read from the app's own `priv` rather than
  # from `docs/` because the image build copies `apps/`, `config/` and `mix.exs` and
  # nothing else: a module that compiled against the design directory built on a laptop
  # and failed in Docker, which is what it did.
  @statuses_path Path.join([
                   __DIR__,
                   "..",
                   "..",
                   "..",
                   "..",
                   "..",
                   "priv",
                   "design",
                   "statuses.json"
                 ])
  @external_resource Path.expand(@statuses_path)

  states =
    @statuses_path
    |> Path.expand()
    |> File.read!()
    |> Jason.decode!()
    |> Map.new(fn {key, value} ->
      {String.to_atom(key), %{glyph: value["glyph"], word: value["word"]}}
    end)

  # A state whose token lacks a glyph or a word fails the build rather than rendering as
  # a blank cell somebody notices in production.
  for {state, %{glyph: glyph, word: word}} <- states do
    if is_nil(glyph) or is_nil(word) do
      raise "status #{state} in tokens.json is missing a glyph or a word"
    end
  end

  @states states
  @names Map.keys(states)

  @type state :: atom()

  @doc "Every state the design defines, which is every state that may be rendered."
  @spec states() :: [state()]
  def states, do: @names

  @doc "The glyph and word for a state, for a caller that is not rendering HTML."
  @spec describe(state()) :: %{glyph: String.t(), word: String.t()}
  def describe(state) when is_map_key(@states, state), do: Map.fetch!(@states, state)

  @doc """
  A status as a pill: glyph, word, and the state's own background and border.

  For a heading or a title block, where the state is the subject. In a table cell use
  `cell/1`, which is the same three signals without the box.
  """
  attr(:state, :atom, required: true, values: @names)
  attr(:title, :string, default: nil)

  def pill(assigns) do
    assigns = assign(assigns, :status, Map.fetch!(@states, assigns.state))

    ~H"""
    <span class={"status status--pill status--#{@state}"} title={@title}>
      <span class="status__glyph" aria-hidden="true">{@status.glyph}</span>
      <span class="status__word">{@status.word}</span>
    </span>
    """
  end

  @doc """
  A status in a table cell: the same glyph and word, no box.

  §5 says the status column is glyph plus word and §2 says never a bare dot, so this
  renders both and there is no variant that renders one.
  """
  attr(:state, :atom, required: true, values: @names)
  attr(:title, :string, default: nil)

  def cell(assigns) do
    assigns = assign(assigns, :status, Map.fetch!(@states, assigns.state))

    ~H"""
    <span class={"status status--#{@state}"} title={@title}>
      <span class="status__glyph" aria-hidden="true">{@status.glyph}</span>
      <span class="status__word">{@status.word}</span>
    </span>
    """
  end

  @doc """
  The class a table row carries so a non-healthy row gets its 3px left marker.

  §5: *a non-healthy row carries a 3px left marker in its status colour.* Healthy rows
  get nothing, because a marker on every row is a marker on none.
  """
  @spec row_class(state()) :: String.t()
  def row_class(:healthy), do: ""
  def row_class(state) when is_map_key(@states, state), do: "row--marked row--#{state}"

  @doc """
  How bad a state is, for sorting worst-first.

  §2: *anything not healthy is sorted to the top of its list.* §7 forbids re-sorting a
  table because data arrived, so this orders a list when it is built or when the reader
  asks — never in response to an update.
  """
  # The order the design gives for Overview's attention list — broken, credential
  # missing, degraded, over budget, pending — extended to every state. Anything a person
  # must act on outranks anything that is merely in progress. Written as the list it is
  # rather than as a case, so the ordering can be read in one line and a state added to
  # the tokens without a rank fails the check below rather than sorting as "last".
  @ranked ~w(broken missingCredential rejected degraded disconnected unknown
             pending waiting draining running healthy dormant)a

  unranked = @names -- @ranked

  if unranked != [] do
    raise "status(es) #{inspect(unranked)} have no severity rank; add them to @ranked"
  end

  @severity @ranked |> Enum.with_index() |> Map.new()

  @spec severity(state()) :: non_neg_integer()
  def severity(state) when is_map_key(@severity, state), do: Map.fetch!(@severity, state)

  # -- translating the platform's own words -----------------------------------

  @doc """
  What a worker row's status is.

  Silence is `unknown` and not `broken`: §2 is explicit that marking a missing report as
  a failure is how a console cries wolf during a partition. A pod that is draining says
  so; one that is up but carrying fewer ready replicas than it asked for is `degraded`,
  which is still serving.
  """
  @spec from_worker(map()) :: state()
  def from_worker(%{draining: true}), do: :draining
  def from_worker(%{healthy: false, last_seen_at: nil}), do: :unknown
  def from_worker(%{healthy: false}), do: :broken

  def from_worker(%{ready: ready, desired: desired}) when is_integer(ready) and ready < desired,
    do: :degraded

  def from_worker(_worker), do: :healthy

  @doc """
  What a session row's status is.

  A dormant session is not a degraded one — it costs nothing and that is the design — so
  it has its own state and its own word, "Asleep".
  """
  @spec from_session(map()) :: state()
  def from_session(%{state: "dormant"}), do: :dormant
  def from_session(%{status: "waiting"}), do: :waiting
  def from_session(%{done_reason: reason}) when reason not in [nil, "finished"], do: :broken
  def from_session(%{status: status}) when status in ["thinking", "acting", "idle"], do: :healthy
  def from_session(_session), do: :unknown

  @doc "What a profile's rollout status is: committed here, or confirmed by the cluster."
  @spec from_rollout(map()) :: state()
  def from_rollout(%{rejected: reason}) when is_binary(reason), do: :rejected
  def from_rollout(%{pods_pending: n}) when is_integer(n) and n > 0, do: :waiting
  def from_rollout(%{confirmed: false}), do: :pending
  def from_rollout(_rollout), do: :healthy
end
