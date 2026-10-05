defmodule Troupe.Gateway.PrivateTest do
  @moduledoc """
  A person's own session, sealed from their own machine.

  The claim is that a laptop holding no object-storage credential and no key manager
  credential can nonetheless write a session into the cluster's bucket, that nobody else
  can read it, and that a second device taking it over stops this one.

  So the store here is the real MinIO and the signatures are real SigV4, made by the
  fake plane against the same bucket the daemon then writes to. What is faked is the row
  and the assertion: a row is a database and an assertion is a signature, and the daemon
  is allowed to know about neither.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.{Daemon, FakePlane, Plane, Private}
  alias Troupe.ObjectStore
  alias Troupe.Protocol.{Client, Endpoint, Event}
  alias Troupe.Session.Log
  alias Troupe.Sessions.{Cipher, Context, Sealer, Storage}

  @moduletag :object_store

  # The sealing tests write to the real MinIO and take their key from the real OpenBao.
  # Without one of them this says so, and each of those tests fails pointing back here, as
  # the other storage suites do; the rest need neither and run anyway.
  setup_all do
    case services() do
      :ok ->
        {:ok, services: :up}

      {:error, missing} ->
        IO.puts(:stderr, """

        SKIPPED: #{missing}; the sealing tests of #{inspect(__MODULE__)} fail without it.
        Bring it up with `scripts/dev-up`.
        """)

        :ok
    end
  end

  setup do
    plane = FakePlane.serve()
    name = :"plane-#{System.unique_integer([:positive])}"
    start_supervised!({Plane, name: name})

    :ok =
      Plane.link(
        %{
          "subject" => "ada@example.test",
          "plane_url" => plane.url,
          "plane_token" => "plane-token"
        },
        name
      )

    on_exit(fn -> Process.exit(plane.server, :normal) end)

    %{plane: plane, name: name}
  end

  describe "linking" do
    test "the token is held in memory and never written to disk", %{name: name} do
      assert Plane.linked?(name)
      assert Plane.subject(name) == "ada@example.test"

      # A restart is a daemon with no token — deliberately, because a token on disk is a
      # token a backup copies. The label survives; the credential does not.
      stop_supervised!(Plane)
      restarted = :"plane-#{System.unique_integer([:positive])}"
      start_supervised!({Plane, name: restarted})
      refute Plane.linked?(restarted)

      assert {:error, :unlinked} = Plane.call("session.register", %{}, restarted)
    end

    test "unlinking forgets it", %{name: name} do
      :ok = Plane.unlink(name)
      refute Plane.linked?(name)
    end

    # Issue #381: the person signed out at the client that handed it over.
    test "signing out forgets the token for that plane and that person, and nothing else",
         %{name: name, plane: plane} do
      refute Plane.sign_out("https://elsewhere.example.test", "ada@example.test", name)
      refute Plane.sign_out(plane.url, "bob@example.test", name)
      assert Plane.linked?(name)

      assert Plane.sign_out(plane.url <> "/", "ada@example.test", name)
      refute Plane.linked?(name)
      assert {:error, :unlinked} = Plane.call("session.register", %{}, name)
      refute Plane.sign_out(plane.url, "ada@example.test", name)

      # The label stays, so the next link with a token is the same link again.
      assert Plane.subject(name) == "ada@example.test"
      :ok = Plane.link(%{"plane_token" => "plane-token"}, name)
      assert Plane.linked?(name)

      # A client that does not know who signed out names the plane alone.
      assert Plane.sign_out(plane.url, nil, name)
      refute Plane.linked?(name)
    end
  end

  describe "sealing" do
    # The daemon starts these; here there is no daemon, only the parts under test.
    setup context do
      requires_services(context)
      start_supervised!(Private.Sealers)
      :ok
    end

    test "writes a session nobody else can read, through signatures it was handed", ctx do
      session_id = unique("p")

      {:ok, sealer, context} = start_private(session_id, ctx)

      events = [
        %{"seq" => 1, "type" => "session_created", "data" => %{"kind" => "private"}},
        %{"seq" => 2, "type" => "message", "data" => %{"text" => "a private thought"}}
      ]

      {:ok, segment} =
        Storage.seal_segment(context.store, session_id, context.data_key, %{
          events: events,
          epoch: context.epoch,
          head_hash: "sha256:head"
        })

      # The daemon never held a bucket credential; these bytes went up a presigned URL.
      keyed = ObjectStore.from_env()
      assert {:ok, ciphertext} = ObjectStore.get(keyed, segment.key)
      refute ciphertext =~ "a private thought"
      assert {:error, _} = Cipher.open(:crypto.strong_rand_bytes(32), session_id, ciphertext)

      # And it can read its own back, which is the half that needs the key.
      assert {:ok, ^events} =
               Storage.read_segment(context.store, session_id, context.data_key, segment.key)

      # Listing is the plane's, because a listing cannot be signed per-key.
      assert {:ok, [listed]} = Storage.list_segments(context.store, session_id)
      assert listed.key == segment.key

      assert Process.alive?(sealer)
    end

    test "every seal tells the plane how far the session has got", ctx do
      session_id = unique("p")
      {:ok, sealer, context} = start_private(session_id, ctx)

      send_event(context, sealer, 1)
      send_event(context, sealer, 2)

      assert {:ok, report} = Sealer.seal_now(sealer)
      assert report.sealed_through == 2

      # Upload first, then report: the plane hears about a segment that is already in
      # storage, never the other way round.
      row = FakePlane.row(ctx.plane.state, session_id)
      assert row["kind"] == "private"
      assert row["device"] == "test-laptop"
      assert row["last_seq"] == 2
      assert row["head_hash"] == report.head_hash

      # And the manifest names a person rather than a team, which is what a rebuild reads.
      assert {:ok, manifest} = Storage.get_manifest(context.store, session_id)
      assert manifest["kind"] == "private"
      assert manifest["team"] == nil
      assert manifest["owner_subject"] == "ada@example.test"
      assert manifest["key_path"] == "troupe/people/ada@example.test/sessions/#{session_id}"
    end

    # Issue #433: it was refused and carried on, uploading at its old epoch beside the
    # device that held the session now.
    test "a device that lost the session stops sealing, and uploads nothing more at its epoch",
         ctx do
      session_id = unique("p")
      {:ok, sealer, context} = start_private(session_id, ctx)
      ref = Process.monitor(sealer)

      # Another device takes it. This one is not told: it is holding epoch 1 and the row
      # has moved to 2, and it finds out the next time it tries to say anything.
      taken = FakePlane.steal(ctx.plane.state, session_id)
      assert taken["epoch"] == context.epoch + 1

      # Its next seal goes up and is then reported, which is how it finds out.
      send_event(context, sealer, 1)
      refused = Sealer.seal_now(sealer)

      assert {"session.register", %{"epoch" => 1}} =
               ctx.plane.state |> FakePlane.calls() |> List.last()

      assert {:ok, [sealed]} = Storage.list_segments(context.store, session_id)

      # The session goes on here: a turn writes another event, and the interval comes round.
      send_event(context, sealer, 2)
      send(sealer, :interval)
      settle(sealer)

      # Nothing more went up at the old epoch, on its way down included, and nothing more
      # was reported.
      assert {:ok, [^sealed]} = Storage.list_segments(context.store, session_id)
      assert [_refused] = seal_reports(ctx.plane.state, session_id)
      assert {:error, :stale_version} = refused
      assert_receive {:DOWN, ^ref, :process, ^sealer, {:shutdown, :stale_version}}

      # Not started again, and listed as the other device's until it is claimed back here.
      assert %{active: 0} = DynamicSupervisor.count_children(Private.Sealers)
      assert eventually(fn -> not Private.sealing?(session_id) end)
      assert Private.sync(session_id) == {"elsewhere", nil}

      # The row is unchanged: the loser's report was refused, not merged.
      assert FakePlane.row(ctx.plane.state, session_id)["device"] == "the other one"
    end

    # Decision 755. The key is under the person's name at the key manager, which the plane
    # answers and a re-key (751) leaves alone; the subject a device is linked under is not
    # it once the person has been moved.
    test "another device finds the key a session was sealed with before its owner was moved",
         ctx do
      session_id = unique("p")

      # Ada's laptop seals under her name, which was her subject when she was first known.
      {:ok, _sealer, laptop} = start_private(session_id, ctx, kms_name: "ada@example.test")

      events = [%{"seq" => 1, "type" => "message", "data" => %{"text" => "before the move"}}]

      {:ok, segment} =
        Storage.seal_segment(laptop.store, session_id, laptop.data_key, %{
          events: events,
          epoch: laptop.epoch,
          head_hash: "sha256:head"
        })

      :ok = Private.stop(session_id)

      # The plane moves her to another claim. Her desktop signs in under the new subject,
      # and the plane answers her name as it always was.
      desktop = link_as("ada-oid@example.test", ctx)

      {:ok, _sealer, restored} =
        start_private(session_id, %{ctx | name: desktop}, kms_name: "ada@example.test")

      assert restored.owner_subject == "ada-oid@example.test"
      assert Context.key_path(restored) == "troupe/people/ada@example.test/sessions/#{session_id}"
      assert restored.data_key == laptop.data_key

      assert {:ok, ^events} =
               Storage.read_segment(restored.store, session_id, restored.data_key, segment.key)
    end

    test "claiming bumps the epoch, and a second claim on the old one is refused", ctx do
      session_id = unique("p")
      {:ok, _sealer, _context} = start_private(session_id, ctx)

      assert {:ok, won} = Private.claim(session_id, 1, plane: ctx.name, device: "desktop")
      assert won["epoch"] == 2

      assert {:error, {:rpc, %{"message" => "stale_version"}}} =
               Private.claim(session_id, 1, plane: ctx.name, device: "laptop")
    end
  end

  # Decision 756. The plane destroys an erased session's key and cannot reach this disk;
  # the daemon is told when it connects, drops its sealer and its copy, and says so, and
  # that is when the objects go.
  describe "erasure" do
    setup context do
      requires_services(context)
      start_supervised!(Private.Sealers)
      :ok
    end

    test "a session the plane erased stops sealing here, and its objects go once", ctx do
      session_id = unique("p")
      {:ok, sealer, context} = start_private(session_id, ctx)

      send_event(context, sealer, 1)
      assert {:ok, %{segments: 1}} = Sealer.seal_now(sealer)
      store = ObjectStore.from_env()
      assert {:ok, [_ | _]} = ObjectStore.list_versions(store, "sessions/#{session_id}/")

      FakePlane.erase(ctx.plane.state, session_id)
      test = self()

      erase = fn id ->
        send(test, {:erased_here, id})
        :ok
      end

      assert {:ok, [^session_id]} =
               Private.apply_erasures(plane: ctx.name, device: "test-laptop", erase: erase)

      assert_received {:erased_here, ^session_id}
      refute Process.alive?(sealer)
      refute Private.sealing?(session_id)
      assert {:ok, []} = ObjectStore.list_versions(store, "sessions/#{session_id}/")

      # Told once: the next connection finds nothing to do.
      assert {:ok, []} =
               Private.apply_erasures(plane: ctx.name, device: "test-laptop", erase: erase)

      assert [_once] = acknowledgements(ctx.plane.state, session_id)
    end

    test "nothing is deleted for a session the plane did not erase", ctx do
      session_id = unique("p")
      {:ok, sealer, context} = start_private(session_id, ctx)

      send_event(context, sealer, 1)
      assert {:ok, _} = Sealer.seal_now(sealer)

      assert {:ok, []} = Private.apply_erasures(plane: ctx.name, device: "test-laptop")
      assert Private.sealing?(session_id)
      assert acknowledgements(ctx.plane.state, session_id) == []

      store = ObjectStore.from_env()
      assert {:ok, [_ | _]} = ObjectStore.list_versions(store, "sessions/#{session_id}/")
    end
  end

  # Issue #365. The daemon holds its plane token in memory, so one that restarted seals
  # nothing until a client links it again, and a token that ran out seals nothing until
  # the client hands it the renewed one. Either way the session carries on from where the
  # plane says it got to, at the epoch this device held, and nothing is lost meanwhile.
  describe "carrying on" do
    setup context do
      requires_services(context)
      start_supervised!(Private.Sealers)
      :ok
    end

    test "a session sealing before a restart is sealed again once a client links, from where it got to",
         ctx do
      session_id = unique("p")
      {:ok, sealer, context} = start_private(session_id, ctx)
      send_event(context, sealer, 1)
      assert {:ok, %{sealed_through: 1}} = Sealer.seal_now(sealer)

      # The daemon goes, and the token with it. Its log goes on to the fourth event: what it
      # wrote before it stopped, and what a turn wrote after it came back.
      :ok = Private.stop(session_id)
      restarted = restart_plane()
      log = Enum.map(1..4, &event/1)

      assert {:ok, []} = resume(restarted, [session_id], log)
      refute Private.sealing?(session_id)

      :ok = link(restarted, ctx, "plane-token")
      assert {:ok, [^session_id]} = resume(restarted, [session_id], log)
      assert Private.sealing?(session_id)
      assert {:ok, %{sealed_through: 4}} = Sealer.seal_now(sealer_of(session_id))

      # From the plane's `last_seq`, under its epoch, fenced: the first event is not sealed
      # twice, and the row is this device's still.
      row = FakePlane.row(ctx.plane.state, session_id)
      assert row["last_seq"] == 4
      assert row["epoch"] == context.epoch
      assert row["device"] == "test-laptop"
      assert [made, again] = registrations(ctx.plane.state, session_id)
      refute Map.has_key?(made, "epoch")
      assert again["epoch"] == context.epoch

      assert {:ok, [first, second]} = Storage.list_segments(context.store, session_id)

      assert {:ok, [%{"seq" => 1}]} =
               Storage.read_segment(context.store, session_id, context.data_key, first.key)

      assert {:ok, events} =
               Storage.read_segment(context.store, session_id, context.data_key, second.key)

      assert Enum.map(events, & &1["seq"]) == [2, 3, 4]

      # And a second link with the same token starts nothing twice.
      assert {:ok, []} = resume(restarted, [session_id], log)
    end

    test "a session another device has taken since is left to it", ctx do
      session_id = unique("p")
      {:ok, sealer, context} = start_private(session_id, ctx)
      send_event(context, sealer, 1)
      assert {:ok, _} = Sealer.seal_now(sealer)
      :ok = Private.stop(session_id)

      FakePlane.steal(ctx.plane.state, session_id)

      assert {:ok, []} = resume(ctx.name, [session_id], Enum.map(1..2, &event/1))
      refute Private.sealing?(session_id)
      assert [_made] = registrations(ctx.plane.state, session_id)
      assert FakePlane.row(ctx.plane.state, session_id)["device"] == "the other one"
    end

    # D61: what `session.claim` does with one. This copy holds the event the row's
    # `last_seq` names, so what is sealed here follows on from it, past the other's epoch.
    test "a session another device took is sealed here once claimed, from where the plane has it",
         ctx do
      session_id = unique("p")
      {:ok, sealer, context} = start_private(session_id, ctx)
      send_event(context, sealer, 1)
      send_event(context, sealer, 2)
      assert {:ok, %{sealed_through: 2}} = Sealer.seal_now(sealer)
      :ok = Private.stop(session_id)

      FakePlane.steal(ctx.plane.state, session_id)
      log = Enum.map(1..4, &event/1)
      assert {:ok, []} = resume(ctx.name, [session_id], log)
      assert Private.sync(session_id) == {"elsewhere", "the other one"}

      assert {:ok, %{"epoch" => 3, "device" => "test-laptop"}} =
               take_over(ctx.name, session_id, log)

      assert Private.sealing?(session_id)
      assert {:ok, %{sealed_through: 4, pending: 0}} = Sealer.seal_now(sealer_of(session_id))
      assert Private.sync(session_id) == {"current", nil}

      row = FakePlane.row(ctx.plane.state, session_id)
      assert row["last_seq"] == 4
      assert row["epoch"] == 3
      assert {:ok, [_first, second]} = Storage.list_segments(context.store, session_id)

      assert {:ok, events} =
               Storage.read_segment(context.store, session_id, context.data_key, second.key)

      assert Enum.map(events, & &1["seq"]) == [3, 4]

      # Claiming again, with the row this device's, starts nothing twice.
      assert {:ok, %{"epoch" => 3}} = take_over(ctx.name, session_id, log)
    end

    # Sealing this copy after events it does not hold would make the session two histories.
    test "a claim is refused where the plane has events this copy does not", ctx do
      session_id = unique("p")
      {:ok, sealer, context} = start_private(session_id, ctx)
      send_event(context, sealer, 1)
      assert {:ok, _} = Sealer.seal_now(sealer)
      :ok = Private.stop(session_id)

      # The other device carried it on to a third event this copy never had.
      taken = FakePlane.steal(ctx.plane.state, session_id)

      FakePlane.put(
        ctx.plane.state,
        session_id,
        Map.merge(taken, %{"last_seq" => 3, "head_hash" => "sha256:another"})
      )

      assert {:error, :diverged} = take_over(ctx.name, session_id, Enum.map(1..2, &event/1))
      assert {:error, :diverged} = take_over(ctx.name, session_id, Enum.map(1..3, &event/1))
      refute Private.sealing?(session_id)
      assert %{"device" => "the other one", "epoch" => 2} = FakePlane.row(ctx.plane.state, session_id)
    end

    test "a session made while nobody had linked is registered, and sealed from its first event",
         ctx do
      session_id = unique("p")
      assert FakePlane.row(ctx.plane.state, session_id) == nil

      assert {:ok, [^session_id]} = resume(ctx.name, [session_id], Enum.map(1..3, &event/1))
      sealer = sealer_of(session_id)
      assert {:ok, %{sealed_through: 3, segments: 1}} = Sealer.seal_now(sealer)

      row = FakePlane.row(ctx.plane.state, session_id)
      assert row["last_seq"] == 3
      assert row["device"] == "test-laptop"

      # An event the log gave it, delivered again as a subscription that raced the read
      # would, and one after it: only the new one is sealed.
      send(sealer, {:troupe_event, session_id, event(2)})
      send(sealer, {:troupe_event, session_id, event(4)})
      assert {:ok, %{sealed_through: 4, segments: 2}} = Sealer.seal_now(sealer)
    end

    test "a renewed token is the one it carries on with, and what waited for it is sealed", ctx do
      session_id = unique("p")
      {:ok, sealer, context} = start_private(session_id, ctx)
      send_event(context, sealer, 1)
      assert {:ok, %{sealed_through: 1}} = Sealer.seal_now(sealer)

      # The token the daemon holds runs out: nothing is sealed, and nothing is dropped.
      FakePlane.renew(ctx.plane.state, "plane-token-2")
      send_event(context, sealer, 2)
      assert {:ok, %{sealed_through: 1, pending: 1}} = Sealer.seal_now(sealer)

      # The client renews it and links again.
      :ok = link(ctx.name, ctx, "plane-token-2")
      assert {:ok, %{sealed_through: 2, pending: 0}} = Sealer.seal_now(sealer)
      assert FakePlane.row(ctx.plane.state, session_id)["last_seq"] == 2
    end

    # Issue #381. Signing out leaves the daemon as a restart does: no token, no sealer, the
    # log on this disk, and the next sign-in carrying the session on from where it got to.
    test "a session sealing when the person signs out stops, and carries on at the next sign-in",
         ctx do
      session_id = unique("p")
      {:ok, sealer, context} = start_private(session_id, ctx)
      send_event(context, sealer, 1)
      assert {:ok, %{sealed_through: 1}} = Sealer.seal_now(sealer)

      # A turn is under way: its first event is in the log and not sealed yet.
      send_event(context, sealer, 2)
      asked = length(FakePlane.calls(ctx.plane.state))

      assert Plane.sign_out(ctx.plane.url, "ada@example.test", ctx.name)
      assert [^session_id] = Private.suspend()
      refute Process.alive?(sealer)
      refute Private.sealing?(session_id)

      # Nothing more reached the plane, the last seal on the way down included, and a
      # session made now is not registered.
      assert {:error, :unlinked} = start_private(unique("p"), ctx)
      assert length(FakePlane.calls(ctx.plane.state)) == asked
      assert FakePlane.row(ctx.plane.state, session_id)["last_seq"] == 1

      # The person signs in again and the client links with a token: what the log holds
      # after the first event is sealed, the turn's and one written while signed out.
      :ok = link(ctx.name, ctx, "plane-token")
      log = Enum.map(1..3, &event/1)
      assert {:ok, [^session_id]} = resume(ctx.name, [session_id], log)
      assert {:ok, %{sealed_through: 3}} = Sealer.seal_now(sealer_of(session_id))

      row = FakePlane.row(ctx.plane.state, session_id)
      assert row["last_seq"] == 3
      assert row["epoch"] == context.epoch
      assert {:ok, [_first, second]} = Storage.list_segments(context.store, session_id)

      assert {:ok, events} =
               Storage.read_segment(context.store, session_id, context.data_key, second.key)

      assert Enum.map(events, & &1["seq"]) == [2, 3]
    end
  end

  describe "without a plane" do
    test "a session that cannot be registered is refused, and nothing is lost", ctx do
      :ok = Plane.unlink(ctx.name)

      assert {:error, :unlinked} =
               Private.start(unique("p"), plane: ctx.name, key_manager: &fake_key_manager/2)
    end
  end

  describe "through the daemon" do
    setup do
      base = Path.join(System.tmp_dir!(), "troupe-priv-#{System.unique_integer([:positive])}")
      workspace = Path.join(base, "workspace")
      state_dir = Path.join(base, "state")
      File.mkdir_p!(workspace)
      File.mkdir_p!(state_dir)

      previous = System.get_env("TROUPE_STATE_HOME")
      System.put_env("TROUPE_STATE_HOME", state_dir)

      endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
      start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

      on_exit(fn ->
        if previous,
          do: System.put_env("TROUPE_STATE_HOME", previous),
          else: System.delete_env("TROUPE_STATE_HOME")

        File.rm_rf!(base)
      end)

      %{workspace: workspace, state_dir: state_dir, endpoint: endpoint}
    end

    test "a daemon nobody has linked creates the session and says it is not syncing", ctx do
      {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: ctx.endpoint, spawn: false)
      on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

      assert {:ok, created} =
               Client.call(client, "session.create", %{
                 "command_id" => Client.command_id(),
                 "workspace" => ctx.workspace,
                 "private" => true,
                 "config" => %{"auto_approve" => true}
               })

      on_exit(fn -> Troupe.stop_session(created["session_id"]) end)

      # The session exists and runs. `syncing` is what it is *actually* doing, not what
      # was asked for: refusing to work without a network is the coupling a private
      # session exists to avoid, so an unlinked daemon makes a local one and says so.
      assert created["syncing"] == false
      refute Private.sealing?(created["session_id"])

      # And the log says what kind it is, which is what a rebuild and a second device read.
      events = Log.read_session(created["session_id"], ctx.state_dir)
      created_event = Enum.find(events, &(&1.type == "session_created"))
      assert created_event.data["kind"] == "private"
    end

    # Decision 756: linking is the daemon connecting to its plane, and when it is told.
    test "a link is when an erased session's copy here goes, and the plane is told", ctx do
      requires_services(ctx)
      {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: ctx.endpoint, spawn: false)
      on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

      # Made while nobody had linked, so it is on this disk and nowhere else yet.
      assert {:ok, %{"session_id" => id}} =
               Client.call(client, "session.create", %{
                 "command_id" => Client.command_id(),
                 "workspace" => ctx.workspace,
                 "private" => true,
                 "config" => %{"auto_approve" => true}
               })

      on_exit(fn -> Troupe.stop_session(id) end)
      assert Troupe.get_session(id)

      # What another of its devices sealed, before somebody erased it from elsewhere.
      store = ObjectStore.from_env()
      {:ok, _} = ObjectStore.put(store, "sessions/#{id}/manifest.json", "{}")
      FakePlane.erase(ctx.plane.state, id)

      link = %{
        "subject" => "ada@example.test",
        "plane_url" => ctx.plane.url,
        "plane_token" => "plane-token"
      }

      assert {:ok, _identity} = Client.call(client, "identity.link", link)

      assert eventually(fn -> acknowledgements(ctx.plane.state, id) != [] end)
      assert Troupe.get_session(id) == nil
      assert {:ok, []} = ObjectStore.list_versions(store, "sessions/#{id}/")

      # A second link asks again and has nothing to do.
      asked = length(asked_for_erasures(ctx.plane.state))
      assert {:ok, _identity} = Client.call(client, "identity.link", link)
      assert eventually(fn -> length(asked_for_erasures(ctx.plane.state)) > asked end)
      assert [_once] = acknowledgements(ctx.plane.state, id)
    end

    # Issue #365: a link that carries a token is also when the daemon carries on with the
    # private sessions it could not seal, here one it made while nobody had linked. The
    # token is in no file. This fake plane signs no assertion, so the key and the sealing
    # after the registration are the "carrying on" tests', with the exchange stood in for.
    test "a link with a token registers a private session made while nobody had linked", ctx do
      {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: ctx.endpoint, spawn: false)
      on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

      assert {:ok, %{"session_id" => id, "syncing" => false}} =
               Client.call(client, "session.create", %{
                 "command_id" => Client.command_id(),
                 "workspace" => ctx.workspace,
                 "private" => true,
                 "config" => %{"auto_approve" => true}
               })

      on_exit(fn -> Troupe.stop_session(id) end)
      assert FakePlane.row(ctx.plane.state, id) == nil

      link = %{
        "subject" => "ada@example.test",
        "plane_url" => ctx.plane.url,
        "plane_token" => "plane-token"
      }

      assert {:ok, identity} = Client.call(client, "identity.link", link)
      refute inspect(identity) =~ "plane-token"

      assert eventually(fn -> FakePlane.row(ctx.plane.state, id) != nil end)
      assert FakePlane.row(ctx.plane.state, id)["kind"] == "private"
      refute File.read!(Troupe.Identity.path(ctx.state_dir)) =~ "plane-token"
    end

    # Issue #381: `identity.sign_out`, which `troupe logout` and the desktop app's sign-out
    # send. The token goes and the sealing with it, where they are that person's at that
    # plane; the label stays.
    test "signing out takes back the person's token and stops sealing, and keeps the label",
         ctx do
      requires_services(ctx)
      {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: ctx.endpoint, spawn: false)
      on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

      link = %{
        "subject" => "ada@example.test",
        "plane_url" => ctx.plane.url,
        "plane_token" => "plane-token"
      }

      assert {:ok, _identity} = Client.call(client, "identity.link", link)

      # A private session sealing here, its key from the stand-in the other tests use.
      session_id = unique("p")

      {:ok, sealer, _context} =
        Private.start(session_id,
          device: "test-laptop",
          subscribe: fn _id -> :ok end,
          key_manager: &fake_key_manager/2
        )

      on_exit(fn -> stop(sealer) end)

      # Somebody else signing out, or signing out of another plane, takes nothing.
      for {url, subject} <- [
            {ctx.plane.url, "bob@example.test"},
            {"https://elsewhere.example.test", "ada@example.test"}
          ] do
        assert {:ok, %{"signed_out" => false}} = sign_out(client, url, subject)
      end

      assert Plane.linked?()
      assert Private.sealing?(session_id)

      assert {:ok, %{"signed_out" => true}} = sign_out(client, ctx.plane.url, "ada@example.test")
      refute Plane.linked?()
      refute Private.sealing?(session_id)
      refute Process.alive?(sealer)

      assert {:ok, %{"linked" => true, "subject" => "ada@example.test"}} =
               Client.call(client, "identity.get", %{})

      assert {:error, %{message: "invalid_params"}} =
               Client.call(client, "identity.sign_out", %{"command_id" => Client.command_id()})
    end

    # D61: a client lists what `session.list` says, and it said nothing of a session being
    # private, so the desktop app listed one as local.
    test "session.list says a private session is private, and how its sealing stands", ctx do
      {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: ctx.endpoint, spawn: false)
      on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

      private = create(client, ctx, private: true)
      local = create(client, ctx)

      # Nobody has handed the daemon a token, so nothing is sealing it: it carries on at the
      # next link with one.
      assert %{"kind" => "private", "sync" => "paused", "device" => nil} = listed(client, private)
      assert %{"kind" => "local", "sync" => nil} = listed(client, local)

      assert {:ok, %{"kind" => "private", "sync" => "paused"}} =
               Client.call(client, "session.get", %{"session_id" => private})
    end

    # D61 and Decision 764: one another device sealed last is left to it until it is claimed
    # here, which a machine whose name changed needs as well.
    test "a private session another device sealed last is listed so, and claiming it takes it here",
         ctx do
      {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: ctx.endpoint, spawn: false)
      on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

      id = create(client, ctx, private: true)
      FakePlane.put(ctx.plane.state, id, %{"device" => "the other one", "epoch" => 1})

      assert {:ok, _identity} = Client.call(client, "identity.link", link_params(ctx))
      assert eventually(fn -> listed(client, id)["sync"] == "elsewhere" end)
      assert %{"kind" => "private", "device" => "the other one"} = listed(client, id)

      claim = %{"command_id" => Client.command_id(), "session_id" => id}
      assert {:ok, claimed} = Client.call(client, "session.claim", claim)

      # The row names this device now, one epoch on; the other device learns it lost when it
      # next seals. This plane signs no assertion, so sealing here waits for one.
      row = FakePlane.row(ctx.plane.state, id)
      assert row["epoch"] == 2
      assert row["device"] == claimed["device"]
      refute row["device"] == "the other one"
      assert %{"session_id" => ^id, "epoch" => 2, "sync" => "paused"} = claimed
      assert %{"sync" => "paused", "device" => nil} = listed(client, id)

      # The same command again is the same answer, and a second claim takes nothing more.
      assert {:ok, ^claimed} = Client.call(client, "session.claim", claim)

      assert {:ok, %{"epoch" => 2}} =
               Client.call(client, "session.claim", %{claim | "command_id" => Client.command_id()})

      assert FakePlane.row(ctx.plane.state, id)["epoch"] == 2

      # A local session has nothing to claim.
      local = create(client, ctx)

      assert {:error, %{message: "invalid_params"}} =
               Client.call(client, "session.claim", %{claim | "command_id" => Client.command_id(), "session_id" => local})
    end

    # D59: the state Decision 756 added, as a client lists it.
    test "a private session waiting to be erased is listed so, and is not claimed", ctx do
      {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: ctx.endpoint, spawn: false)
      on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

      id = create(client, ctx, private: true)
      FakePlane.pend_erasure(ctx.plane.state, id)

      assert {:ok, _identity} = Client.call(client, "identity.link", link_params(ctx))
      assert eventually(fn -> listed(client, id)["sync"] == "erasure_pending" end)

      assert {:error, %{message: "not_found", data: %{"reason" => "erased"}}} =
               Client.call(client, "session.claim", %{
                 "command_id" => Client.command_id(),
                 "session_id" => id
               })

      assert FakePlane.row(ctx.plane.state, id)["state"] == "erasure_pending"
    end

    # Issue #432: `session.erase` of a private session erased this copy and nothing else,
    # leaving its sealer running and the sealed copy at the plane under a live key.
    test "erasing a private session here erases it at the plane, stops its sealer, and its objects go",
         ctx do
      requires_services(ctx)
      {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: ctx.endpoint, spawn: false)
      on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

      assert {:ok, _identity} = Client.call(client, "identity.link", link_params(ctx))
      id = create(client, ctx, private: true)
      sealer = seal_here(id, ctx)
      ref = Process.monitor(sealer)
      store = ObjectStore.from_env()
      assert {:ok, [_ | _]} = ObjectStore.list_versions(store, "sessions/#{id}/")

      assert {:ok, %{"session_id" => ^id, "erased" => true, "state" => "erased"}} =
               erase(client, id)

      # The sealer first, the key at the plane, this copy, and the objects once the plane
      # was told this device had stopped.
      assert_receive {:DOWN, ^ref, :process, ^sealer, _reason}
      refute Private.sealing?(id)
      assert FakePlane.row(ctx.plane.state, id)["state"] == "erased"
      assert [_once] = acknowledgements(ctx.plane.state, id)
      assert {:ok, []} = ObjectStore.list_versions(store, "sessions/#{id}/")
      assert Troupe.get_session(id) == nil
      assert listed(client, id) == nil

      # The next link has nothing left to do.
      asked = length(asked_for_erasures(ctx.plane.state))
      assert {:ok, _identity} = Client.call(client, "identity.link", link_params(ctx))
      assert eventually(fn -> length(asked_for_erasures(ctx.plane.state)) > asked end)
      assert [_once] = acknowledgements(ctx.plane.state, id)
    end

    # Decision 756's `erasure_pending`, reached from here: the key goes first, and this copy
    # after it, as an erasure started at the plane has it.
    test "a private session whose key the plane has not destroyed is listed waiting to be erased, until it has",
         ctx do
      requires_services(ctx)
      {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: ctx.endpoint, spawn: false)
      on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

      assert {:ok, _identity} = Client.call(client, "identity.link", link_params(ctx))
      id = create(client, ctx, private: true)
      sealer = seal_here(id, ctx)
      ref = Process.monitor(sealer)
      store = ObjectStore.from_env()

      FakePlane.refuse_keys(ctx.plane.state, true)

      assert {:ok, %{"session_id" => ^id, "erased" => false, "state" => "erasure_pending"}} =
               erase(client, id)

      assert_receive {:DOWN, ^ref, :process, ^sealer, _reason}
      assert FakePlane.row(ctx.plane.state, id)["state"] == "erasure_pending"
      assert %{"kind" => "private", "sync" => "erasure_pending"} = listed(client, id)
      assert {:ok, [_ | _]} = ObjectStore.list_versions(store, "sessions/#{id}/")
      assert acknowledgements(ctx.plane.state, id) == []

      # Erasing again tries again.
      assert {:ok, %{"erased" => false, "state" => "erasure_pending"}} = erase(client, id)

      # The key manager is back, and the next link finishes it: this copy, and the objects.
      FakePlane.refuse_keys(ctx.plane.state, false)
      assert {:ok, _identity} = Client.call(client, "identity.link", link_params(ctx))
      assert eventually(fn -> acknowledgements(ctx.plane.state, id) != [] end)
      assert FakePlane.row(ctx.plane.state, id)["state"] == "erased"
      assert {:ok, []} = ObjectStore.list_versions(store, "sessions/#{id}/")
      assert listed(client, id) == nil
    end

    test "a daemon with no plane token erases nothing of a private session, and says where it is sealed",
         ctx do
      requires_services(ctx)
      {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: ctx.endpoint, spawn: false)
      on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

      assert {:ok, _identity} = Client.call(client, "identity.link", link_params(ctx))
      id = create(client, ctx, private: true)
      store = ObjectStore.from_env()
      {:ok, _} = ObjectStore.put(store, "sessions/#{id}/manifest.json", "{}")

      # The person signed out: the token went, and the label stayed.
      assert {:ok, %{"signed_out" => true}} = sign_out(client, ctx.plane.url, "ada@example.test")
      plane_url = ctx.plane.url

      assert {:error,
              %{
                message: "unavailable",
                data: %{"session_id" => ^id, "reason" => "unlinked", "plane_url" => ^plane_url}
              }} = erase(client, id)

      # Nothing went: this copy, the row and the objects are as they were.
      assert %{"kind" => "private"} = listed(client, id)
      refute Enum.any?(FakePlane.calls(ctx.plane.state), &match?({"session.erase", _}, &1))
      refute FakePlane.row(ctx.plane.state, id)["state"]
      assert {:ok, [_]} = ObjectStore.list_versions(store, "sessions/#{id}/")
    end

    test "a local session has no sealer, and stopping one is a no-op", ctx do
      {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: ctx.endpoint, spawn: false)
      on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

      assert {:ok, created} =
               Client.call(client, "session.create", %{
                 "command_id" => Client.command_id(),
                 "workspace" => ctx.workspace,
                 "config" => %{"auto_approve" => true}
               })

      assert created["syncing"] == false
      assert :ok = Private.stop(created["session_id"])

      assert {:ok, %{"state" => "dormant"}} =
               Client.call(client, "session.archive", %{
                 "command_id" => Client.command_id(),
                 "session_id" => created["session_id"]
               })
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp services do
    store = ObjectStore.from_env()

    cond do
      not match?({:ok, _}, ObjectStore.list(store, "reachability-probe/")) ->
        {:error, "no object storage (#{store.endpoint})"}

      not bao_reachable?() ->
        {:error, "no OpenBao (#{bao_address()})"}

      true ->
        :ok
    end
  end

  defp bao_reachable? do
    match?(
      {:ok, %{status: 200}},
      Req.request(method: :get, url: bao_address() <> "/v1/sys/health", retry: false)
    )
  rescue
    _ -> false
  end

  defp bao_address do
    Application.get_env(:troupe_worker, :kms, [])[:address] || "http://localhost:28200"
  end

  defp requires_services(%{services: :up}), do: :ok

  defp requires_services(_),
    do: flunk("no object storage or OpenBao; see the message from setup_all")

  defp start_private(session_id, ctx, opts \\ []) do
    result =
      Private.start(session_id,
        plane: ctx.name,
        device: "test-laptop",
        subscribe: fn _id -> :ok end,
        key_manager: fn plane, id -> fake_key_manager(plane, id, opts[:kms_name]) end
      )

    case result do
      {:ok, sealer, context} ->
        on_exit(fn -> stop(sealer) end)
        {:ok, sealer, context}

      other ->
        other
    end
  end

  defp stop(sealer) do
    if Process.alive?(sealer), do: Process.exit(sealer, :normal)
  end

  # What the real exchange answers, without the signature. Minting an assertion is the
  # plane's job and is proven in the plane's own suite; what this test is about is what
  # the daemon does with the token afterwards. `name` is the person's name at the key
  # manager as the plane answers it; a plane from before Decision 755 answers none.
  defp fake_key_manager(_plane, _session_id, name \\ nil) do
    kms = Application.get_env(:troupe_worker, :kms, [])
    token = System.get_env("TROUPE_BAO_TOKEN") || kms[:token]
    {:ok, if(name, do: [token: token, name: name], else: [token: token])}
  end

  # A second device of the same person, signed in under `subject`, on the same plane.
  defp link_as(subject, ctx) do
    name = :"plane-#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({Plane, name: name}, id: name))

    :ok =
      Plane.link(
        %{"subject" => subject, "plane_url" => ctx.plane.url, "plane_token" => "plane-token"},
        name
      )

    name
  end

  # The daemon after a restart: a plane process nobody has linked.
  defp restart_plane do
    name = :"plane-#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({Plane, name: name}, id: name))
    name
  end

  defp link(plane, ctx, token) do
    Plane.link(
      %{"subject" => "ada@example.test", "plane_url" => ctx.plane.url, "plane_token" => token},
      plane
    )
  end

  # A session made through the daemon, stopped when the test ends.
  defp create(client, ctx, opts \\ []) do
    params =
      %{
        "command_id" => Client.command_id(),
        "workspace" => ctx.workspace,
        "config" => %{"auto_approve" => true}
      }
      |> then(&if(opts[:private], do: Map.put(&1, "private", true), else: &1))

    assert {:ok, %{"session_id" => id}} = Client.call(client, "session.create", params)
    on_exit(fn -> Troupe.stop_session(id) end)
    id
  end

  # The session's row as the daemon's `session.list` says it.
  defp listed(client, session_id) do
    {:ok, %{"sessions" => sessions}} = Client.call(client, "session.list", %{})
    Enum.find(sessions, &(&1["id"] == session_id))
  end

  defp link_params(ctx) do
    %{
      "command_id" => Client.command_id(),
      "subject" => "ada@example.test",
      "plane_url" => ctx.plane.url,
      "plane_token" => "plane-token"
    }
  end

  defp erase(client, session_id) do
    Client.call(client, "session.erase", %{
      "command_id" => Client.command_id(),
      "session_id" => session_id
    })
  end

  # A sealer for a private session the daemon made, its key from the stand-in the other
  # tests use (this plane signs no assertion), with what the session's log holds sealed.
  defp seal_here(session_id, ctx) do
    {:ok, sealer, _context} =
      Private.start(session_id, workspace: ctx.workspace, key_manager: &fake_key_manager/2)

    on_exit(fn -> stop(sealer) end)
    assert {:ok, %{sealed_through: sealed}} = Sealer.seal_now(sealer)
    assert sealed > 0
    sealer
  end

  defp sign_out(client, plane_url, subject) do
    Client.call(client, "identity.sign_out", %{
      "command_id" => Client.command_id(),
      "plane_url" => plane_url,
      "subject" => subject
    })
  end

  # `Private.resume/1` over these sessions, with `log` as what this disk holds of each.
  defp resume(plane, session_ids, log) do
    Private.resume(
      plane: plane,
      device: "test-laptop",
      subscribe: fn _id -> :ok end,
      key_manager: fn p, id -> fake_key_manager(p, id) end,
      sessions: Enum.map(session_ids, &%{id: &1, workspace: nil}),
      backfill: fn _id, after_seq -> Enum.filter(log, &(&1.seq > after_seq)) end
    )
  end

  # `Private.take_over/2`, what `session.claim` does, with `log` as what this disk holds.
  defp take_over(plane, session_id, log) do
    Private.take_over(%{id: session_id, workspace: nil},
      plane: plane,
      device: "test-laptop",
      subscribe: fn _id -> :ok end,
      key_manager: fn p, id -> fake_key_manager(p, id) end,
      backfill: fn _id, after_seq -> Enum.filter(log, &(&1.seq > after_seq)) end
    )
  end

  defp sealer_of(session_id), do: Registry.whereis_name({Private.Registry, session_id})

  # A registration, rather than the progress report every seal makes on the same method.
  defp registrations(state, session_id) do
    for {"session.register", %{"session_id" => ^session_id} = params} <- FakePlane.calls(state),
        not Map.has_key?(params, "last_seq"),
        do: params
  end

  # And the progress reports.
  defp seal_reports(state, session_id) do
    for {"session.register", %{"session_id" => ^session_id, "last_seq" => _} = params} <-
          FakePlane.calls(state),
        do: params
  end

  # Once the sealer has handled what was sent to it before this, or has gone.
  defp settle(sealer) do
    _ = :sys.get_state(sealer)
    :ok
  catch
    :exit, _gone -> :ok
  end

  defp event(seq), do: %Event{seq: seq, type: "message", agent: ["root"], data: %{"n" => seq}}

  defp acknowledgements(state, session_id) do
    for {"session.erased", %{"session_id" => ^session_id} = params} <- FakePlane.calls(state),
        do: params
  end

  defp asked_for_erasures(state) do
    for {"session.erasures", params} <- FakePlane.calls(state), do: params
  end

  # The link answers before the daemon has asked; what it does next is a task of its own.
  defp eventually(check, deadline \\ 5_000) do
    cond do
      check.() ->
        true

      deadline <= 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(check, deadline - 50)
    end
  end

  # The Sealer subscribes; here nothing publishes, so the events are handed to it
  # directly. `agent_done` on the root is a turn ending, which is the sealer's own cue.
  defp send_event(context, sealer, seq) do
    event = %Event{seq: seq, type: "message", agent: ["root"], data: %{"n" => seq}}
    send(sealer, {:troupe_event, context.session_id, event})
  end

  # Unique between runs as well as within one. These become object keys, and an object store
  # is not a database: nothing rolls back at the end of a test, so a second run that picked
  # the same id would list what the first one wrote. That is what failed on CI \u2014 one test
  # here asserts a session has exactly one segment, and it had one of its own plus one from
  # a run half an hour earlier.
  defp unique(prefix) do
    "#{prefix}-#{System.os_time(:millisecond)}-#{System.unique_integer([:positive])}"
  end
end
