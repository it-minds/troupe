defmodule Troupe.Plane.Names do
  @moduledoc """
  People by name, wherever the plane answers with a subject.

  A subject is what the plane keys a person on, and is often an opaque id or an email; the
  name is what a client shows. Every row the plane lists that names a person carries the
  name beside the subject, filled from the identity record SCIM and sign-in write, in one
  query per answer: `owner_name` beside a session's `owner`, `actor_name` beside an audit
  row's `actor`. A subject with no record, or a record whose name is empty or only the
  subject again, keeps its subject and gets no name, so a client falls back to what it
  showed before there was one.

  The events a session writes carry the name in their `actor`, from the token the plane
  signs for the connection (`name` beside `sub`), which this module does not touch: the
  plane never sees an event.
  """

  import Ecto.Query

  alias Troupe.Plane.Identity.User
  alias Troupe.Plane.Repo

  @doc """
  The names of these subjects the plane has a record for, as `%{subject => name}`.

  A subject with no record, or none worth showing, is absent from the answer.
  """
  @spec of([String.t() | nil]) :: %{String.t() => String.t()}
  def of(subjects) do
    case subjects |> Enum.filter(&is_binary/1) |> Enum.uniq() do
      [] ->
        %{}

      wanted ->
        from(u in User, where: u.subject in ^wanted, select: {u.subject, u.display_name})
        |> Repo.all()
        |> Enum.filter(fn {subject, name} -> shown?(name, subject) end)
        |> Map.new()
    end
  end

  @doc """
  Put the name beside each subject a row names.

  `fields` pairs the key a row names a subject under with the key its name goes under,
  `[{"owner", "owner_name"}]`; the keys are strings or atoms, as the rows are. One query
  for every row and field together. A row whose subject has no name is left as it was,
  and a single row is decorated as a list of one would be.
  """
  @spec decorate(map() | [map()], [{term(), term()}]) :: map() | [map()]
  def decorate(rows, fields) when is_list(rows) do
    names =
      rows
      |> Enum.flat_map(fn row -> Enum.map(fields, fn {from, _to} -> Map.get(row, from) end) end)
      |> of()

    Enum.map(rows, &put_names(&1, fields, names))
  end

  def decorate(%{} = row, fields), do: [row] |> decorate(fields) |> hd()

  defp put_names(row, fields, names) do
    Enum.reduce(fields, row, fn {from, to}, row ->
      case Map.fetch(names, Map.get(row, from)) do
        {:ok, name} -> Map.put(row, to, name)
        :error -> row
      end
    end)
  end

  # A name that is the subject again, as a principal's or a break-glass sign-in's record
  # carries, says nothing the subject did not.
  defp shown?(name, subject), do: is_binary(name) and String.trim(name) != "" and name != subject
end
