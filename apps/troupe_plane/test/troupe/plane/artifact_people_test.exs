defmodule Troupe.Plane.ArtifactPeopleTest do
  @moduledoc """
  An artifact shared with picked people, each at a role, and its thread of comments (#62).

  `artifact.share` with `person` shares it with that person by name, at `view`, `comment`
  or `edit`, no link made; they find it under *Shared with you* (`scope: shared`), and the
  role is enforced on every get and put. `artifact.unshare` with `person` takes it back.
  `artifact.comments` is the thread for whoever may open it; `artifact.comment` writes in it
  for whoever holds `comment` or above, audited without the text, and the session the
  artifact came from hears it where that session runs on a pod. Through `Harness`, as
  `/rpc` reaches them.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.ObjectStore
  alias Troupe.Plane.{Admin, Artifacts, Audit, FakePod, Fleet, Harness, Identity, Repo, Sessions}
  alias Troupe.Plane.Artifacts.{Artifact, Comment}
  alias Troupe.Plane.Control.{Connections, Listener}

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:troupe_plane, :artifacts, url: "https://artifacts.example.test")

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :artifacts)
      ObjectStore.delete_prefix(ObjectStore.from_env(), "artifacts/")
    end)

    _engineering = team_with_grant("engineering", "dev", name: "engineering")
    _research = team_with_grant("research", "lab", name: "research")

    ada = person("ada@example.test", ["engineering"])

    {:ok, page} =
      call(ada, "artifact.publish", %{
        "title" => "Plan",
        "kind" => "html",
        "files" => [%{"path" => "index.html", "bytes" => Base.encode64("<h1>Plan</h1>")}]
      })

    %{
      ada: ada,
      bo: person("bo@example.test", ["engineering"]),
      cy: person("cy@example.test", ["research"]),
      di: person("di@example.test", ["research"]),
      page: page
    }
  end

  defp as(user), do: %{user: user, platform_admin?: Admin.actor_for(user).role == :platform_admin}
  defp call(user, method, params), do: Harness.call(method, params, as(user))

  defp share_with(context, person, role),
    do: call(context.ada, "artifact.share", %{"id" => context.page["id"], "person" => person.subject, "role" => role})

  defp put(user, id, body),
    do:
      call(user, "artifact.put", %{
        "id" => id,
        "files" => [%{"path" => "index.html", "bytes" => Base.encode64(body)}]
      })

  defp comment(user, id, body), do: call(user, "artifact.comment", %{"id" => id, "body" => body})

  describe "a person picked by name" do
    test "at view finds it under Shared with you and opens it, and nobody else does", context do
      id = context.page["id"]

      # Private: nobody but Ada, before she picks anybody.
      assert {:error, %{message: "not_found"}} = call(context.cy, "artifact.get", %{"id" => id})

      assert {:ok, %{"id" => ^id, "person" => person}} = share_with(context, context.cy, "view")
      assert person["subject"] == context.cy.subject
      assert person["display_name"] == context.cy.display_name
      assert person["role"] == "view"

      assert {:ok, %{"artifacts" => [row]}} = call(context.cy, "artifact.list", %{"shared" => true})
      assert row["id"] == id
      assert row["scope"] == "shared"
      assert row["role"] == "view"
      refute row["may_edit"]
      refute row["may_comment"]

      assert {:ok, %{"role" => "view"}} = call(context.cy, "artifact.get", %{"id" => id})
      assert {:ok, %{"url" => _ticket}} = call(context.cy, "artifact.open", %{"id" => id})
      assert {:ok, _file} = Artifacts.fetch(id, :current, nil, context.cy)

      # Di was picked by nobody: nothing on either host.
      assert {:error, %{message: "not_found"}} = call(context.di, "artifact.get", %{"id" => id})
      assert {:ok, %{"artifacts" => []}} = call(context.di, "artifact.list", %{})
      assert {:error, :not_found} = Artifacts.fetch(id, :current, nil, context.di)

      # A viewer may not put, comment, share or delete.
      assert {:error, %{message: "forbidden"}} = put(context.cy, id, "<h1>Cy</h1>")
      assert {:error, %{message: "forbidden"}} = comment(context.cy, id, "Looks good")

      assert {:error, %{message: "forbidden"}} =
               call(context.cy, "artifact.share", %{"id" => id, "person" => context.di.subject, "role" => "view"})

      assert {:error, %{message: "forbidden"}} = call(context.cy, "artifact.delete", %{"id" => id})
    end

    test "at comment writes in its thread and may not put; at edit puts and comments, and nothing an owner does",
         context do
      id = context.page["id"]
      {:ok, _} = share_with(context, context.cy, "comment")
      {:ok, _} = share_with(context, context.di, "edit")

      assert {:ok, %{"role" => "comment", "may_comment" => true, "may_edit" => false}} =
               call(context.cy, "artifact.get", %{"id" => id})

      assert {:ok, %{"comment" => _}} = comment(context.cy, id, "The second table is wrong.")
      assert {:error, %{message: "forbidden"}} = put(context.cy, id, "<h1>Cy</h1>")

      assert {:ok, %{"version" => 2}} = put(context.di, id, "<h1>Di's</h1>")
      assert {:ok, %{"comment" => _}} = comment(context.di, id, "Fixed it.")

      assert {:ok, %{"role" => "edit", "may_edit" => true, "may_delete" => false}} =
               call(context.di, "artifact.get", %{"id" => id})

      assert {:error, %{message: "forbidden"}} = call(context.di, "artifact.pin", %{"id" => id, "version" => 1})
      assert {:error, %{message: "forbidden"}} = call(context.di, "artifact.delete", %{"id" => id})

      assert {:error, %{message: "forbidden"}} =
               call(context.di, "artifact.put", %{"id" => id, "base" => 2, "visibility" => "organisation"})
    end

    test "is listed for the owner, named again at another role, taken back, and each audited", context do
      id = context.page["id"]
      {:ok, _} = share_with(context, context.cy, "view")
      {:ok, _} = share_with(context, context.cy, "edit")

      assert {:ok, %{"people" => [person]}} = call(context.ada, "artifact.get", %{"id" => id})
      assert %{"subject" => "cy@example.test", "role" => "edit", "granted_by" => "ada@example.test"} = person

      # Only an owner reads who it is shared with.
      refute Map.has_key?(elem(call(context.cy, "artifact.get", %{"id" => id}), 1), "people")

      assert {:ok, %{"revoked" => true}} =
               call(context.ada, "artifact.unshare", %{"id" => id, "person" => context.cy.subject})

      assert {:error, %{message: "not_found"}} = call(context.cy, "artifact.get", %{"id" => id})
      assert {:ok, %{"people" => []}} = call(context.ada, "artifact.get", %{"id" => id})

      shares = Enum.filter(Audit.list(), &(&1.action == "artifact.share" and &1.subject_id == id))
      assert Enum.map(shares, & &1.detail["role"]) |> Enum.sort() == ["edit", "view"]
      assert Enum.all?(shares, &(&1.detail["person"] == "cy@example.test"))
      assert Enum.any?(Audit.list(), &(&1.action == "artifact.unshare" and &1.detail["person"] == "cy@example.test"))
    end

    test "is refused for nobody, for the owner, for a role that is not one, and to anybody but an owner", context do
      id = context.page["id"]

      assert {:error, %{message: "not_found"}} =
               call(context.ada, "artifact.share", %{"id" => id, "person" => "nobody@example.test", "role" => "view"})

      assert {:error, %{message: "invalid_params"}} = share_with(context, context.ada, "view")
      assert {:error, %{message: "invalid_params", data: %{reason: reason}}} = share_with(context, context.cy, "owner")
      assert reason =~ "view, comment or edit"

      assert {:error, %{message: "not_found"}} =
               call(context.bo, "artifact.share", %{"id" => id, "person" => context.cy.subject, "role" => "view"})
    end

    test "keeps the stronger of a link's role and the owner's naming", context do
      id = context.page["id"]
      {:ok, %{"token" => token}} = call(context.ada, "artifact.share", %{"id" => id, "role" => "edit"})
      {:ok, _} = call(context.cy, "artifact.redeem", %{"token" => token})
      {:ok, _} = share_with(context, context.cy, "view")

      assert {:ok, %{"role" => "edit"}} = call(context.cy, "artifact.get", %{"id" => id})

      # Taking the person back ends both ways they held it.
      {:ok, _} = call(context.ada, "artifact.unshare", %{"id" => id, "person" => context.cy.subject})
      assert {:error, %{message: "not_found"}} = call(context.cy, "artifact.get", %{"id" => id})
    end
  end

  describe "the thread" do
    test "is read by whoever may open it, oldest first with names, and written only by a role that comments",
         context do
      {:ok, org} =
        call(context.ada, "artifact.publish", %{
          "title" => "Roadmap",
          "kind" => "markdown",
          "visibility" => "organisation",
          "files" => [%{"path" => "index.md", "bytes" => Base.encode64("# Roadmap")}]
        })

      id = org["id"]

      {:ok, _} =
        Identity.upsert_user(%{subject: "ada@example.test", email: "ada@example.test", display_name: "Ada Lovelace"})

      assert {:ok, %{"comment" => first}} = comment(context.ada, id, "  First draft.  ")
      assert first["body"] == "First draft."
      assert first["author"] == %{"subject" => "ada@example.test", "display_name" => "Ada Lovelace"}
      assert first["created_at"]

      # Cy reads it, being in the organisation, and may not write in it until given a role.
      assert {:ok, %{"may_comment" => false, "comments" => [%{"body" => "First draft."}]}} =
               call(context.cy, "artifact.comments", %{"id" => id})

      assert {:error, %{message: "forbidden", data: %{reason: reason}}} = comment(context.cy, id, "Hm")
      assert reason =~ "comment or edit"

      {:ok, _} = call(context.ada, "artifact.share", %{"id" => id, "person" => context.cy.subject, "role" => "comment"})
      assert {:ok, _} = comment(context.cy, id, "Second.")

      assert {:ok, %{"may_comment" => true, "comments" => [one, two]}} =
               call(context.cy, "artifact.comments", %{"id" => id})

      assert {one["body"], two["body"]} == {"First draft.", "Second."}
      assert two["author"]["subject"] == "cy@example.test"

      # The rows say how long the thread is and when it was last written.
      assert {:ok, %{"artifacts" => rows}} = call(context.ada, "artifact.list", %{})
      row = Enum.find(rows, &(&1["id"] == id))
      assert row["comments"] == 2
      assert row["commented_at"]
    end

    test "refuses an empty or too long comment, and is not there for whoever may not open it", context do
      id = context.page["id"]

      assert {:error, %{message: "invalid_params"}} = comment(context.ada, id, "   ")
      assert {:error, %{message: "invalid_params"}} = comment(context.ada, id, String.duplicate("a", 4001))
      assert {:error, %{message: "invalid_params"}} = comment(context.ada, id, nil)

      assert {:error, %{message: "not_found"}} = call(context.cy, "artifact.comments", %{"id" => id})
      assert {:error, %{message: "not_found"}} = comment(context.cy, id, "Hello")
    end

    test "is audited as a write, never its text", context do
      id = context.page["id"]
      {:ok, %{"comment" => %{"id" => comment_id}}} = comment(context.ada, id, "Ship it on Friday.")

      [row] = Enum.filter(Audit.list(), &(&1.action == "artifact.comment"))
      assert row.subject_id == id
      assert row.detail == %{"comment" => comment_id, "length" => 18}
      refute inspect(row) =~ "Friday"
    end

    test "goes with the artifact", context do
      id = context.page["id"]
      {:ok, _} = comment(context.ada, id, "Gone soon.")
      {:ok, _} = call(context.ada, "artifact.delete", %{"id" => id})
      assert Repo.aggregate(Comment, :count) == 0
    end
  end

  describe "the session it came from" do
    setup do
      start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
      start_supervised!(Connections)
      start_supervised!(Troupe.Plane.Singleton)
      start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})
      {:ok, _} = Fleet.put_profile(%{name: "dev", config_bundle_channel: "stable", replicas: 1})
      %{port: Listener.port()}
    end

    test "hears a comment where it runs on a pod, with the artifact, the author and the text", context do
      worker = enrolled(context.port, "dev-token", "troupe-w-dev-0")
      answer_index(worker, [])
      [pod] = Fleet.list_workers("dev")

      {:ok, _} = Sessions.create(%{id: "s-report", owner_subject: context.ada.subject, owner_id: context.ada.id, profile: "dev"})
      {:ok, _} = Sessions.place("s-report", pod)

      id = context.page["id"]

      Repo.get!(Artifact, id)
      |> Ecto.Changeset.change(origin: %{"session_id" => "s-report", "where" => "pod"})
      |> Repo.update!()

      {:ok, _} = share_with(context, context.cy, "comment")
      {:ok, _} = comment(context.cy, id, "Can you add last quarter?")

      assert %{"params" => params} = push(worker, "artifact.commented")
      assert params["session_id"] == "s-report"
      assert params["artifact"] == %{"id" => id, "title" => "Plan"}
      assert params["comment"]["body"] == "Can you add last quarter?"
      assert params["comment"]["author"]["subject"] == "cy@example.test"
      assert is_integer(params["epoch"])
    end
  end

  # -- a pod over the control link, as `MemoryReadTest` has one ---------------------------

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line])
    %{socket: socket, id: :counters.new(1, [])}
  end

  defp enrolled(port, token, pod_name) do
    worker = connect(port)

    {:ok, _} =
      pod_call(worker, "enrol", %{
        "token" => FakePod.token(token),
        "pod_name" => pod_name,
        "capacity" => 4,
        "disk_total_bytes" => 1000
      })

    worker
  end

  defp answer_index(worker, sessions, attempts \\ 8)
  defp answer_index(_worker, _sessions, 0), do: flunk("no session.index request arrived")

  defp answer_index(worker, sessions, attempts) do
    case read(worker) do
      %{"method" => "session.index", "id" => id} ->
        :ok =
          :gen_tcp.send(worker.socket, [
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"sessions" => sessions}}),
            "\n"
          ])

      _other ->
        answer_index(worker, sessions, attempts - 1)
    end
  end

  defp pod_call(worker, method, params) do
    :counters.add(worker.id, 1, 1)
    id = :counters.get(worker.id, 1)

    :ok =
      :gen_tcp.send(worker.socket, [
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}),
        "\n"
      ])

    case answer(worker, id) do
      %{"result" => result} -> {:ok, result}
      %{"error" => error} -> {:error, error}
      other -> {:error, other}
    end
  end

  defp push(worker, method, attempts \\ 5)
  defp push(_worker, method, 0), do: flunk("no #{method} push arrived")

  defp push(worker, method, attempts) do
    case read(worker) do
      %{"method" => ^method} = message -> message
      _other -> push(worker, method, attempts - 1)
    end
  end

  defp answer(worker, id) do
    case read(worker) do
      %{"method" => _method} -> answer(worker, id)
      %{"id" => ^id} = message -> message
      other -> other
    end
  end

  defp read(worker, timeout \\ 5_000) do
    {:ok, line} = :gen_tcp.recv(worker.socket, 0, timeout)
    line |> String.split("\n", trim: true) |> hd() |> Jason.decode!()
  end
end
