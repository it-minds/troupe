defmodule Troupe.Plane.ClientVersions do
  @moduledoc """
  Which versions of its clients this plane serves (#66 slice 1b, Decision 868).

  Per component — the terminal (`tui`), the daemon, the desktop app — three things an
  administrator decides:

  * `recommended`: the version clients are nudged to, and the one `troupe update` installs
    for a person signed in here;
  * `minimum`: the oldest version this plane serves. A client below it is refused at
    `initialize` with `update_required`, and told to run `troupe update`;
  * `blocked`: versions it serves to nobody, whatever their number — a release with a
    defect nobody should keep running.

  `Troupe.Protocol.ClientUpdate` is what reads them, the same way on the plane and in the
  clients. This module only keeps them: one row per component, written the first time an
  administrator sets something, so a plane with no row holds no policy for that component
  and refuses nobody.

  ## Why the policy carries no signature of its own

  It travels on the plane's authenticated connection, to a client that already chose to
  trust this plane with its sign-in, and it can only narrow what a client does: refuse to
  serve it, or name a version for `troupe update` to install, which is still installed only
  if the release key signed it. A plane, or whoever holds its database, can hold a fleet
  back or tell it to move; it cannot make a client run anything the release key did not
  sign. A signed channel document (#66) is what lets the policy outlive the connection —
  cached, checked offline, pinned to the plane that signed it — and is later work.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Troupe.Plane.Repo
  alias Troupe.Protocol.ClientUpdate

  require Logger

  @primary_key {:component, :string, autogenerate: false}

  schema "client_versions" do
    field(:recommended, :string)
    field(:minimum, :string)
    field(:blocked, {:array, :string}, default: [])
    field(:updated_by, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  # What `put/3` reads from a policy, and what `admin.clients.put` declares it takes.
  @keys ~w(recommended minimum blocked)

  @doc "The keys a policy has, as `admin.clients.put` takes them."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc "The components a policy is held for."
  @spec components() :: [String.t()]
  def components, do: ClientUpdate.components()

  @doc """
  Every component's policy, as an administrator reads it: what is set, who set it last and
  when. A component nobody has set anything for reads as empty.
  """
  @spec all() :: %{String.t() => map()}
  def all do
    rows = Map.new(stored(), &{&1.component, &1})
    Map.new(components(), fn component -> {component, describe(rows[component], component)} end)
  end

  @doc """
  One component's policy, as `ClientUpdate` reads it: `%{recommended, minimum, blocked}`,
  empty where nothing is set. A database that cannot be read is no policy, logged: a plane
  that could not say which versions it serves should go on serving them rather than turn
  every client away.
  """
  @spec policy(String.t()) :: map()
  def policy(component) do
    case Enum.find(stored(), &(&1.component == component)) do
      nil -> %{recommended: nil, minimum: nil, blocked: []}
      row -> Map.take(row, [:recommended, :minimum, :blocked])
    end
  end

  @doc """
  Change one component's policy.

  Only the keys sent change; a key sent as `null` is cleared, and `blocked` is the whole
  list. Every version must be one SemVer reads, the minimum may not be newer than the
  recommended version, and the recommended version may not be blocked: each refusal says
  which, and nothing is written. Answers the policy as it now stands, and the one before.
  """
  @spec put(String.t(), map(), String.t()) ::
          {:ok, %{before: map(), now: map()}} | {:error, map()}
  def put(component, attrs, by) do
    with :ok <- known(component),
         {:ok, changes} <- read(attrs) do
      row = Repo.get(__MODULE__, component) || %__MODULE__{component: component}
      before = describe(row, component)

      changeset =
        row
        |> change(changes)
        |> put_change(:updated_by, by)

      with :ok <- coherent(Map.merge(Map.from_struct(row), changes)) do
        stored = Repo.insert_or_update!(changeset)
        {:ok, %{before: before, now: describe(stored, component)}}
      end
    end
  end

  defp known(component) do
    if component in components(),
      do: :ok,
      else:
        {:error,
         %{
           field: "component",
           reason:
             "a policy is held for #{Enum.join(components(), ", ")}; not #{inspect(component)}"
         }}
  end

  # The keys sent, each read: a version, `null` to clear one, a list of versions for
  # `blocked`. A leading `v`, as tags are written, is taken off.
  defp read(attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    @keys
    |> Enum.filter(&Map.has_key?(attrs, &1))
    |> Enum.reduce_while({:ok, %{}}, fn key, {:ok, acc} ->
      case value(key, attrs[key]) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, String.to_existing_atom(key), value)}}
        {:error, why} -> {:halt, {:error, %{field: key, reason: why}}}
      end
    end)
  end

  defp read(_attrs), do: {:error, %{field: "policy", reason: "a policy is an object"}}

  defp value("blocked", nil), do: {:ok, []}

  defp value("blocked", list) when is_list(list) do
    versions = Enum.map(list, &version/1)

    case Enum.find_index(versions, &(&1 == :error)) do
      nil ->
        {:ok, versions |> Enum.map(&elem(&1, 1)) |> Enum.uniq()}

      index ->
        {:error,
         "#{inspect(Enum.at(list, index))} is not a version, as releases are numbered (0.13.0-beta)"}
    end
  end

  defp value("blocked", _other), do: {:error, "blocked is a list of versions"}
  defp value(_key, nil), do: {:ok, nil}
  defp value(_key, ""), do: {:ok, nil}

  defp value(key, text) do
    case version(text) do
      {:ok, version} ->
        {:ok, version}

      :error ->
        {:error,
         "#{key} #{inspect(text)} is not a version, as releases are numbered (0.13.0-beta)"}
    end
  end

  defp version(text) when is_binary(text) do
    version = text |> String.trim() |> String.trim_leading("v")
    if ClientUpdate.version?(version), do: {:ok, version}, else: :error
  end

  defp version(_other), do: :error

  # What the policy would be as a whole, held to the two rules that make it one: a floor no
  # higher than the version clients are sent to, and that version not one nobody is served.
  defp coherent(%{recommended: recommended, minimum: minimum, blocked: blocked}) do
    cond do
      ClientUpdate.older?(recommended, minimum) ->
        {:error,
         %{
           field: "minimum",
           reason: "the minimum #{minimum} is newer than the recommended version #{recommended}"
         }}

      is_binary(recommended) and recommended in (blocked || []) ->
        {:error,
         %{field: "recommended", reason: "the recommended version #{recommended} is blocked"}}

      true ->
        :ok
    end
  end

  defp describe(nil, component) do
    %{
      component: component,
      recommended: nil,
      minimum: nil,
      blocked: [],
      updated_by: nil,
      updated_at: nil
    }
  end

  defp describe(%__MODULE__{} = row, component) do
    %{
      component: component,
      recommended: row.recommended,
      minimum: row.minimum,
      blocked: row.blocked || [],
      updated_by: row.updated_by,
      updated_at: row.updated_at
    }
  end

  defp stored do
    Repo.all(__MODULE__)
  rescue
    error ->
      Logger.warning("troupe plane: could not read the client version policy: #{inspect(error)}")
      []
  catch
    :exit, reason ->
      Logger.warning("troupe plane: could not read the client version policy: #{inspect(reason)}")
      []
  end
end
