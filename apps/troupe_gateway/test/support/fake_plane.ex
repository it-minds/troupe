defmodule Troupe.Gateway.FakePlane do
  @moduledoc """
  A plane, as far as the daemon can tell: four methods over real HTTP.

  The daemon may not depend on `troupe_plane` — that is a boundary rule, and the reason
  for it is that a daemon which could call into the plane's modules would one day do it
  instead of using the protocol. So a test that wants to watch the daemon seal a private
  session has to stand up something that answers `session.register`, `session.presign`,
  `session.objects` and `session.assertion`, and that is this.

  Two of the four are *real*: `session.presign` signs against the same MinIO the daemon
  then writes to, and `session.objects` lists it. Faking those would leave the test
  proving that the daemon can talk to a mock. `session.register` keeps rows in an Agent
  and implements the one behaviour the daemon has to cope with — the epoch fence, which
  `session.presign` keeps too for a write naming an epoch (Decision 800) — and
  `session.assertion` is not implemented here at all, because minting an assertion is
  signing, and signing is the plane's job. The tests pass `:key_manager` instead and the
  exchange is proven where it can be, in the plane's own suite.

  And the two an erasure needs (Decision 756): `session.erasures` names the rows `erase/2`
  marked that a device has not acknowledged, and `session.erased` records the device and
  deletes every version under the prefix in MinIO, as the plane does. `session.get`
  answers a row as its owner reads it, and an erased one as `not_found`, as the plane does.
  `session.erase` is the person's own erasure (Decision 789): the key first, which
  `refuse_keys/2` can make the key manager refuse, leaving the row `erasure_pending` until
  an erase or a `session.erasures` finds it willing again.

  And `initialize`, the handshake a daemon makes when a token arrives (Decision 868): a
  method this plane does not have, as a plane from before the version policy, unless
  `initialize_with/2` says what it answers. And `me.client_defaults`, the organisation's
  document a daemon fetches after it (Decision 869), unanswered unless
  `client_defaults_with/2` says what it is.

  And a signing key of its own where `sign/1` gives it one (#657): served at
  `/.well-known/troupe-signing-key`, and `me.client_defaults` signed with it as the plane
  signs it. `sign/1` again is a rotation.

  It takes one plane token at a time, `"plane-token"` unless told otherwise, and
  `renew/2` replaces it, as a plane token running out and a client renewing it does: the
  old one is refused from then on (issue #365).
  """

  use Agent

  alias Troupe.ObjectStore
  alias Troupe.Protocol.Memory.Entries
  alias Troupe.Protocol.PlaneSignature

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    token = Keyword.get(opts, :token, "plane-token")

    Agent.start_link(
      fn ->
        %{
          sessions: %{},
          calls: [],
          token: token,
          refuse_keys: false,
          before: nil,
          any_epoch: false
        }
      end,
      name: Keyword.get(opts, :name)
    )
  end

  @doc "Start the fake plane and an HTTP server in front of it. Returns its base URL."
  @spec serve(keyword()) :: %{url: String.t(), state: pid()}
  def serve(opts \\ []) do
    {:ok, state} = start_link(token: Keyword.get(opts, :token, "plane-token"))

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.Router, state: state},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{url: "http://127.0.0.1:#{port}", state: state, server: server}
  end

  @doc """
  What `initialize` answers from now on (Decision 868): `{:ok, result}`, or `{:refuse,
  data}` for `update_required` with that `data`. Never set, it is a method this plane does
  not have, as a plane from before the version policy.
  """
  @spec initialize_with(pid(), {:ok, map()} | {:refuse, map()}) :: :ok
  def initialize_with(state, answer), do: Agent.update(state, &Map.put(&1, :initialize, answer))

  @doc """
  What `me.client_defaults` answers from now on: the organisation's document (Decision
  869). Never set, the plane does not answer it, and a daemon keeps the copy it had.
  """
  @spec client_defaults_with(pid(), map()) :: :ok
  def client_defaults_with(state, answer), do: Agent.update(state, &Map.put(&1, :client_defaults, answer))

  @doc """
  What `me.client_versions` answers from now on: each component's policy and where
  releases are, `%{"versions" => ..., "release" => %{"url" => ...}}`, signed as
  `client_versions` where the plane signs. Never set, the plane does not answer it.
  """
  @spec client_versions_with(pid(), map()) :: :ok
  def client_versions_with(state, body),
    do: Agent.update(state, &Map.put(&1, :client_versions, body))

  @doc """
  What `me.memory` answers from now on: the organisation's memory documents a person's
  sessions read (#55), signed as `memory` where the plane signs. Never set, the plane does
  not answer it, as a plane from before them.
  """
  @spec memory_with(pid(), [map()]) :: :ok
  def memory_with(state, documents), do: Agent.update(state, &Map.put(&1, :memory, documents))

  @doc """
  Keep a person's own memory document (#55's user level) from now on, empty at version 0:
  `me.memory` lists it after the documents `memory_with/2` set, with `user` beside them, and
  `me.memory.put` saves it, the whole text over the version edited or one `append`ed entry
  under the day's heading, as the plane does. Answers what it holds with `own/1`.
  """
  @spec keep_own(pid()) :: :ok
  def keep_own(state), do: Agent.update(state, &Map.put(&1, :own, %{"version" => 0, "text" => ""}))

  @doc "The person's teams, by name, which `me.memory` asked with `entries` names."
  @spec teams_with(pid(), [String.t()]) :: :ok
  def teams_with(state, teams), do: Agent.update(state, &Map.put(&1, :teams, teams))

  @doc "Which levels the person may change, which `me.memory` asked with `entries` says (`roles`)."
  @spec roles_with(pid(), map()) :: :ok
  def roles_with(state, roles), do: Agent.update(state, &Map.put(&1, :roles, roles))

  @doc "The person's own document as this plane holds it."
  @spec own(pid()) :: map() | nil
  def own(state), do: Agent.get(state, &Map.get(&1, :own))

  @doc """
  Sign from now on with a key of the plane's own, a new one each time (a rotation), as
  `Troupe.Protocol.PlaneSignature` lays it out. Answers its fingerprint.
  """
  @spec sign(pid()) :: String.t()
  def sign(state) do
    {public, secret} = :crypto.generate_key(:eddsa, :ed25519)
    Agent.update(state, &Map.put(&1, :signing, %{public: public, secret: secret}))
    PlaneSignature.fingerprint(public)
  end

  @doc false
  def signing_key(state) do
    case Agent.get(state, &Map.get(&1, :signing)) do
      nil -> nil
      %{public: public} -> PlaneSignature.key_json(public)
    end
  end

  @doc "Take `token` from now on, and refuse the one taken before."
  @spec renew(pid(), String.t()) :: :ok
  def renew(state, token), do: Agent.update(state, &%{&1 | token: token})

  @doc false
  def token(state), do: Agent.get(state, & &1.token)

  @doc "The invitations the fake plane holds for a session, by subject, each with its keys."
  @spec invitations(pid(), String.t()) :: map()
  def invitations(state, session_id), do: invites(state, session_id)

  @doc "Whose invitation `session.keys` answers from now on: the person reading."
  @spec keys_for(pid(), String.t()) :: :ok
  def keys_for(state, subject), do: Agent.update(state, &Map.put(&1, :reader, subject))

  @doc "The row the fake plane holds for a session, or nil."
  @spec row(pid(), String.t()) :: map() | nil
  def row(state, session_id), do: Agent.get(state, & &1.sessions[session_id])

  @doc "Every method the daemon called, oldest first."
  @spec calls(pid()) :: [{String.t(), map()}]
  def calls(state), do: state |> Agent.get(& &1.calls) |> Enum.reverse()

  @doc "Take the session over, as another device would."
  @spec steal(pid(), String.t()) :: map()
  def steal(state, session_id) do
    Agent.get_and_update(state, fn %{sessions: sessions} = s ->
      row = Map.fetch!(sessions, session_id)
      taken = %{row | "epoch" => row["epoch"] + 1, "device" => "the other one"}
      {taken, %{s | sessions: Map.put(sessions, session_id, taken)}}
    end)
  end

  @doc "Erase the session, as the plane would on somebody's word: a row, erased."
  @spec erase(pid(), String.t()) :: map()
  def erase(state, session_id) do
    Agent.get_and_update(state, fn %{sessions: sessions} = s ->
      row = Map.get(sessions, session_id, %{"session_id" => session_id, "kind" => "private"})
      erased = Map.merge(row, %{"state" => "erased", "applied_by" => []})
      {erased, %{s | sessions: Map.put(sessions, session_id, erased)}}
    end)
  end

  @doc """
  Erase the session where the key manager would not destroy its key: the row is
  `erasure_pending`, listed as it is, and not yet named to any device (Decision 756), and
  the key manager goes on refusing until `refuse_keys/2` says otherwise.
  """
  @spec pend_erasure(pid(), String.t()) :: map()
  def pend_erasure(state, session_id) do
    Agent.get_and_update(state, fn %{sessions: sessions} = s ->
      row = Map.get(sessions, session_id, %{"session_id" => session_id, "kind" => "private"})
      pending = Map.put(row, "state", "erasure_pending")
      {pending, %{s | sessions: Map.put(sessions, session_id, pending), refuse_keys: true}}
    end)
  end

  @doc """
  Have the key manager refuse to destroy a key, or destroy it again. While it refuses, an
  erasure leaves the row `erasure_pending`; once it does not, the next `session.erase` or
  `session.erasures` finishes it, as the plane's does.
  """
  @spec refuse_keys(pid(), boolean()) :: :ok
  def refuse_keys(state, refuse?), do: Agent.update(state, &%{&1 | refuse_keys: refuse?})

  @doc """
  Sign a write whatever epoch it names, as a plane from before Decision 800 does: a device
  that lost the session then hears so at the report after its write, not before it.
  """
  @spec sign_any_epoch(pid()) :: :ok
  def sign_any_epoch(state), do: Agent.update(state, &%{&1 | any_epoch: true})

  @doc """
  A row another device registered and sealed, as if the session had been carried on there:
  `device`, `epoch`, `last_seq` and `head_hash` from `attrs`, over a first registration's.
  """
  @spec put(pid(), String.t(), map()) :: map()
  def put(state, session_id, attrs) do
    row =
      Map.merge(
        %{
          "session_id" => session_id,
          "kind" => "private",
          "epoch" => 1,
          "device" => "the other one",
          "last_seq" => 0,
          "head_hash" => nil
        },
        attrs
      )

    Agent.update(state, &%{&1 | sessions: Map.put(&1.sessions, session_id, row)})
    row
  end

  # -- the methods ------------------------------------------------------------

  @doc """
  Run `fun` once, before the plane answers the next call `match?` accepts (a function of
  the method and its params): how a test has something happen at the plane at one moment
  of what the daemon is doing, such as another device claiming a session in the middle of
  a seal. `fun` runs in the process answering that call, which waits for it.
  """
  @spec before(pid(), (String.t(), map() -> boolean()), (-> any())) :: :ok
  def before(state, match?, fun), do: Agent.update(state, &%{&1 | before: {match?, fun}})

  @doc false
  def call(state, method, params) do
    Agent.update(state, fn s -> %{s | calls: [{method, params} | s.calls]} end)
    run_before(state, method, params)
    dispatch(state, method, params)
  end

  defp run_before(state, method, params) do
    hook =
      Agent.get_and_update(state, fn
        %{before: {match?, fun}} = s ->
          if match?.(method, params), do: {fun, %{s | before: nil}}, else: {nil, s}

        s ->
          {nil, s}
      end)

    if hook, do: hook.()
  end

  defp dispatch(state, "session.register", %{"claim" => true} = params) do
    id = params["session_id"]

    held = params["epoch"]

    Agent.get_and_update(state, fn %{sessions: sessions} = s ->
      case sessions[id] do
        nil ->
          {{:error, "not_found"}, s}

        %{"epoch" => ^held} = row ->
          taken = %{row | "epoch" => held + 1, "device" => params["device"]}
          {{:ok, taken}, %{s | sessions: Map.put(sessions, id, taken)}}

        _passed ->
          {{:error, "stale_version"}, s}
      end
    end)
  end

  defp dispatch(state, "session.get", %{"session_id" => id}) do
    case row(state, id) do
      nil -> {:error, "not_found"}
      %{"state" => "erased"} -> {:error, "not_found", %{"session_id" => id, "reason" => "erased"}}
      row -> {:ok, row}
    end
  end

  defp dispatch(state, "session.register", params) do
    id = params["session_id"]

    Agent.get_and_update(state, fn %{sessions: sessions} = s ->
      case sessions[id] do
        nil ->
          row = %{
            "session_id" => id,
            "kind" => "private",
            "epoch" => 1,
            "device" => params["device"],
            "last_seq" => params["last_seq"] || 0,
            "head_hash" => params["head_hash"]
          }

          {{:ok, row}, %{s | sessions: Map.put(sessions, id, row)}}

        %{} = row ->
          seal(s, sessions, id, row, params)
      end
    end)
  end

  # An epoch named is the one the caller holds, and one the row has moved past is signed
  # nothing (Decision 800). None named signs as before: a restore holds none.
  defp dispatch(state, "session.presign", params) do
    with :ok <- known(state, params["session_id"]),
         :ok <- holds(state, params["session_id"], params["epoch"]) do
      store = ObjectStore.from_env()
      method = String.to_existing_atom(params["method"])
      prefix = "sessions/#{params["session_id"]}/"
      keys = Enum.filter(params["keys"], &String.starts_with?(&1, prefix))

      urls = Map.new(keys, &{&1, ObjectStore.presign(store, method, &1, ttl: 300)})
      {:ok, %{"session_id" => params["session_id"], "expires_in" => 300, "urls" => urls}}
    end
  end

  defp dispatch(state, "session.objects", params) do
    with :ok <- known(state, params["session_id"]) do
      prefix = params["prefix"] || "sessions/#{params["session_id"]}/"
      {:ok, keys} = ObjectStore.list(ObjectStore.from_env(), prefix)
      {:ok, %{"session_id" => params["session_id"], "keys" => keys}}
    end
  end

  # The person's erasure of their own session: the key first, and `erasure_pending` until
  # it is gone. The objects wait for a device to say it has stopped (`session.erased`).
  defp dispatch(state, "session.erase", %{"session_id" => id}) do
    Agent.get_and_update(state, fn %{sessions: sessions} = s ->
      case sessions[id] do
        nil ->
          {{:error, "not_found"}, s}

        row ->
          erased = finish(row, s.refuse_keys)

          answer = %{
            "session_id" => id,
            "erased" => erased["state"] == "erased",
            "state" => erased["state"],
            "head_hash" => row["head_hash"]
          }

          {{:ok, answer}, %{s | sessions: Map.put(sessions, id, erased)}}
      end
    end)
  end

  # A row whose key is not destroyed yet is tried again first, as the plane's is.
  defp dispatch(state, "session.erasures", %{"device" => device}) do
    Agent.update(state, fn s ->
      %{s | sessions: Map.new(s.sessions, fn {id, row} -> {id, retried(row, s.refuse_keys)} end)}
    end)

    erasures =
      for {id, %{"state" => "erased"} = row} <- Agent.get(state, & &1.sessions),
          device not in row["applied_by"],
          do: %{"session_id" => id, "erased_at" => "2026-10-03T00:00:00Z"}

    {:ok, %{"erasures" => erasures}}
  end

  defp dispatch(state, "session.erased", %{"session_id" => id, "device" => device}) do
    case row(state, id) do
      %{"state" => "erased"} -> delete_objects(state, id, device)
      _other -> {:error, "not_found"}
    end
  end

  # The handshake (Decision 868): what `initialize_with/2` said, and otherwise the method a
  # plane from before the version policy does not have.
  #
  # A served handshake names `policy.revision`, a digest of the two answers below, as the
  # plane's does (#657); a refusal is signed as `update_required` where this plane signs,
  # and `{:refuse_unsigned, data}` refuses with no signature even then.
  defp dispatch(state, "initialize", _params) do
    case Agent.get(state, &Map.get(&1, :initialize)) do
      {:ok, result} ->
        {:ok, Map.put_new(result, "policy", %{"revision" => revision(state)})}

      {:refuse, data} ->
        {:rpc_error, -32_016, "update_required", signed(state, "update_required", data)}

      {:refuse_unsigned, data} ->
        {:rpc_error, -32_016, "update_required", data}

      nil ->
        {:rpc_error, -32_601, "method_not_found", %{"method" => "initialize"}}
    end
  end

  defp dispatch(state, "me.client_versions", _params) do
    case Agent.get(state, &Map.get(&1, :client_versions)) do
      nil ->
        {:rpc_error, -32_601, "method_not_found", %{"method" => "me.client_versions"}}

      %{"versions" => versions, "release" => release} = body ->
        signed = signed(state, "client_versions", body)
        {:ok, versions |> Map.put("release", release) |> put_signed(signed["signed"])}
    end
  end

  defp dispatch(state, "me.client_defaults", _params) do
    case Agent.get(state, &Map.get(&1, :client_defaults)) do
      nil -> {:rpc_error, -32_601, "method_not_found", %{"method" => "me.client_defaults"}}
      answer -> {:ok, signed(state, "client_defaults", answer)}
    end
  end

  # Asked with `entries`, it names the person's teams too, where `teams_with/2` set them; the
  # documents' entries it leaves for the daemon to read off the text, as a plane from before
  # them would.
  defp dispatch(state, "me.memory", params) do
    names = Agent.get(state, &Map.get(&1, :teams))
    teams = if is_list(names) and params["entries"] == true, do: %{"teams" => names}, else: %{}
    roles = Agent.get(state, &Map.get(&1, :roles))
    teams = if is_map(roles) and params["entries"] == true, do: Map.put(teams, "roles", roles), else: teams

    case Agent.get(state, &{Map.get(&1, :memory), Map.get(&1, :own)}) do
      {nil, nil} -> {:rpc_error, -32_601, "method_not_found", %{"method" => "me.memory"}}
      {documents, nil} -> {:ok, signed(state, "memory", Map.merge(%{"documents" => documents}, teams))}
      {documents, own} -> {:ok, signed(state, "memory", Map.merge(%{"documents" => List.wrap(documents) ++ own_documents(own), "user" => own_json(own)}, teams))}
    end
  end

  defp dispatch(state, "me.memory.put", params) do
    Agent.get_and_update(state, fn held ->
      case own_put(Map.get(held, :own), params) do
        {:ok, now, entry} ->
          {{:ok, %{"changed" => true, "entry" => entry, "user" => own_json(now)}}, Map.put(held, :own, now)}

        refused ->
          {refused, held}
      end
    end)
  end

  # A laptop's own sign-in for steering (#58 slice 2): a grant for the device, kept here
  # until it is released, exchanged at `/auth/relay` for a token of the laptop's door
  # (`laptop:` and a number, which `FakeRelay` takes), unless `refuse_grants/2` said no.
  defp dispatch(state, "remote.grant", params) do
    case Agent.get(state, &Map.get(&1, :refuse_grants)) do
      nil ->
        grant = "rg_fake." <> Integer.to_string(System.unique_integer([:positive]))

        Agent.update(state, fn s ->
          Map.update(s, :grants, %{grant => params["device"]}, &Map.put(&1, grant, params["device"]))
        end)

        {:ok, %{"grant" => grant, "device" => params["device"]}}

      {code, message, data} ->
        {:rpc_error, code, message, data}
    end
  end

  # Invitations into a private session (#765), kept as the plane keeps them: whom, at which
  # role, and where each generation of the session's key was put in their slot, a person's
  # name at the key manager being their subject here. Taking one back marks the row
  # `rekey_due` until `session.rekeyed` names the next generation with a key for everybody
  # still invited. `session.keys` answers the slots of `keys_for/2`'s person, with no
  # assertion: this plane signs none.
  defp dispatch(state, "session.invite_slot", %{"session_id" => id, "subject" => subject}) do
    case row(state, id) do
      nil ->
        {:error, "not_found"}

      row ->
        {:ok,
         %{
           "session_id" => id,
           "subject" => subject,
           "display_name" => subject,
           "prefix" => "troupe/people/#{subject}/invited/#{id}/",
           "key_version" => row["key_version"] || 1
         }}
    end
  end

  defp dispatch(state, "session.invite", %{"session_id" => id, "subject" => subject} = params) do
    versions = for key <- params["keys"] || [], do: key["key_version"]

    case row(state, id) do
      nil ->
        {:error, "not_found"}

      row ->
        if Enum.sort(versions) == Enum.to_list(1..(row["key_version"] || 1)) do
          invite = %{"subject" => subject, "role" => params["role"], "keys" => params["keys"]}
          put_invite(state, id, subject, invite)
          {:ok, %{"session_id" => id, "invite" => Map.delete(invite, "keys"), "pushed" => false}}
        else
          {:rpc_error, -32_602, "invalid_params", %{"field" => "keys"}}
        end
    end
  end

  defp dispatch(state, "session.uninvite", %{"session_id" => id, "subject" => subject}) do
    if invites(state, id)[subject] do
      take_back(state, id, subject)

      {:ok, %{"session_id" => id, "subject" => subject, "rekey_due" => true, "pushed" => false}}
    else
      {:error, "not_found"}
    end
  end

  defp dispatch(state, "session.invites", %{"session_id" => id}) do
    rows = for {_subject, invite} <- invites(state, id), do: Map.delete(invite, "keys")
    {:ok, %{"session_id" => id, "invites" => rows}}
  end

  defp dispatch(
         state,
         "session.rekeyed",
         %{"session_id" => id, "key_version" => version} = params
       ) do
    given = Map.new(params["keys"] || [], &{&1["subject"], &1["slot"]})
    missing = invites(state, id) |> Map.keys() |> Enum.reject(&Map.has_key?(given, &1))

    if missing == [] do
      rekey(state, id, version, given)
      {:ok, row(state, id)}
    else
      {:rpc_error, -32_602, "invalid_params", %{"field" => "keys", "missing" => missing}}
    end
  end

  defp dispatch(state, "session.keys", %{"session_id" => id}) do
    reader = Agent.get(state, &Map.get(&1, :reader))

    case reader && invites(state, id)[reader] do
      nil ->
        {:error, "not_found"}

      invite ->
        {:ok,
         %{
           "session_id" => id,
           "key_version" => (row(state, id) || %{})["key_version"] || 1,
           "keys" => invite["keys"]
         }}
    end
  end

  # An artifact published (#62): the plane's answer, as its id, the next version of one
  # named, and an address on an artifacts host; a page with no title is refused, as the
  # plane refuses it.
  defp dispatch(_state, "artifact.publish", %{"title" => title} = params) when is_binary(title) and title != "" do
    id = params["id"] || "art-fakefakefakefake"

    {:ok,
     %{
       "id" => id,
       "title" => title,
       "kind" => params["kind"],
       "visibility" => params["visibility"],
       "version" => if(params["id"], do: 2, else: 1),
       "origin" => Map.take(params, ["session_id", "agent"]),
       "url" => "https://artifacts.example.test/a/#{id}/"
     }}
  end

  defp dispatch(_state, "artifact.publish", _params),
    do: {:rpc_error, -32_602, "invalid_params", %{"reason" => "an artifact needs a title"}}

  # An upload handle, as the plane makes one: a PUT presigned into the development MinIO for
  # each file under `artifact-uploads/<handle>/`.
  defp dispatch(_state, "artifact.upload.begin", %{"files" => files}) do
    handle = "up-fake#{System.unique_integer([:positive])}"
    store = ObjectStore.from_env()

    {:ok,
     %{
       "upload" => handle,
       "expires_in" => 900,
       "urls" =>
         Enum.map(files, fn file ->
           key = "artifact-uploads/#{handle}/#{file["path"]}"
           %{"path" => file["path"], "url" => ObjectStore.presign(store, :put, key, ttl: 300)}
         end)
     }}
  end

  # The person's own artifacts, as the plane lists them, with the gallery's address.
  defp dispatch(_state, "artifact.list", params) do
    {:ok,
     %{
       "enabled" => true,
       "profiles" => ["dev"],
       "publish_organisation" => "everyone",
       "public_links" => false,
       "gallery_url" => "https://plane.example.test/console#/artifacts",
       "asked" => params,
       "artifacts" => [
         %{
           "id" => "art-fakefakefakefake",
           "title" => "Weekly",
           "kind" => "html",
           "visibility" => "organisation",
           "version" => 1,
           "mine" => true
         }
       ]
     }}
  end

  # The viewer's methods (#62), as the plane answers them for the person: somebody else's
  # artifact is not there to see, and its owner's controls are refused.
  defp dispatch(_state, "artifact." <> _, %{"id" => "art-somebody-elses"} = params) do
    if Map.has_key?(params, "version") and not Map.has_key?(params, "role"),
      do: {:rpc_error, -32_004, "forbidden", %{"reason" => "only its owner pins an artifact"}},
      else: {:rpc_error, -32_005, "not_found", %{"id" => "art-somebody-elses"}}
  end

  defp dispatch(_state, "artifact.get", %{"id" => id}) do
    {:ok,
     %{
       "id" => id,
       "title" => "Weekly",
       "kind" => "html",
       "visibility" => "organisation",
       "version" => 1,
       "mine" => true,
       "versions" => [%{"n" => 1, "note" => nil, "url" => "https://artifacts.example.test/a/#{id}/v1/"}],
       "shares" => []
     }}
  end

  defp dispatch(_state, "artifact.open", %{"id" => _id}),
    do: {:ok, %{"url" => "https://artifacts.example.test/enter?ticket=fake", "expires_in" => 60}}

  # One text file of a version, as the plane reads it for a client.
  defp dispatch(_state, "artifact.read", %{"id" => id} = params),
    do: {:ok, %{"id" => id, "version" => params["version"] || 1, "path" => params["path"] || "index.md", "text" => "# Weekly"}}

  defp dispatch(_state, "artifact.share", %{"id" => _id, "role" => role}) do
    {:ok,
     %{
       "token" => "tok",
       "url" => "https://artifacts.example.test/s/tok",
       "share" => %{"id" => "sh-1", "role" => role, "public" => false, "state" => "live"}
     }}
  end

  defp dispatch(_state, "artifact.unshare", %{"id" => id} = params),
    do: {:ok, Map.merge(%{"revoked" => true, "id" => id}, Map.take(params, ["share", "person"]))}

  defp dispatch(_state, method, %{"id" => id} = params) when method in ["artifact.rollback", "artifact.pin"],
    do: {:ok, %{"id" => id, "version" => 2, "pinned" => if(method == "artifact.pin", do: params["version"])}}

  # The person's own memory's history and a rollback, over what `keep_own/1` set.
  defp dispatch(state, "me.memory.history", params) do
    case Agent.get(state, &Map.get(&1, :own)) do
      nil ->
        {:rpc_error, -32_601, "method_not_found", %{"method" => "me.memory.history"}}

      own ->
        {:ok,
         %{
           "versions" => [%{"version" => own["version"], "changed_by" => "ada@example.test"}],
           "version" => own["version"],
           "text" => own["text"],
           "against" => params["against"],
           "against_text" => nil,
           "diff" => [%{"op" => "add", "text" => own["text"]}]
         }}
    end
  end

  defp dispatch(state, "me.memory.rollback", %{"to" => to, "version" => version}) do
    Agent.get_and_update(state, fn held ->
      case Map.get(held, :own) do
        %{"version" => ^version} ->
          now = %{"version" => version + 1, "text" => "rolled back to v#{to}"}
          {{:ok, %{"changed" => true, "entry" => nil, "user" => own_json(now)}}, Map.put(held, :own, now)}

        own ->
          {{:rpc_error, -32_006, "conflict", %{"reason" => "saved since", "version" => own && own["version"]}}, held}
      end
    end)
  end

  # What is in effect for the person in a team, as the plane answers it: a fixed answer for
  # the team `sales`, `not_found` for any other.
  defp dispatch(_state, "memory.in_effect", params) do
    case params["team"] do
      team when team in [nil, "sales"] ->
        {:ok,
         %{
           "team" => "sales",
           "profile" => params["profile"],
           "organisation" => %{"name" => "Example"},
           "levels" => [%{"scope" => "organisation", "name" => nil, "version" => 1, "entries" => 1}],
           "entries" => [
             %{
               "topic" => "Tone",
               "body" => "Short answers.",
               "level" => %{"scope" => "user", "name" => nil},
               "replaces" => [%{"level" => %{"scope" => "organisation", "name" => nil}, "topic" => "Tone", "body" => "Plain English."}]
             }
           ]
         }}

      team ->
        {:rpc_error, -32_005, "not_found", %{"team" => team, "reason" => "you are in no team called #{team}"}}
    end
  end

  # A level of the organisation's memory: the team `sales`'s is this person's to change, the
  # organisation's is not, as the plane decides it.
  defp dispatch(_state, "admin.memory." <> _ = method, %{"scope" => "team", "name" => "sales"} = params) do
    case method do
      "admin.memory.get" -> {:ok, %{"scope" => "team", "name" => "sales", "version" => 1, "text" => "## Prices\n\nFramework.", "entries" => [%{"topic" => "Prices", "body" => "Framework."}]}}
      "admin.memory.preview" -> {:ok, %{"version" => 1, "bytes" => 10, "diff" => [], "entries" => params["entries"]}}
      "admin.memory.put" -> {:ok, %{"document" => %{"version" => 2}, "changes" => %{"version" => %{"from" => 1, "to" => 2}}}}
    end
  end

  defp dispatch(_state, "admin.memory." <> _, params),
    do: {:rpc_error, -32_004, "forbidden", %{"reason" => "only a platform admin changes #{params["scope"]}'s memory"}}

  defp dispatch(_state, method, _params), do: {:error, "method_not_found:#{method}"}

  defp take_back(state, id, subject) do
    Agent.update(state, fn s ->
      s
      |> Map.update(:invites, %{}, &Map.update(&1, id, %{}, fn i -> Map.delete(i, subject) end))
      |> Map.update!(
        :sessions,
        &Map.update!(&1, id, fn row -> Map.put(row, "rekey_due", true) end)
      )
    end)
  end

  defp rekey(state, id, version, given) do
    Agent.update(state, fn s ->
      s
      |> Map.update!(:sessions, &Map.update!(&1, id, fn row -> rekeyed_row(row, version) end))
      |> Map.update(
        :invites,
        %{},
        &Map.update(&1, id, %{}, fn i -> given_keys(i, version, given) end)
      )
    end)
  end

  defp rekeyed_row(row, version),
    do: Map.merge(row, %{"key_version" => version, "rekey_due" => false})

  defp given_keys(invites, version, given) do
    Map.new(invites, fn {subject, invite} ->
      key = %{"key_version" => version, "slot" => given[subject]}
      {subject, Map.update!(invite, "keys", &(&1 ++ [key]))}
    end)
  end

  defp invites(state, id),
    do: Agent.get(state, &get_in(&1, [Access.key(:invites, %{}), Access.key(id, %{})]))

  defp put_invite(state, id, subject, invite) do
    Agent.update(state, fn s ->
      Map.update(s, :invites, %{id => %{subject => invite}}, fn all ->
        Map.update(all, id, %{subject => invite}, &Map.put(&1, subject, invite))
      end)
    end)
  end

  defp own_put(nil, _params), do: {:rpc_error, -32_601, "method_not_found", %{"method" => "me.memory.put"}}

  # Under the topic's heading, at the end where it is the last one, as a new section where
  # it is not: enough of the plane's rule for a test to see the topic land.
  defp own_put(own, %{"append" => entry} = params) do
    heading = "## " <> (params["topic"] || "Notes")
    last = own["text"] |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "## ")) |> List.last()

    text =
      cond do
        own["text"] == "" -> heading <> "\n\n- " <> entry
        last == heading -> own["text"] <> "\n- " <> entry
        true -> own["text"] <> "\n\n" <> heading <> "\n\n- " <> entry
      end

    {:ok, %{"version" => own["version"] + 1, "text" => text}, entry}
  end

  defp own_put(own, %{"entries" => entries} = params) do
    {:ok, entries} = Entries.cast(entries)
    own_put(own, params |> Map.delete("entries") |> Map.put("text", Entries.render(entries)))
  end

  defp own_put(%{"version" => version}, %{"text" => text, "version" => version}),
    do: {:ok, %{"version" => version + 1, "text" => text}, nil}

  defp own_put(own, %{"text" => _text}) do
    reason = "your memory was saved somewhere else since; version #{own["version"]} is in force now"
    {:rpc_error, -32_602, "conflict", %{"reason" => reason, "version" => own["version"]}}
  end

  defp own_documents(%{"text" => ""}), do: []

  defp own_documents(own),
    do: [%{"scope" => "user", "name" => nil, "version" => own["version"], "hash" => "sha256:own-#{own["version"]}", "text" => own["text"]}]

  defp own_json(own),
    do: Map.merge(own, %{"bytes" => byte_size(own["text"]), "limit" => 8192, "changed_by" => "ada@example.test"})

  defp put_signed(answer, nil), do: answer
  defp put_signed(answer, signed), do: Map.put(answer, "signed", signed)

  # What the two signed answers say now, as one digest.
  defp revision(state) do
    answers = Agent.get(state, &Map.take(&1, [:client_defaults, :client_versions]))
    :sha256 |> :crypto.hash(:erlang.term_to_binary(answers)) |> Base.encode16(case: :lower)
  end

  @doc "Refuse every `remote.grant` from now on with this error, as a team that forbids offering."
  @spec refuse_grants(pid(), {integer(), String.t(), map()} | nil) :: :ok
  def refuse_grants(state, error), do: Agent.update(state, &Map.put(&1, :refuse_grants, error))

  @doc "The grants this plane holds now, each with its device."
  @spec grants(pid()) :: %{String.t() => String.t()}
  def grants(state), do: Agent.get(state, &Map.get(&1, :grants, %{}))

  @doc "Every grant released so far, oldest first."
  @spec released(pid()) :: [String.t()]
  def released(state), do: state |> Agent.get(&Map.get(&1, :released, [])) |> Enum.reverse()

  @doc "Forget a grant, as a plane whose administrators took it back."
  @spec revoke(pid(), String.t()) :: :ok
  def revoke(state, grant), do: Agent.update(state, &Map.update(&1, :grants, %{}, fn g -> Map.delete(g, grant) end))

  @doc false
  @spec redeem(pid(), String.t() | nil) :: {:ok, map()} | :error
  def redeem(state, grant) do
    case Map.fetch(grants(state), grant) do
      {:ok, device} ->
        token = "laptop:" <> Integer.to_string(System.unique_integer([:positive]))
        exp = System.system_time(:second) + Agent.get(state, &Map.get(&1, :laptop_lifetime, 900))
        Agent.update(state, fn s -> %{s | calls: [{"/auth/relay", %{"grant" => grant}} | s.calls]} end)
        {:ok, %{"token" => token, "expires_at" => exp, "device" => device}}

      :error ->
        :error
    end
  end

  @doc false
  @spec release(pid(), String.t() | nil) :: :ok
  def release(state, grant) do
    Agent.update(state, fn s ->
      s
      |> Map.update(:grants, %{}, &Map.delete(&1, grant))
      |> Map.update(:released, [grant], &[grant | &1])
    end)
  end

  @doc "How long, in seconds, a laptop token minted from now on lives."
  @spec laptop_lifetime(pid(), pos_integer()) :: :ok
  def laptop_lifetime(state, seconds), do: Agent.update(state, &Map.put(&1, :laptop_lifetime, seconds))

  # The device is recorded once every version is gone, and told again otherwise, as the
  # plane's is (Decision 804); this one deletes within the call.
  defp signed(state, kind, answer) do
    case Agent.get(state, &Map.get(&1, :signing)) do
      nil ->
        answer

      %{public: public, secret: secret} ->
        document = PlaneSignature.document(kind, answer)
        signature = :crypto.sign(:eddsa, :none, document, [secret, :ed25519])
        envelope = PlaneSignature.envelope(document, signature, PlaneSignature.fingerprint(public))
        Map.put(answer, "signed", envelope)
    end
  end

  defp delete_objects(state, id, device) do
    case ObjectStore.delete_prefix(ObjectStore.from_env(), "sessions/#{id}/") do
      {:ok, deleted} ->
        Agent.update(state, fn %{sessions: sessions} = s ->
          acknowledged = Map.update!(sessions[id], "applied_by", &[device | &1])
          %{s | sessions: Map.put(sessions, id, acknowledged)}
        end)

        {:ok,
         %{
           "session_id" => id,
           "device" => device,
           "deleting" => false,
           "objects_deleted" => deleted
         }}

      {:error, _not_deleted} ->
        {:error, "unavailable"}
    end
  end

  defp seal(s, sessions, id, %{"epoch" => epoch} = row, params) do
    if is_integer(params["epoch"]) and params["epoch"] != epoch do
      {{:error, "stale_version"}, s}
    else
      sealed = %{
        row
        | "last_seq" => max(params["last_seq"] || 0, row["last_seq"]),
          "head_hash" => params["head_hash"] || row["head_hash"]
      }

      {{:ok, sealed}, %{s | sessions: Map.put(sessions, id, sealed)}}
    end
  end

  defp finish(%{"state" => "erased"} = row, _refused?), do: row

  defp finish(row, refused?) do
    row
    |> Map.put_new("applied_by", [])
    |> Map.put("state", if(refused?, do: "erasure_pending", else: "erased"))
  end

  defp retried(%{"state" => "erasure_pending"} = row, refused?), do: finish(row, refused?)
  defp retried(row, _refused?), do: row

  defp known(state, session_id) do
    if row(state, session_id), do: :ok, else: {:error, "not_found"}
  end

  defp holds(_state, _session_id, nil), do: :ok

  defp holds(state, session_id, epoch) do
    case Agent.get(state, &{&1.any_epoch, &1.sessions[session_id]["epoch"]}) do
      {true, _held} -> :ok
      {false, ^epoch} -> :ok
      {false, _passed} -> {:error, "stale_version"}
    end
  end

  defmodule Router do
    @moduledoc false

    @behaviour Plug

    import Plug.Conn

    alias Troupe.Gateway.FakePlane

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(%{request_path: "/rpc"} = conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)

      if authorized?(conn, FakePlane.token(opts[:state])) do
        answer(conn, request, FakePlane.call(opts[:state], request["method"], request["params"]))
      else
        send_resp(conn, 401, "")
      end
    end

    def call(%{request_path: "/auth/relay"} = conn, opts) do
      {:ok, body, conn} = read_body(conn)

      case FakePlane.redeem(opts[:state], Jason.decode!(body)["grant"]) do
        {:ok, answer} -> json(conn, answer)
        :error -> send_resp(conn, 401, ~s({"error":"unauthenticated"}))
      end
    end

    def call(%{request_path: "/auth/relay/release"} = conn, opts) do
      {:ok, body, conn} = read_body(conn)
      :ok = FakePlane.release(opts[:state], Jason.decode!(body)["grant"])
      send_resp(conn, 204, "")
    end

    def call(%{request_path: "/.well-known/troupe-signing-key"} = conn, opts) do
      case FakePlane.signing_key(opts[:state]) do
        nil -> send_resp(conn, 404, "")
        key -> json(conn, key)
      end
    end

    def call(conn, _opts), do: send_resp(conn, 404, "")

    defp authorized?(conn, token) do
      get_req_header(conn, "authorization") == ["Bearer " <> token]
    end

    defp answer(conn, request, {:ok, result}) do
      json(conn, %{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
    end

    defp answer(conn, request, {:error, message}) do
      json(conn, %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "error" => %{"code" => -32_007, "message" => message}
      })
    end

    defp answer(conn, request, {:rpc_error, code, message, data}) do
      json(conn, %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "error" => %{"code" => code, "message" => message, "data" => data}
      })
    end

    defp answer(conn, request, {:error, message, data}) do
      json(conn, %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "error" => %{"code" => -32_005, "message" => message, "data" => data}
      })
    end

    defp json(conn, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end
  end
end
