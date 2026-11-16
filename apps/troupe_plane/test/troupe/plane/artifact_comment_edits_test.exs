defmodule Troupe.Plane.ArtifactCommentEditsTest do
  @moduledoc """
  A comment taken back or edited (#979), and the comments a laptop's daemon hears on its
  poll (#980).

  `artifact.comment.delete` is its author's, an owner's, and a takedown by whoever may take
  the artifact down; `artifact.comment.edit` its author's, marked edited. Each is audited
  without the text, and the thread says per comment who may do which. `me.memory` asked with
  `artifact_comments: {since}` answers the comments written since on the caller's artifacts
  that came from a session on their machine, beside the signed memory. Through `Harness`, as
  `/rpc` reaches them.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.ObjectStore
  alias Troupe.Plane.{Admin, Audit, Harness, Identity}

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    Application.put_env(:troupe_plane, :artifacts, url: "https://artifacts.example.test")

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :platform_admin_group)
      Application.delete_env(:troupe_plane, :artifacts)
      ObjectStore.delete_prefix(ObjectStore.from_env(), "artifacts/")
    end)

    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _team} = Identity.enable_team(group, %{name: "platform"})
    _engineering = team_with_grant("engineering", "dev", name: "engineering")
    _research = team_with_grant("research", "lab", name: "research")

    ada = person("ada@example.test", ["engineering"])

    {:ok, page} =
      call(ada, "artifact.publish", %{
        "title" => "Roadmap",
        "kind" => "markdown",
        "visibility" => "organisation",
        "files" => [%{"path" => "index.md", "bytes" => Base.encode64("# Roadmap")}]
      })

    %{
      ada: ada,
      root: person("root@example.test", ["platform"]),
      cy: person("cy@example.test", ["research"]),
      di: person("di@example.test", ["research"]),
      page: page
    }
  end

  defp as(user), do: %{user: user, platform_admin?: Admin.actor_for(user).role == :platform_admin}
  defp call(user, method, params), do: Harness.call(method, params, as(user))

  defp comment(user, id, body), do: call(user, "artifact.comment", %{"id" => id, "body" => body})
  defp delete(user, id, comment), do: call(user, "artifact.comment.delete", %{"id" => id, "comment" => comment})

  defp edit(user, id, comment, body),
    do: call(user, "artifact.comment.edit", %{"id" => id, "comment" => comment, "body" => body})

  defp share_with(context, person, role),
    do: call(context.ada, "artifact.share", %{"id" => context.page["id"], "person" => person.subject, "role" => role})

  defp thread(user, id) do
    {:ok, %{"comments" => comments}} = call(user, "artifact.comments", %{"id" => id})
    comments
  end

  describe "a comment deleted" do
    test "by its author, and refused to another writer who is not an owner", context do
      id = context.page["id"]
      {:ok, _} = share_with(context, context.cy, "comment")
      {:ok, _} = share_with(context, context.di, "comment")
      {:ok, %{"comment" => %{"id" => mine}}} = comment(context.cy, id, "Wrong figure in row 3.")

      assert {:error, %{message: "forbidden", data: %{reason: reason}}} = delete(context.di, id, mine)
      assert reason =~ "wrote"
      assert [%{"id" => ^mine}] = thread(context.ada, id)

      assert {:ok, %{"comment" => ^mine, "deleted" => true}} = delete(context.cy, id, mine)
      assert thread(context.ada, id) == []

      # Gone is gone: deleting it again finds nothing.
      assert {:error, %{message: "not_found"}} = delete(context.cy, id, mine)
    end

    test "by an owner, whoever wrote it, and the rows count what is left", context do
      id = context.page["id"]
      {:ok, _} = share_with(context, context.cy, "comment")
      {:ok, %{"comment" => %{"id" => theirs}}} = comment(context.cy, id, "Off topic.")
      {:ok, %{"comment" => %{"id" => _own}}} = comment(context.ada, id, "Thanks.")

      assert {:ok, %{"deleted" => true}} = delete(context.ada, id, theirs)
      assert [%{"body" => "Thanks."}] = thread(context.ada, id)

      {:ok, %{"artifacts" => rows}} = call(context.ada, "artifact.list", %{})
      assert Enum.find(rows, &(&1["id"] == id))["comments"] == 1
    end

    test "by a platform administrator as a takedown, and audited with who and never the text", context do
      id = context.page["id"]
      {:ok, _} = share_with(context, context.cy, "comment")
      {:ok, %{"comment" => %{"id" => theirs}}} = comment(context.cy, id, "Call me on 555 0100.")

      # A reader of the organisation's artifact who is neither its author nor an owner.
      assert {:error, %{message: "forbidden"}} = delete(context.di, id, theirs)

      assert [%{"may_delete" => true, "may_edit" => false}] = thread(context.root, id)
      assert {:ok, %{"deleted" => true}} = delete(context.root, id, theirs)

      [row] = Enum.filter(Audit.list(), &(&1.action == "artifact.comment.delete"))
      assert row.actor == context.root.subject
      assert row.subject_id == id
      assert row.detail == %{"comment" => theirs, "author" => context.cy.subject, "by" => "takedown"}
      refute inspect(row) =~ "555"
    end

    test "is refused for a comment that is not in this artifact's thread, or no id at all", context do
      id = context.page["id"]

      assert {:error, %{message: "not_found"}} = delete(context.ada, id, Ecto.UUID.generate())
      assert {:error, %{message: "not_found"}} = delete(context.ada, id, "not-a-uuid")
      assert {:error, %{message: "invalid_params"}} = delete(context.ada, id, nil)
      assert {:error, %{message: "invalid_params"}} = call(context.ada, "artifact.comment.delete", %{})
    end
  end

  describe "a comment edited" do
    test "by its author, marked edited, audited without the text, and nobody else's to edit", context do
      id = context.page["id"]
      {:ok, _} = share_with(context, context.cy, "comment")
      {:ok, %{"comment" => %{"id" => theirs, "edited_at" => nil}}} = comment(context.cy, id, "Row 3 is wrong.")

      # The thread says per comment, to each reader, what they may do with it.
      assert [%{"may_edit" => true, "may_delete" => true}] = thread(context.cy, id)
      assert [%{"may_edit" => false, "may_delete" => true}] = thread(context.ada, id)
      assert [%{"may_edit" => false, "may_delete" => false}] = thread(context.di, id)

      assert {:error, %{message: "forbidden", data: %{reason: reason}}} = edit(context.ada, id, theirs, "Row 4.")
      assert reason =~ "wrote"

      assert {:ok, %{"comment" => edited}} = edit(context.cy, id, theirs, "  Row 4 is wrong, not row 3.  ")
      assert edited["body"] == "Row 4 is wrong, not row 3."
      assert edited["edited_at"]
      assert [%{"body" => "Row 4 is wrong, not row 3.", "edited_at" => at}] = thread(context.ada, id)
      assert at

      assert {:error, %{message: "invalid_params"}} = edit(context.cy, id, theirs, "  ")

      [row] = Enum.filter(Audit.list(), &(&1.action == "artifact.comment.edit"))
      assert row.detail == %{"comment" => theirs, "length" => 26}
      refute inspect(row) =~ "Row 4"
    end

    test "not once its author may no longer write in the thread, though they may still delete it", context do
      id = context.page["id"]
      {:ok, _} = share_with(context, context.cy, "comment")
      {:ok, %{"comment" => %{"id" => theirs}}} = comment(context.cy, id, "Draft.")
      {:ok, _} = call(context.ada, "artifact.unshare", %{"id" => id, "person" => context.cy.subject})

      # Cy still reads the organisation's artifact, and no longer writes in its thread.
      assert [%{"may_edit" => false, "may_delete" => true}] = thread(context.cy, id)
      assert {:error, %{message: "forbidden"}} = edit(context.cy, id, theirs, "Final.")
      assert {:ok, %{"deleted" => true}} = delete(context.cy, id, theirs)
    end
  end

  describe "a laptop's daemon, on its poll" do
    defp poll(user, since),
      do: Harness.call("me.memory", %{"artifact_comments" => %{"since" => since}}, as(user))

    test "hears the comments on its person's artifacts from a session on their machine, since its last poll",
         context do
      {:ok, laptop} =
        call(context.ada, "artifact.publish", %{
          "title" => "Findings",
          "kind" => "markdown",
          "visibility" => "organisation",
          "session_id" => "s-laptop-1",
          "agent" => "root",
          "files" => [%{"path" => "index.md", "bytes" => Base.encode64("# Findings")}]
        })

      {:ok, theirs} =
        call(context.cy, "artifact.publish", %{
          "title" => "Cy's",
          "kind" => "markdown",
          "visibility" => "organisation",
          "session_id" => "s-laptop-2",
          "files" => [%{"path" => "index.md", "bytes" => Base.encode64("# Cy")}]
        })

      for {owner, artifact} <- [{context.ada, laptop}, {context.ada, context.page}, {context.cy, theirs}] do
        {:ok, _} = call(owner, "artifact.share", %{"id" => artifact["id"], "person" => context.di.subject, "role" => "comment"})
      end

      # The first poll hears nothing written before it, and is given where to start.
      {:ok, _} = comment(context.ada, laptop["id"], "Before the daemon asked.")
      assert {:ok, %{"artifact_comments" => %{"since" => since, "comments" => []}} = answer} = poll(context.ada, nil)
      # Beside the signed memory, not in it.
      refute inspect(answer["signed"]) =~ "artifact_comments"

      {:ok, %{"comment" => %{"id" => first}}} = comment(context.di, laptop["id"], "Is the second table right?")
      # Not one on an artifact published by nobody's session, nor on somebody else's.
      {:ok, _} = comment(context.di, context.page["id"], "On the roadmap.")
      {:ok, _} = comment(context.di, theirs["id"], "On Cy's.")

      assert {:ok, %{"artifact_comments" => %{"since" => next, "comments" => [heard]}}} = poll(context.ada, since)

      assert heard["session_id"] == "s-laptop-1"
      assert heard["artifact"] == %{"id" => laptop["id"], "title" => "Findings"}
      assert heard["comment"]["id"] == first
      assert heard["comment"]["body"] == "Is the second table right?"
      assert heard["comment"]["author"]["subject"] == context.di.subject

      # Asked again from where it left off: nothing new, and a deleted one is not told.
      assert {:ok, %{"artifact_comments" => %{"since" => ^next, "comments" => []}}} = poll(context.ada, next)
      {:ok, %{"comment" => %{"id" => gone}}} = comment(context.di, laptop["id"], "Never mind.")
      {:ok, _} = delete(context.di, laptop["id"], gone)
      assert {:ok, %{"artifact_comments" => %{"comments" => []}}} = poll(context.ada, next)
    end

    test "is not asked about comments by a poll that does not ask", context do
      assert {:ok, answer} = Harness.call("me.memory", %{}, as(context.ada))
      refute Map.has_key?(answer, "artifact_comments")
    end
  end
end
