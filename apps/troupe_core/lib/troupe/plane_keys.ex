defmodule Troupe.PlaneKeys do
  @moduledoc """
  The signing key each plane this machine signs in to says what it tells clients with
  (#657), pinned the first time it is seen, as SSH pins a host key.

  A plane signs its version policy (`me.client_versions`) and its organisation's document
  (`me.client_defaults`) with a key of its own, which `Troupe.Protocol.PlaneSignature`
  describes. This keeps, per plane, the key this machine holds it to, in
  `<state>/plane-keys.json`: one file for the terminal, the daemon and, through the daemon,
  the desktop app, so a key accepted in one is accepted in all of them.

    * **At sign-in** (`troupe login`, and the daemon whenever a client hands it a plane
      token) the key the plane serves at `/.well-known/troupe-signing-key` is seen: pinned
      where none is, and where another is pinned, kept beside it as *offered* and not
      trusted.
    * **Every signed answer** is checked against the pinned key (`check/4`): one signed by
      another key, changed after it was signed, expired, or not signed at all once a key is
      pinned, is refused in a sentence.
    * **A changed key** is taken only when a person accepts it (`accept/2`), naming the
      fingerprint they were shown: `troupe plane-key accept`, or the desktop app.
    * **A plane that signs nothing**, one from before this, serves no key; nothing is pinned
      for it and its answers are taken as they always were, said in a line.

  This is the organisation's word honoured by Troupe on a machine its person administers,
  not a lock against that person: the file is in their own state directory, as the copy of
  the organisation's document is.
  What it stops is an answer from anywhere but the plane signed in to: a mirror, a copy
  carried to another machine, an edited cache.
  """

  alias Troupe.Config.Org
  alias Troupe.Protocol.{ClientUpdate, PlaneSignature}

  @version 1
  @well_known "/.well-known/troupe-signing-key"

  @type served :: %{String.t() => String.t()}
  @type seen ::
          {:pinned, String.t()}
          | {:same, String.t()}
          | {:changed, String.t(), String.t()}

  @doc "Where the keys are kept: `<state>/plane-keys.json`."
  @spec path() :: Path.t()
  def path, do: Org.keys_path()

  @doc "The same plane however its URL was spelled: the clients agree on all but a trailing slash."
  @spec plane(String.t()) :: String.t()
  def plane(url), do: String.trim_trailing(url, "/")

  @doc """
  What is kept for a plane: `fingerprint`, `public_key`, `pinned_at`, and `offered` where
  it has served another key since. `nil` for a plane nothing is pinned for.
  """
  @spec pinned(String.t(), Path.t()) :: map() | nil
  def pinned(url, path \\ path()), do: read(path)[plane(url)]

  @doc "Every plane's, by URL."
  @spec all(Path.t()) :: %{String.t() => map()}
  def all(path \\ path()), do: read(path)

  @doc """
  The key a plane serves, as `/.well-known/troupe-signing-key` answers it: `{:ok, key}`,
  `:unsigned` for a plane that has no such path (one from before #657), or an error.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, served()} | :unsigned | {:error, String.t()}
  def fetch(url, opts \\ []) do
    get = Keyword.get(opts, :get, &get/1)

    case get.(plane(url) <> @well_known) do
      {:ok, %{} = served} ->
        case PlaneSignature.read_key(served) do
          {:ok, _key} ->
            {:ok,
             Map.take(served, ["algorithm", "public_key", "fingerprint", "version", "created_at"])}

          {:error, :malformed} ->
            {:error, "#{plane(url)} serves a signing key this client cannot read"}
        end

      :not_found ->
        :unsigned

      {:error, why} ->
        {:error, why}
    end
  end

  defp get(url) do
    case Req.get(url, retry: false, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %{status: 404}} -> :not_found
      {:ok, %{status: status}} -> {:error, "#{url} answered #{status}"}
      {:error, exception} -> {:error, "could not reach #{url}: #{Exception.message(exception)}"}
    end
  end

  @doc """
  A key a plane serves, seen: pinned where none is (`{:pinned, fingerprint}`), the same as
  the one pinned (`{:same, fingerprint}`), or another, kept as offered and not trusted
  (`{:changed, pinned, offered}`).
  """
  @spec see(String.t(), served(), Path.t()) :: {:ok, seen()} | {:error, String.t()}
  def see(url, served, path \\ path()) do
    {:ok, key} = PlaneSignature.read_key(served)
    keys = read(path)
    now = now()

    case keys[plane(url)] do
      nil ->
        with :ok <- write(path, Map.put(keys, plane(url), entry(served, key, "pinned_at", now))),
             do: {:ok, {:pinned, key.fingerprint}}

      %{"fingerprint" => fingerprint} = held when fingerprint == key.fingerprint ->
        if Map.has_key?(held, "offered"),
          do: write(path, Map.put(keys, plane(url), Map.delete(held, "offered"))),
          else: :ok

        {:ok, {:same, fingerprint}}

      %{"fingerprint" => fingerprint} = held ->
        offered =
          case held["offered"] do
            %{"fingerprint" => same} = before when same == key.fingerprint -> before
            _other -> entry(served, key, "seen_at", now)
          end

        with :ok <- write(path, Map.put(keys, plane(url), Map.put(held, "offered", offered))),
             do: {:ok, {:changed, fingerprint, key.fingerprint}}
    end
  end

  @doc """
  A person accepting the key a plane offered in place of the one pinned, by its
  fingerprint, which must be the offered key's: the offered key is pinned. `served` is the
  key the plane serves now, where the caller has just asked, and is offered first.
  Accepting the key already pinned changes nothing.
  """
  @spec accept(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def accept(url, fingerprint, opts \\ []) do
    path = Keyword.get(opts, :path, path())

    with {:ok, _seen} <- maybe_see(url, opts[:served], path) do
      keys = read(path)
      accepted(keys[plane(url)], fingerprint, url, keys, path)
    end
  end

  defp accepted(%{"fingerprint" => fingerprint}, fingerprint, _url, _keys, _path),
    do: {:ok, fingerprint}

  defp accepted(
         %{"offered" => %{"fingerprint" => fingerprint} = offered},
         fingerprint,
         url,
         keys,
         path
       ) do
    pinned = offered |> Map.delete("seen_at") |> Map.put("pinned_at", now())
    with :ok <- write(path, Map.put(keys, plane(url), pinned)), do: {:ok, fingerprint}
  end

  defp accepted(%{"offered" => %{"fingerprint" => offered}}, fingerprint, url, _keys, _path),
    do:
      {:error, "#{plane(url)} offers the key #{offered}, not #{fingerprint}: nothing is accepted"}

  defp accepted(%{"fingerprint" => pinned}, _fingerprint, url, _keys, _path),
    do:
      {:error,
       "#{plane(url)} offers no key but #{pinned}, the one already pinned: nothing is accepted"}

  defp accepted(nil, _fingerprint, url, _keys, _path),
    do: {:error, "no key is pinned for #{plane(url)} yet: it is pinned when you sign in"}

  defp maybe_see(_url, nil, _path), do: {:ok, nil}
  defp maybe_see(url, served, path), do: see(url, served, path)

  @doc """
  An answer of the plane at `url`, checked as `kind` against the key pinned for it.

    * `{:ok, body, :signed}`: the body the plane signed, the signature holding;
    * `{:ok, answer, :unsigned}`: a plane with no key pinned whose answer is not signed,
      taken as it is, without its `signed`;
    * `{:error, sentence}`: refused, and why, with what to do where there is something.

  A signed answer from a plane nothing is pinned for yet, as after an update from before
  this, pins the key the plane serves first (`:fetch` stands in for asking it), as a
  sign-in would have.
  """
  @spec check(String.t(), map(), String.t(), keyword()) ::
          {:ok, map(), :signed | :unsigned} | {:error, String.t()}
  def check(url, answer, kind, opts \\ []) when is_map(answer) do
    path = Keyword.get(opts, :path, path())
    signed = answer["signed"]

    with {:ok, held} <- held(url, signed, path, opts) do
      checked(held, answer, url, kind, opts)
    end
  end

  defp checked(nil, answer, _url, _kind, _opts),
    do: {:ok, Map.delete(answer, "signed"), :unsigned}

  defp checked(%{"fingerprint" => pinned} = held, answer, url, kind, opts) do
    {:ok, key} = PlaneSignature.read_key(held)

    case PlaneSignature.verify(answer["signed"], key, kind, Keyword.take(opts, [:now])) do
      {:ok, %{body: body}} -> {:ok, body, :signed}
      {:error, reason} -> {:error, refusal(reason, url, kind, pinned)}
    end
  end

  defp held(url, signed, path, opts) do
    case pinned(url, path) do
      nil when is_map(signed) -> pin_served(url, fetch(url, opts), path)
      held -> {:ok, held}
    end
  end

  defp pin_served(url, {:ok, served}, path) do
    with {:ok, _seen} <- see(url, served, path), do: {:ok, pinned(url, path)}
  end

  defp pin_served(url, :unsigned, _path),
    do:
      {:error,
       "#{plane(url)} signed its answer and serves no key to check it with: it is not taken"}

  defp pin_served(url, {:error, why}, _path),
    do:
      {:error,
       "#{plane(url)} signed its answer, and its key could not be fetched to check it: #{why}"}

  @doc """
  A plane's `update_required`, the `data` its `initialize` refused this client's version
  with, checked against the key pinned for the plane (#657):

    * `{:refused, sentence}`: the plane's word, signed by the pinned key as
      `update_required` for this `component` and `version` and not past its hour; or, from
      a plane nothing is pinned for, taken as it always was;
    * `{:not_taken, line}`: not the plane's signed word, and why. The client then goes on
      as with a plane that could not be asked: it is told to update by nothing it cannot
      check.
  """
  @spec held_refusal(String.t(), map(), String.t(), String.t(), keyword()) ::
          {:refused, String.t()} | {:not_taken, String.t()}
  def held_refusal(url, data, component, version, opts \\ []) when is_map(data) do
    case check(url, data, "update_required", opts) do
      {:ok, %{"component" => ^component, "version" => ^version} = body, :signed} ->
        {:refused, ClientUpdate.sentence(body)}

      {:ok, _other, :signed} ->
        {:not_taken,
         "#{plane(url)} signed a refusal of another client or version than this one: it is not taken"}

      {:ok, answer, :unsigned} ->
        {:refused, ClientUpdate.sentence(answer)}

      {:error, sentence} ->
        {:not_taken, sentence}
    end
  end

  @doc "What a refusal of `kind` from `url` says, the key pinned being `pinned`."
  @spec refusal(PlaneSignature.reason(), String.t(), String.t(), String.t()) :: String.t()
  def refusal(reason, url, kind, pinned) do
    sentence = PlaneSignature.refusal(reason, plane(url), what: what(kind), pinned: pinned)

    case reason do
      {:other_key, offered} ->
        sentence <>
          ": check its fingerprint with the plane's administrators, then run troupe plane-key accept " <>
          offered <> " (or accept it in the desktop app)"

      _other ->
        sentence
    end
  end

  @doc "A line for an answer taken unsigned from a plane that signs nothing."
  @spec unsigned_line(String.t(), String.t()) :: String.t()
  def unsigned_line(url, kind),
    do:
      "#{plane(url)} signs nothing it tells clients (a plane from before 0.22): #{what(kind)} is taken as it is"

  defp what("client_versions"), do: "the version policy"
  defp what("client_defaults"), do: "the organisation's document"
  defp what("memory"), do: "the organisation's memory"
  defp what("update_required"), do: "the plane's refusal of this version"
  defp what(_kind), do: "the plane's answer"

  # -- the file ---------------------------------------------------------------------

  defp entry(served, key, stamp, now) do
    %{
      "algorithm" => "ed25519",
      "public_key" => served["public_key"],
      "fingerprint" => key.fingerprint,
      stamp => now
    }
  end

  defp read(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{"version" => @version, "planes" => %{} = planes}} <- Jason.decode(text) do
      planes
    else
      _none -> %{}
    end
  end

  # Whole or not at all: beside it, then renamed over it.
  defp write(path, planes) do
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"
    text = Jason.encode!(%{"version" => @version, "planes" => planes}, pretty: true) <> "\n"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, text),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)

        {:error,
         "#{Troupe.Paths.display(path)} could not be written: #{:file.format_error(reason)}"}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
