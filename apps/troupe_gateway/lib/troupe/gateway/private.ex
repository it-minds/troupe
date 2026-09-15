defmodule Troupe.Gateway.Private do
  @moduledoc """
  Sealing a person's own session from their own machine.

  A private session runs here and nowhere else. Nothing about it reaches a worker, and
  the only thing the plane learns is that it exists and how far it has got. What makes
  that possible is that the daemon can do the two things a pod does — hold a session key
  and write to object storage — without holding either credential.

  * **The key** comes from the key manager, through a token the daemon exchanges for an
    assertion the plane signs. `session.assertion` names the path under
    `troupe/people/<subject>/sessions/<id>`, the person policy covers their own subtree
    and nobody else's, and no pod role covers any of it.
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
  """

  alias Troupe.Gateway.Plane
  alias Troupe.KMS
  alias Troupe.ObjectStore.Signed
  alias Troupe.Sessions.{Context, Sealer}

  require Logger

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
        _ = Sealer.seal_now(pid)
        DynamicSupervisor.terminate_child(__MODULE__.Sealers, pid)
        :ok
    end
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
  defp register(plane, session_id, opts) do
    Plane.call(
      "session.register",
      %{
        "session_id" => session_id,
        "device" => device(opts),
        "title" => opts[:title]
      },
      plane
    )
  end

  defp context(plane, subject, session_id, row, opts, exchange) do
    with {:ok, token} <- exchange.(plane, session_id) do
      Context.open(session_id,
        team: {:person, subject},
        epoch: row["epoch"] || 1,
        owner_subject: subject,
        store: Keyword.get_lazy(opts, :store, fn -> store(session_id, plane) end),
        state_dir: opts[:state_dir],
        workspace: opts[:workspace],
        kms: Keyword.get(opts, :kms, KMS.adapter()),
        kms_options: token
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
        # and the plane is the thing that does.
        {:ok, %{token: token}} -> {:ok, [token: token, address: manager["address"], mount: manager["mount"]]}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp sealer(plane, context, opts) do
    child =
      {Sealer,
       [
         context: context,
         name: {:via, Registry, {__MODULE__.Registry, context.session_id}},
         subscribe: Keyword.get(opts, :subscribe, &Troupe.subscribe/1),
         report: report(plane, context)
       ]}

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
    children = [
      {Registry, keys: :unique, name: Troupe.Gateway.Private.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Troupe.Gateway.Private.Sealers}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
