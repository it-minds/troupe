defmodule Troupe.Gateway.Private do
  @moduledoc """
  Sealing a person's own session from their own machine.

  A private session runs here and nowhere else. Nothing about it reaches a worker, and
  the only thing the plane learns is that it exists and how far it has got. What makes
  that possible is that the daemon can do the two things a pod does — hold a session key
  and write to object storage — without holding either credential.

  * **The key** comes from the key manager, through a token the daemon exchanges for an
    assertion the plane signs. `session.assertion` names the path under
    `troupe/people/<name>/sessions/<id>`, the person policy covers their own subtree
    and nobody else's, and no pod role covers any of it. The name is the person's at the
    key manager, which the answer carries: the subject this daemon was linked under is
    not it once they have been moved to another claim, and a device that took the
    subject for it would make a second key rather than find the first (Decision 755). A
    plane from before that names none, and there the subject is the name.
  * **The bytes** go through `Troupe.ObjectStore.Signed`: one presigned URL per key, and
    a listing the plane does because a listing cannot be signed per-key.

  Everything after that is `Troupe.Sessions.Sealer`, unchanged and unaware. That is what
  the move into `troupe_protocol` was for: a session sealed by a laptop and a session
  sealed by a pod are the same bytes in the same layout, so either can restore the other.

  ## What it does when it cannot

  Nothing, loudly enough to be found in a log and quietly enough to be ignored. A laptop
  is offline most of the time it is on, and the durable log is already on disk before any
  of this is asked for — so a session that cannot be registered is a session that seals
  later, not one that loses anything. `start/2` answers an error, the session runs
  exactly as a local one, and the next attempt is somebody signing in.

  The one error that is not transient is `stale_version`: another device has taken the
  session, and this one must stop. It does, and says so.

  ## When the session is erased

  The plane destroys the key and keeps the tombstone; it cannot reach this disk, and it
  does not delete the objects while this device may still be writing them. So when the
  daemon connects it asks what was erased while it was away, drops its sealer and its copy
  of each, and says so, and that is when the plane deletes the objects
  (`apply_erasures/1`, Decision 756). Erasing one here goes the same way, with the plane
  asked first (`erase/2`, Decision 789): nothing is erased where it cannot be.

  ## When the daemon restarted

  The token is in memory, so a daemon that restarted seals nothing until a client links
  it again, and a session it made while nobody had linked was never registered. The link
  that hands it a token is when it carries on (`resume/1`, Decision 764): each private
  session it has with no sealer is sealed from where the plane says it got to, with what
  the log holds after that, and one the plane has never heard of from its first event.

  ## When the person signs out

  The client that handed the token over takes it back (`identity.sign_out`), and every
  sealer stops (`suspend/1`), leaving the daemon as a restart would: nothing is sealed
  until a link with a token carries each session on (issue #381).

  ## What a listing says, and claiming

  `session.list` says how each private session's sealing stands here (`sync/1`), from
  its sealer and from what the plane last said of it when the daemon asked, which it does
  at a link and at every seal: another device sealed it last, or it is waiting to be
  erased. A session another device holds is sealed here once the person claims it
  (`take_over/2`, `session.claim`; Decision 785).
  """

  alias Troupe.Gateway.Plane
  alias Troupe.KMS
  alias Troupe.ObjectStore.Signed
  alias Troupe.Protocol.Event
  alias Troupe.Sessions.{Context, Sealer}

  require Logger

  # What the plane last said of a session that is not being sealed here, by id:
  # `:erasure_pending`, or `{:elsewhere, device}`. Owned by `Private.Sealers`.
  @heard __MODULE__.Heard

  # How long a listing waits for a sealer to say how far it has got. A sealer answers
  # between seals; one that does not answer in this long is uploading what it holds.
  @status_timeout 250

  @doc """
  Make a local session private: register it, take its key, and start sealing.

  Returns the sealer, which is supervised here rather than by the caller: a session's
  unsealed tail must survive the connection that created it, and a sealer that died with
  a client would lose exactly the events nobody had written down yet.
  """
  @spec start(String.t(), keyword()) :: {:ok, pid(), Context.t()} | {:error, term()}
  def start(session_id, opts \\ []) do
    plane = Keyword.get(opts, :plane, Plane)

    with {:ok, subject} <- subject(plane),
         {:ok, row} <- register(plane, session_id, opts),
         {:ok, context} <- context(plane, subject, session_id, row, opts, key_manager(opts)),
         {:ok, sealer} <- sealer(plane, context, opts) do
      {:ok, sealer, context}
    end
  end

  @doc """
  Seal what is pending and stop.

  Called where a session stops. The sealer would seal on the way down anyway — it traps
  exits for exactly this — but a session going dormant should be *written* before the
  daemon says it is dormant, not shortly afterwards.
  """
  @spec stop(String.t()) :: :ok
  def stop(session_id) do
    case Registry.whereis_name({__MODULE__.Registry, session_id}) do
      :undefined ->
        :ok

      pid ->
        _ = seal_now(pid)
        DynamicSupervisor.terminate_child(__MODULE__.Sealers, pid)
        :ok
    end
  end

  # A sealer may have stopped on its own since it was looked up: another device holds the
  # session, and it had nothing more to write.
  defp seal_now(pid) do
    Sealer.seal_now(pid)
  catch
    :exit, _gone -> {:error, :gone}
  end

  @doc "Whether this session is being sealed here. A local session is not."
  @spec sealing?(String.t()) :: boolean()
  def sealing?(session_id) do
    Registry.whereis_name({__MODULE__.Registry, session_id}) != :undefined
  end

  @doc """
  Take a session over on this device, bumping the epoch past whatever held it.

  The device that loses is not told; it finds out when it next seals, which is the only
  moment the answer changes anything for it.
  """
  @spec claim(String.t(), pos_integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def claim(session_id, epoch, opts \\ []) do
    plane = Keyword.get(opts, :plane, Plane)

    Plane.call(
      "session.register",
      %{
        "session_id" => session_id,
        "claim" => true,
        "epoch" => epoch,
        "device" => device(opts)
      },
      plane
    )
  end

  @doc """
  How a private session's sealing stands here, as `session.list` says it, with the device
  that holds it where that is another one.

  * `"erasure_pending"`: somebody erased it and the plane has not yet destroyed its key.
  * `"elsewhere"`: another device sealed it last, and it is that device's until it is
    claimed here (`take_over/2`).
  * `"current"`: sealing here, with nothing waiting to be sealed.
  * `"behind"`: sealing here, with events not sealed yet.
  * `"paused"`: not sealing: no client has handed the daemon a token since it started or
    since the person signed out, the plane was not there, or the session was archived. A
    link with a token carries it on.

  The first two are what the plane said when the daemon last asked, at a link or a seal,
  and not asked again for a listing.
  """
  @spec sync(String.t()) :: {String.t(), String.t() | nil}
  def sync(session_id) do
    case heard(session_id) do
      :erasure_pending -> {"erasure_pending", nil}
      {:elsewhere, device} -> {"elsewhere", device}
      nil -> {sealing(session_id), nil}
    end
  end

  defp sealing(session_id) do
    case Registry.whereis_name({__MODULE__.Registry, session_id}) do
      :undefined -> "paused"
      pid -> pid |> pending() |> sealing_word()
    end
  end

  defp sealing_word(0), do: "current"
  defp sealing_word(:gone), do: "paused"
  defp sealing_word(_waiting), do: "behind"

  defp pending(pid) do
    Sealer.status(pid, @status_timeout).pending
  catch
    :exit, {:timeout, _call} -> :sealing
    :exit, _gone -> :gone
  end

  @doc """
  Take a private session over on this device, and seal it from here: what `session.claim`
  does, for one another device sealed last, which `resume/1` leaves to it, and for one this
  machine sealed under a name it no longer has.

  Only where this copy holds what the plane has: the event at the row's `last_seq` is
  here, with the row's `head_hash`, so what is sealed from here follows on from it. One
  whose plane copy went further, or elsewhere, is refused with `:diverged`: sealing this
  copy after it would make the session two histories. The claim names the epoch the row
  had, so two devices claiming at once make one winner, and the other learns it lost at
  its next seal. A row that names this device already is carried on, not claimed again.

  Answers the row as it now stands.
  """
  @spec take_over(%{id: String.t(), workspace: String.t() | nil}, keyword()) ::
          {:ok, map()} | {:error, term()}
  def take_over(%{id: session_id} = session, opts \\ []) do
    plane = Keyword.get(opts, :plane, Plane)
    device = device(opts)

    with {:ok, row} <- plane_row(plane, session_id) do
      cond do
        row["device"] == device and sealing?(session_id) -> {:ok, row}
        row["device"] == device -> seal_from(session, row, plane, opts)
        true -> claim_from(session, row, plane, opts)
      end
    end
  end

  defp claim_from(session, row, plane, opts) do
    with :ok <- holds(session.id, row, opts),
         {:ok, taken} <- claim(session.id, row["epoch"], Keyword.put(opts, :plane, plane)) do
      # A sealer still here is one that lost: its epoch is behind the row's.
      stop_sealer(session.id)
      seal_from(session, taken, plane, opts)
    end
  end

  defp plane_row(plane, session_id) do
    case Plane.call("session.get", %{"session_id" => session_id}, plane) do
      {:ok, %{"state" => state}} when state in ["erasure_pending", "erased"] ->
        hear(session_id, :erasure_pending)
        {:error, :erased}

      {:ok, row} ->
        {:ok, row}

      {:error, {:rpc, %{"message" => "not_found"} = error}} ->
        if erased?(error), do: {:error, :erased}, else: {:error, :not_registered}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The event the row's `last_seq` names, as this disk holds it, hashed as a seal hashes
  # the last event it sealed. A row nothing was sealed into asks for nothing.
  defp holds(session_id, row, opts) do
    last_seq = row["last_seq"] || 0
    read = Keyword.get(opts, :backfill, &Troupe.replay_from/2)

    with true <- last_seq > 0,
         %Event{} = event <- Enum.find(read.(session_id, last_seq - 1), &(&1.seq == last_seq)) do
      if row["head_hash"] in [nil, Event.hash(event)], do: :ok, else: {:error, :diverged}
    else
      false -> :ok
      nil -> {:error, :diverged}
    end
  end

  defp seal_from(session, row, plane, opts) do
    forget(session.id)

    started?(
      session,
      plane,
      Keyword.merge(opts,
        epoch: row["epoch"],
        sealed_through: row["last_seq"] || 0,
        object_bytes: row["object_bytes"] || 0
      )
    )

    {:ok, row}
  end

  defp stop_sealer(session_id) do
    case Registry.whereis_name({__MODULE__.Registry, session_id}) do
      :undefined -> :ok
      pid -> DynamicSupervisor.terminate_child(__MODULE__.Sealers, pid)
    end
  end

  # What the plane said of a session, for `sync/1`. A daemon with no sealers running has
  # no table, and nothing to say.
  defp hear(session_id, what) do
    if :ets.whereis(@heard) != :undefined, do: :ets.insert(@heard, {session_id, what})
    :ok
  end

  defp forget(session_id) do
    if :ets.whereis(@heard) != :undefined, do: :ets.delete(@heard, session_id)
    :ok
  end

  defp heard(session_id) do
    case :ets.whereis(@heard) != :undefined and :ets.lookup(@heard, session_id) do
      [{^session_id, what}] -> what
      _none -> nil
    end
  end

  @doc """
  Carry out what the plane has erased of this person's private sessions since this device
  last asked.

  Called when the daemon connects to its plane, which for a daemon is a client linking
  it: the first moment it can ask anything. For each session the plane names, the sealer
  stops, the copy on this disk is erased, and the plane is told, which is when it deletes
  the session's objects: this device was writing them, and has stopped. One the plane could
  not be told about it names again at the next connection.

  Answers the sessions the plane was told about.
  """
  @spec apply_erasures(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def apply_erasures(opts \\ []) do
    plane = Keyword.get(opts, :plane, Plane)
    device = device(opts)

    with {:ok, %{"erasures" => erasures}} <-
           Plane.call("session.erasures", %{"device" => device}, plane) do
      {:ok, Enum.flat_map(erasures, &carry_out(&1["session_id"], plane, device, opts))}
    end
  end

  @doc """
  Erase a private session from here, as `session.erase` does (Decision 789): at the plane
  first, the way an erasure started there goes.

  The plane destroys the key, and until it has the session is `erasure_pending`. Once it
  has, this is `apply_erasures/1` for one session: the sealer stops, the copy on this disk
  is erased, and the plane is told, which is when it deletes the objects; one the plane
  could not be told about it names again at the next link. Until it has, the sealer and
  the session stop and the copy stays, listed as waiting to be erased, until the next link
  or the next erase finds the key gone. One the plane has no row for was never sealed, and
  the copy here is all there is.

  Nothing changes where the plane cannot be asked: no token, or no answer. The sealed copy
  and its key are there, and erasing only this one would leave nothing here to finish them.

  Answers `"erased"` or `"erasure_pending"`.
  """
  @spec erase(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def erase(session_id, opts \\ []) do
    plane = Keyword.get(opts, :plane, Plane)

    case Plane.call("session.erase", %{"session_id" => session_id}, plane) do
      {:ok, %{"erased" => true}} ->
        carry_out(session_id, plane, device(opts), opts)
        {:ok, "erased"}

      {:ok, %{"state" => "erasure_pending"}} ->
        stop_sealer(session_id)
        Troupe.stop_session(session_id)
        hear(session_id, :erasure_pending)
        {:ok, "erasure_pending"}

      {:ok, answer} ->
        {:error, {:unexpected_answer, answer}}

      {:error, {:rpc, %{"message" => "not_found"} = error}} ->
        if erased?(error),
          do: carry_out(session_id, plane, device(opts), opts),
          else: drop(session_id, opts)

        {:ok, "erased"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Seal again what this device was sealing before the daemon stopped, and for the first
  time what it made while it could not.

  Called when a client links the daemon with a plane token, after `apply_erasures/1`: the
  token is held in memory, so after a restart this is the first moment the daemon can
  seal anything. For each of its private sessions with no sealer it asks the plane for the
  row. One the plane has never heard of is registered and sealed from its first event. One
  this device sealed last carries on from the row's `last_seq`, at the epoch it held, and
  that registration is fenced, so a claim made meanwhile refuses it. One another device
  sealed last is that device's until somebody claims it back, which is not done here. One
  being erased is `apply_erasures/1`'s.

  Answers the sessions now sealing here.
  """
  @spec resume(keyword()) :: {:ok, [String.t()]}
  def resume(opts \\ []) do
    plane = Keyword.get(opts, :plane, Plane)
    device = device(opts)

    resumed =
      opts
      |> Keyword.get_lazy(:sessions, &private_sessions/0)
      |> Enum.reject(&sealing?(&1.id))
      |> Enum.filter(&carry_on(&1, plane, device, opts))
      |> Enum.map(& &1.id)

    {:ok, resumed}
  end

  @doc """
  Stop sealing anything, until a link with a token carries on (`resume/1`).

  Called when the person signs out at the client that handed the daemon its token
  (`identity.sign_out`), after the token is forgotten. Each sealer goes, and with it the
  key it held; its last seal on the way down finds no token and keeps nothing, because the
  log on this disk already has every event, and the next link carries the session on from
  the row's `last_seq`. Answers the sessions that stopped.
  """
  @spec suspend(keyword()) :: [String.t()]
  def suspend(opts \\ []) do
    supervisor = Keyword.get(opts, :supervisor, __MODULE__.Sealers)

    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(supervisor),
        is_pid(pid),
        session_id <- Registry.keys(__MODULE__.Registry, pid),
        :ok == DynamicSupervisor.terminate_child(supervisor, pid),
        do: session_id
  end

  defp private_sessions do
    for %{kind: "private"} = session <- Troupe.list_live_sessions(), do: session
  end

  defp carry_on(session, plane, device, opts) do
    case Plane.call("session.get", %{"session_id" => session.id}, plane) do
      {:ok, %{"state" => state}} when state in ["erasure_pending", "erased"] ->
        hear(session.id, :erasure_pending)
        false

      {:ok, %{"device" => ^device} = row} ->
        started?(
          session,
          plane,
          Keyword.merge(opts,
            epoch: row["epoch"],
            sealed_through: row["last_seq"] || 0,
            object_bytes: row["object_bytes"] || 0
          )
        )

      {:ok, row} ->
        hear(session.id, {:elsewhere, row["device"]})

        Logger.info(
          "troupe: #{session.id} was sealed last by #{inspect(row["device"])}; it is sealed here once it is claimed here"
        )

        false

      {:error, {:rpc, %{"message" => "not_found"} = error}} ->
        not erased?(error) and started?(session, plane, opts)

      {:error, reason} ->
        Logger.info("troupe: #{session.id} is local for now: #{inspect(reason)}")
        false
    end
  end

  defp erased?(%{"data" => %{"reason" => "erased"}}), do: true
  defp erased?(_error), do: false

  defp started?(session, plane, opts) do
    case start(session.id, Keyword.merge(opts, plane: plane, workspace: session.workspace)) do
      {:ok, _sealer, _context} ->
        forget(session.id)
        true

      {:error, reason} ->
        Logger.info("troupe: #{session.id} is local for now: #{inspect(reason)}")
        false
    end
  end

  # The sealer first, so stopping the session sends it nothing more to seal. Its own last
  # seal on the way down is refused by the plane, and anything that got through before is
  # under the prefix the plane then deletes.
  defp carry_out(session_id, plane, device, opts) do
    drop(session_id, opts)

    case Plane.call("session.erased", %{"session_id" => session_id, "device" => device}, plane) do
      {:ok, _done} ->
        [session_id]

      {:error, reason} ->
        Logger.info(
          "troupe: #{session_id} is erased here and the plane was not told: #{inspect(reason)}"
        )

        []
    end
  end

  # This copy, the sealer first.
  defp drop(session_id, opts) do
    stop_sealer(session_id)
    :ok = Keyword.get(opts, :erase, &Troupe.erase_session/1).(session_id)
    forget(session_id)
  end

  @doc """
  The store a private session writes through: signatures from the plane, bytes direct.

  Exposed because a restore needs one before there is a session to seal, and because a
  test that built its own would be testing its own idea of the arrangement.
  """
  @spec store(String.t(), GenServer.server()) :: Signed.t()
  def store(session_id, plane \\ Plane) do
    %Signed{
      session_id: session_id,
      presign: fn method, keys ->
        case Plane.call(
               "session.presign",
               %{
                 "session_id" => session_id,
                 "method" => Atom.to_string(method),
                 "keys" => keys
               },
               plane
             ) do
          {:ok, %{"urls" => urls}} -> {:ok, urls}
          {:error, reason} -> {:error, reason}
        end
      end,
      list: fn prefix ->
        case Plane.call(
               "session.objects",
               %{"session_id" => session_id, "prefix" => prefix},
               plane
             ) do
          {:ok, %{"keys" => keys}} -> {:ok, keys}
          {:error, reason} -> {:error, reason}
        end
      end
    }
  end

  # -- the four steps ---------------------------------------------------------

  defp subject(plane) do
    case Plane.subject(plane) do
      subject when is_binary(subject) -> {:ok, subject}
      nil -> {:error, :unlinked}
    end
  end

  # Registration comes first, and not only because the rest needs a row. It is what makes
  # every later call a statement about a session the plane already agrees is this
  # person's — including `session.assertion`, which is where a deprovisioned person stops.
  # One carried on after a restart names the epoch this device held, so a claim another
  # device made meanwhile refuses it rather than this device sealing beside that one.
  defp register(plane, session_id, opts) do
    params =
      %{"session_id" => session_id, "device" => device(opts), "title" => opts[:title]}
      |> then(&if(opts[:epoch], do: Map.put(&1, "epoch", opts[:epoch]), else: &1))

    Plane.call("session.register", params, plane)
  end

  defp context(plane, subject, session_id, row, opts, exchange) do
    with {:ok, key_manager} <- exchange.(plane, session_id) do
      {name, kms_options} = Keyword.pop(key_manager, :name)

      Context.open(session_id,
        team: {:person, name || subject},
        epoch: row["epoch"] || 1,
        owner_subject: subject,
        store: Keyword.get_lazy(opts, :store, fn -> store(session_id, plane) end),
        state_dir: opts[:state_dir],
        workspace: opts[:workspace],
        kms: Keyword.get(opts, :kms, KMS.adapter()),
        kms_options: kms_options
      )
    end
  end

  # How the daemon gets a key manager token. A function rather than a call, because a
  # test that has no plane to sign an assertion still has a seal path worth exercising —
  # and because saying so here is better than a flag that quietly skips a step.
  defp key_manager(opts), do: Keyword.get(opts, :key_manager, &exchange/2)

  # The same exchange a pod makes, with the same two halves: the plane says who the
  # caller is, and the key manager decides what that person may reach. The daemon is
  # never handed a token the plane minted, because a token the plane minted is a token
  # the plane held.
  defp exchange(plane, session_id) do
    with {:ok, grant} <- Plane.call("session.assertion", %{"session_id" => session_id}, plane) do
      manager = grant["key_manager"]

      case KMS.OpenBao.jwt_login(
             manager["address"],
             manager["auth_path"],
             manager["role"],
             grant["assertion"]
           ) do
        # The address the key manager named, not whatever this machine was configured
        # with: a laptop has no reason to know where the cluster keeps its key manager,
        # and the plane is the thing that does. The same for the person's name there.
        {:ok, %{token: token}} ->
          {:ok,
           [
             token: token,
             address: manager["address"],
             mount: manager["mount"],
             name: manager["name"]
           ]}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # From where storage has the session to, with what the log holds after that: nothing
  # for a session that starts sealing as it is created, apart from the events its start
  # wrote before the sealer subscribed, and everything since for one carried on.
  defp sealer(plane, context, opts) do
    session_id = context.session_id
    read = Keyword.get(opts, :backfill, &Troupe.replay_from/2)

    # Started again after a crash, and not after a report refused as stale, which is this
    # device's instruction to stop (issue #433).
    child =
      Supervisor.child_spec(
        {Sealer,
         [
           context: context,
           name: {:via, Registry, {__MODULE__.Registry, session_id}},
           subscribe: Keyword.get(opts, :subscribe, &Troupe.subscribe/1),
           report: report(plane, context),
           sealed_through: Keyword.get(opts, :sealed_through, 0),
           object_bytes: Keyword.get(opts, :object_bytes, 0),
           backfill: fn after_seq -> read.(session_id, after_seq) end
         ]},
        restart: :transient
      )

    case DynamicSupervisor.start_child(Keyword.get(opts, :supervisor, __MODULE__.Sealers), child) do
      {:ok, pid} -> {:ok, pid}
      # The same session started twice is one session: a client reconnecting and asking
      # again must not get a second sealer subscribed to the same events.
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  # Every seal tells the plane how far this session has got, which is the same report a
  # pod makes at dormancy and the same fence: a report carrying an epoch another device
  # has passed is refused, and that refusal is this device's instruction to stop.
  defp report(plane, context) do
    fn attrs ->
      params = %{
        "session_id" => context.session_id,
        "epoch" => context.epoch,
        "last_seq" => attrs[:last_seq] || attrs["last_seq"] || 0,
        "head_hash" => attrs[:head_hash] || attrs["head_hash"],
        "object_bytes" => attrs[:object_bytes] || attrs["object_bytes"] || 0
      }

      case Plane.call("session.register", params, plane) do
        {:ok, _row} ->
          :ok

        {:error, {:rpc, %{"message" => "stale_version"}}} ->
          hear(context.session_id, {:elsewhere, nil})

          Logger.warning(
            "troupe: #{context.session_id} is held by another device; this one has stopped sealing"
          )

          {:error, :stale_version}

        {:error, reason} ->
          # Not an error worth raising: the segment is in storage either way, and an
          # un-anchored segment is fixed by the next report that lands.
          Logger.debug("troupe: #{context.session_id} seal not reported: #{inspect(reason)}")
          :ok
      end
    end
  end

  # What the person will see in a list of their devices when two of them have a session.
  # A name they chose, or the machine's, which is better than nothing and not checked.
  defp device(opts) do
    opts[:device] || Application.get_env(:troupe_gateway, :device_name) ||
      (:inet.gethostname() |> elem(1) |> to_string())
  end
end

defmodule Troupe.Gateway.Private.Sealers do
  @moduledoc """
  The sealers, one per private session, and the registry that names them.

  A DynamicSupervisor rather than a link from whoever asked, because a session's unsealed
  tail has to outlive the client that created it. And shutting this down is what seals
  everything one last time: `Sealer` traps exits and seals in `terminate/2`, so a daemon
  going away takes its last segments with it rather than leaving them on disk.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  @impl Supervisor
  def init(_opts) do
    # What the plane last said of a session not sealing here (`Private.sync/1`), kept as
    # long as the sealers are: a restart forgets it, and the next link asks again.
    :ets.new(Troupe.Gateway.Private.Heard, [:named_table, :public, :set])

    children = [
      {Registry, keys: :unique, name: Troupe.Gateway.Private.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Troupe.Gateway.Private.Sealers}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
