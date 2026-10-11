defmodule Troupe.Protocol.ClientUpdate do
  @moduledoc """
  A plane's version policy for one kind of client, and what it says to one client of that
  kind (#66, Decision 868).

  A plane holds, per component, a `recommended` version, a `minimum` and a `blocked` list.
  At `initialize` it reads the component from the name the client gives and judges the
  version it gives: on a blocked version, or below the minimum, the client is refused with
  `update_required`; otherwise the answer carries the policy as `client_update`, whose
  `action` is `suggest` where a newer version is recommended and `none` where not.

  Here rather than in the plane because three parties read it the same way: the plane
  judging, and the terminal and the daemon putting a refusal into words.

  Versions are ordered as SemVer orders them, which is how `troupe update` orders them too:
  `0.13.0-beta` comes before `0.13.1-beta`, and also before `0.13.0`, so a policy names a
  version as the release is named. A version SemVer cannot read is judged against the
  blocked list alone, since nothing can say what it is older than.
  """

  @components ~w(tui daemon desktop)

  @type component :: String.t()
  @type policy :: %{
          optional(:recommended | String.t()) => String.t() | nil,
          optional(:minimum | String.t()) => String.t() | nil,
          optional(:blocked | String.t()) => [String.t()]
        }

  @doc "The components a plane holds a policy for: the terminal, the daemon, the desktop app."
  @spec components() :: [component()]
  def components, do: @components

  @doc """
  The component a client is, from the `client_info.name` it gives at `initialize`:
  `troupe` and `troupe-headless` are the terminal (`tui`), `troupe-daemon` the daemon and
  `troupe-gui` the desktop app, the names PROTOCOL.md §3 gives them. Any other name is
  none of them, and a plane holds it to no policy.
  """
  @spec component(term()) :: component() | nil
  def component(name) when name in ["troupe", "troupe-headless"], do: "tui"
  def component("troupe-daemon"), do: "daemon"
  def component("troupe-gui"), do: "desktop"
  def component(_name), do: nil

  @doc "What a component is called in a sentence."
  @spec program(component() | nil) :: String.t()
  def program("tui"), do: "troupe"
  def program("daemon"), do: "troupe-daemon"
  def program("desktop"), do: "the desktop app"
  def program(_other), do: "this client"

  @doc """
  What a person runs to update a component, or `nil` where it is not a command: the
  desktop app has no updater of its own yet (a later slice of #66).
  """
  @spec run(component() | nil) :: String.t() | nil
  def run(component) when component in ["tui", "daemon"], do: "troupe update"
  def run(_component), do: nil

  @doc """
  What a policy says to one version.

  `{:refuse, :blocked}` on a blocked version, whatever its number; `{:refuse,
  :below_minimum}` below the minimum; otherwise `{:ok, "suggest"}` below the recommended
  version and `{:ok, "none"}` at it or past it.
  """
  @spec judge(policy(), String.t() | nil) ::
          {:ok, String.t()} | {:refuse, :blocked | :below_minimum}
  def judge(policy, version) do
    cond do
      is_binary(version) and version in blocked(policy) -> {:refuse, :blocked}
      older?(version, field(policy, :minimum)) -> {:refuse, :below_minimum}
      older?(version, field(policy, :recommended)) -> {:ok, "suggest"}
      true -> {:ok, "none"}
    end
  end

  @doc "Whether `a` is older than `b` as SemVer orders them; false where either is not one."
  @spec older?(term(), term()) :: boolean()
  def older?(a, b) when is_binary(a) and is_binary(b) do
    case {Version.parse(a), Version.parse(b)} do
      {{:ok, a}, {:ok, b}} -> Version.compare(a, b) == :lt
      _unparsed -> false
    end
  end

  def older?(_a, _b), do: false

  @doc "Whether a string is a version a policy can name: SemVer, as releases are numbered."
  @spec version?(term()) :: boolean()
  def version?(version) when is_binary(version), do: match?({:ok, _}, Version.parse(version))
  def version?(_version), do: false

  @doc """
  The `client_update` a plane answers `initialize` with: the component's policy, and what
  it means for the version the client gave.
  """
  @spec client_update(component(), policy(), String.t()) :: map()
  def client_update(component, policy, action) do
    %{
      "component" => component,
      "recommended" => field(policy, :recommended),
      "minimum" => field(policy, :minimum),
      "blocked" => blocked(policy),
      "action" => action
    }
  end

  @doc """
  The `data` of an `update_required` refusal: the component, the version the client gave,
  the policy's minimum and recommended versions, whether the version is blocked, what to
  run, and all of it as one sentence in `reason` for a client that shows only that.
  """
  @spec refusal(component(), String.t(), policy(), :blocked | :below_minimum) :: map()
  def refusal(component, version, policy, why) do
    data = %{
      "component" => component,
      "version" => version,
      "minimum" => field(policy, :minimum),
      "recommended" => field(policy, :recommended),
      "blocked" => why == :blocked,
      "run" => run(component)
    }

    Map.put(data, "reason", sentence(data))
  end

  @doc """
  The sentence a client shows for `update_required`, from the refusal's `data`.

  Built from the fields where they are there, so the terminal and the daemon word it the
  same whatever plane said it; a plane that sent only `reason` has that shown.
  """
  @spec sentence(map() | nil) :: String.t()
  def sentence(data) when is_map(data) do
    component = field(data, :component)
    version = field(data, :version)
    minimum = field(data, :minimum)

    cond do
      is_binary(version) and field(data, :blocked) == true ->
        "This plane does not serve #{program(component)} #{version}, which its administrators " <>
          "have blocked: #{remedy(component, data)}."

      is_binary(version) and is_binary(minimum) ->
        "This plane needs #{program(component)} #{minimum} or later, and this is #{version}: " <>
          "#{remedy(component, data)}."

      is_binary(field(data, :reason)) ->
        field(data, :reason)

      true ->
        "This plane needs a newer version of #{program(component)}: #{remedy(component, data)}."
    end
  end

  def sentence(_data), do: "This plane needs a newer version of this client."

  defp remedy(component, data) do
    recommended = field(data, :recommended)

    action =
      case field(data, :run) || run(component) do
        nil when component == "desktop" -> "install a newer desktop app"
        nil -> "install a newer version"
        command -> "run #{command}"
      end

    if is_binary(recommended), do: "#{action}, which installs #{recommended}", else: action
  end

  defp blocked(policy) do
    case field(policy, :blocked) do
      list when is_list(list) -> list
      _none -> []
    end
  end

  # A policy or a refusal as the plane built it (atom keys) or as JSON delivered it.
  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_map, _key), do: nil
end
