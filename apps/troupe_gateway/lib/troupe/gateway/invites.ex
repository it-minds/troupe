defmodule Troupe.Gateway.Invites do
  @moduledoc """
  Inviting a person into a private session from the machine that seals it, and reading one
  you were invited into (#765).

  ## The owner's side

  A private session is sealed here under a key in its owner's own subtree at the key
  manager, which the plane cannot read. Inviting somebody hands them that key the only way
  the plane cannot see it: this daemon, signed in at the key manager as its owner, puts each
  generation of the key the session has been sealed under into the invitee's own slot
  (`Troupe.KMS.invited_slot/4`), where its credential may create a key and may not read one
  back, and then tells the plane where (`session.invite` with `keys`). The plane says first
  whether the person may be invited at all and where their slot is (`session.invite_slot`),
  so nothing is put anywhere for somebody it refuses.

  Taking an invitation back (`uninvite/3`) is the plane's `session.uninvite`, which destroys
  that person's copies and marks the session `rekey_due`, and then a new key forward
  (`rekey/2`): what is pending is sealed under the key held now, a new generation of the key
  is made, everything after is sealed under it, and it is put in the slot of everybody
  still invited and the plane told (`session.rekeyed`). A rekey the plane asks for that this
  daemon did not start, because the invitation was taken back elsewhere, is done when the
  session is next carried on (`Private.resume/1`).

  Whom it hands a key to is what the session's own log says, not only what the plane says:
  each invitation made here is a `session_invited` event in the log, each taken back a
  `session_uninvited`, and a new key goes to the people the plane lists who are invited by
  the log as well. A plane that listed somebody nobody here invited is given no key for them.

  ## The invitee's side

  `read/2`: the plane says where this person's copies of the session's keys are
  (`session.keys`) and hands an assertion for their own name; this daemon spends it at the
  key manager, reads each key from their own slot, and reads the sealed log from object
  storage through URLs the plane signs for reading only. Nothing of it is written here.
  """

  alias Troupe.Gateway.{Plane, Private}
  alias Troupe.KMS
  alias Troupe.Session.Log
  alias Troupe.Sessions.{Sealer, Storage}

  require Logger

  @doc """
  Invite `person` (a subject or an email) into private session `session` at `role`
  (`observe` or `control`), from this, its owner's machine. Answers the plane's
  invitation row.
  """
  @spec invite(map(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def invite(%{id: session_id} = session, person, role, opts \\ []) do
    plane = Keyword.get(opts, :plane, Plane)

    with :ok <- owned(session, plane),
         :ok <- followed_only(role),
         {:ok, slot} <-
           Plane.call(
             "session.invite_slot",
             %{"session_id" => session_id, "subject" => person},
             plane
           ),
         {:ok, manager} <- Private.sign_in(plane, session_id, opts),
         {:ok, keys} <- put_keys(session_id, slot, 1..slot["key_version"], manager, opts),
         {:ok, invited} <-
           Plane.call(
             "session.invite",
             %{
               "session_id" => session_id,
               "subject" => slot["subject"],
               "role" => role,
               "keys" => keys
             },
             plane
           ) do
      recorder(opts).(session_id, :session_invited, %{
        "subject" => slot["subject"],
        "display_name" => slot["display_name"],
        "role" => role,
        "by" => Plane.subject(plane)
      })

      {:ok, invited}
    end
  end

  @doc """
  Take back `person`'s invitation into private session `session`, and seal what follows
  under a key they do not have. Answers the session's row once re-keyed, or the plane's
  answer and why it is not re-keyed yet.
  """
  @spec uninvite(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def uninvite(%{id: session_id} = session, person, opts \\ []) do
    plane = Keyword.get(opts, :plane, Plane)

    with :ok <- owned(session, plane),
         {:ok, answer} <-
           Plane.call(
             "session.uninvite",
             %{"session_id" => session_id, "subject" => person},
             plane
           ) do
      # The new key first, so that the line saying so is sealed under it with what follows.
      rekeyed = rekey(session_id, opts)

      recorder(opts).(session_id, :session_uninvited, %{
        "subject" => answer["subject"],
        "by" => Plane.subject(plane)
      })

      case rekeyed do
        {:ok, row} ->
          {:ok, Map.merge(answer, %{"rekey_due" => false, "key_version" => row["key_version"]})}

        {:error, reason} ->
          Logger.warning("troupe: #{session_id} is not re-keyed yet: #{inspect(reason)}")
          {:ok, Map.put(answer, "rekey_due", true)}
      end
    end
  end

  @doc """
  Seal a private session forward under its next key, where the plane says it is
  `rekey_due`, and put that key in the slot of everybody still invited. A retry finds the
  same key at the same generation, since making one is idempotent. Answers the row.
  """
  @spec rekey(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def rekey(session_id, opts \\ []) do
    plane = Keyword.get(opts, :plane, Plane)

    with {:ok, row} <- Plane.call("session.get", %{"session_id" => session_id}, plane),
         :ok <- due(row),
         version = (row["key_version"] || 1) + 1,
         {:ok, manager} <- Private.sign_in(plane, session_id, opts),
         {:ok, key} <-
           kms(opts).create(
             manager[:owner],
             KMS.generation(session_id, version),
             manager[:options]
           ),
         :ok <- swap(session_id, key, version),
         {:ok, %{"invites" => invites}} <-
           Plane.call("session.invites", %{"session_id" => session_id}, plane),
         {:ok, keys} <- hand_on(session_id, invites, version, key, manager, plane, opts) do
      Plane.call(
        "session.rekeyed",
        %{"session_id" => session_id, "key_version" => version, "keys" => keys},
        plane
      )
    end
  end

  defp due(%{"rekey_due" => true}), do: :ok
  defp due(_row), do: {:error, :not_due}

  # The sealer, where there is one, seals what it holds under the key it has and takes the
  # new one for what follows. With none, the next sealer is started at the row's version.
  defp swap(session_id, key, version) do
    case Registry.whereis_name({Private.Registry, session_id}) do
      :undefined ->
        :ok

      pid ->
        case Sealer.rekey(pid, key, version) do
          {:ok, _sealed} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  catch
    :exit, _gone -> :ok
  end

  # The new key, put in the slot of each person the plane and this session's own log both
  # say is invited.
  defp hand_on(session_id, invites, version, key, manager, plane, opts) do
    here = invited_here(session_id, opts)

    invites
    |> Enum.filter(&MapSet.member?(here, &1["subject"]))
    |> Enum.reduce_while({:ok, []}, fn invite, {:ok, acc} ->
      with {:ok, slot} <-
             Plane.call(
               "session.invite_slot",
               %{"session_id" => session_id, "subject" => invite["subject"]},
               plane
             ),
           {:ok, path} <- put_key(slot["prefix"], version, key, manager, opts) do
        {:cont, {:ok, [%{"subject" => invite["subject"], "slot" => path} | acc]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Who this session's own log says is invited into it: each `session_invited` not followed
  by a `session_uninvited` for the same person.
  """
  @spec invited_here(String.t(), keyword()) :: MapSet.t(String.t())
  def invited_here(session_id, opts \\ []) do
    read = Keyword.get(opts, :replay, &Troupe.replay_from/2)

    session_id
    |> read.(0)
    |> Enum.reduce(MapSet.new(), fn event, acc ->
      case {to_string(event.type), event.data} do
        {"session_invited", %{"subject" => subject}} -> MapSet.put(acc, subject)
        {"session_uninvited", %{"subject" => subject}} -> MapSet.delete(acc, subject)
        _other -> acc
      end
    end)
  end

  # Each generation of the session's key, read with the owner's own sign-in and put in the
  # invitee's slot, which that sign-in may create in and may not read.
  defp put_keys(session_id, slot, versions, manager, opts) do
    Enum.reduce_while(versions, {:ok, []}, fn version, {:ok, acc} ->
      with {:ok, key} <-
             kms(opts).fetch(
               manager[:owner],
               KMS.generation(session_id, version),
               manager[:options]
             ),
           {:ok, path} <- put_key(slot["prefix"], version, key, manager, opts) do
        {:cont, {:ok, acc ++ [%{"key_version" => version, "slot" => path}]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp put_key(prefix, version, key, manager, opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    path = prefix <> "k#{version}-#{nonce}"

    case kms(opts).put_at(path, key, manager[:options]) do
      :ok -> {:ok, path}
      error -> error
    end
  end

  # -- reading one you were invited into --------------------------------------------

  @doc """
  The sealed log of a private session `person` was invited into, as far as it is sealed,
  after `after_seq` (`:after_seq`, 0 for all of it). Answers the events, oldest first, the
  session's `last_seq` at the plane, and the owner's name.
  """
  @spec read(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(session_id, opts \\ []) do
    plane = Keyword.get(opts, :plane, Plane)
    after_seq = Keyword.get(opts, :after_seq, 0)

    with {:ok, grant} <- Plane.call("session.keys", %{"session_id" => session_id}, plane),
         {:ok, options} <- Keyword.get(opts, :spend, &Private.spend/1).(grant),
         {:ok, keys} <- read_keys(grant["keys"] || [], options, opts),
         store = Keyword.get_lazy(opts, :store, fn -> Private.store(session_id, plane) end),
         {:ok, events} <- read_segments(store, session_id, keys, after_seq) do
      {:ok,
       %{
         "session_id" => session_id,
         "events" => events,
         "last_seq" => grant["last_seq"],
         "key_version" => grant["key_version"]
       }}
    end
  end

  defp read_keys(slots, options, opts) do
    Enum.reduce_while(slots, {:ok, []}, fn %{"slot" => slot}, {:ok, acc} ->
      case kms(opts).fetch_at(slot, options) do
        {:ok, key} -> {:cont, {:ok, [key | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp read_segments(_store, _session_id, [], _after_seq), do: {:error, :no_keys}

  defp read_segments(store, session_id, keys, after_seq) do
    with {:ok, segments} <- Storage.list_segments(store, session_id) do
      segments
      |> Storage.live_segments()
      |> Enum.filter(&(&1.last_seq > after_seq))
      |> Enum.reduce_while({:ok, []}, &read_into(store, session_id, keys, after_seq, &1, &2))
    end
  end

  defp read_into(store, session_id, keys, after_seq, segment, {:ok, acc}) do
    case Storage.read_segment(store, session_id, keys, segment.key) do
      {:ok, events} -> {:cont, {:ok, acc ++ Enum.filter(events, &(seq(&1) > after_seq))}}
      error -> {:halt, error}
    end
  end

  defp seq(%{"seq" => seq}) when is_integer(seq), do: seq
  defp seq(_event), do: 0

  # -- the session's own log ------------------------------------------------------

  # The line in the session's log, where the session is running here to write it: who was
  # let in to read what it says is part of what happened.
  defp record(session_id, type, data) do
    data = Map.reject(data, fn {_key, value} -> is_nil(value) end)

    case Registry.lookup(Troupe.Registry, {:log, session_id}) do
      [{_pid, _value}] -> Log.append(session_id, ["root"], type, data)
      [] -> :not_running
    end
  catch
    :exit, reason ->
      Logger.info("troupe: #{session_id} did not record #{type}: #{inspect(reason)}")
  end

  # Followed, not steered: steering a private session from another device is offering it,
  # which a private session never is. Asked before any key goes anywhere.
  defp followed_only("control"), do: {:error, :followed_only}
  defp followed_only(_observe), do: :ok

  defp owned(session, plane) do
    owner = Map.get(session, :owner)
    subject = Plane.subject(plane)

    cond do
      Map.get(session, :kind) != "private" -> {:error, :not_private}
      subject == nil -> {:error, :unlinked}
      owner in [nil, subject] -> :ok
      true -> {:error, :not_owner}
    end
  end

  defp kms(opts), do: Keyword.get(opts, :kms, KMS.adapter())

  # Where the line goes: the session's own log, unless a test keeps one of its own.
  defp recorder(opts), do: Keyword.get(opts, :record, &record/3)
end
