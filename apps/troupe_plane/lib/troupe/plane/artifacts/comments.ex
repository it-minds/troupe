defmodule Troupe.Plane.Artifacts.Comments do
  @moduledoc """
  An artifact's thread of comments (#62): one per artifact, kept on the plane, oldest
  first, each with its author's name and when.

  **Who reads it** is whoever may open the artifact. **Who writes in it** is whoever holds
  `comment` or above on it: its owners, and the people a link or the owner's naming them
  gave `comment` or `edit`. Somebody who reads an artifact because of who it is for (the
  organisation, a team, a profile) reads its thread too and writes in it only once an
  owner gives them a role.

  **Who is told.** The session the artifact came from: the comment arrives there as an
  `artifact_commented` event, so whoever steers the session reads it beside the work and
  may ask the agent to act on it. Where that session is a pod's and it runs, the plane
  tells the pod at once; where it is a laptop's, the plane cannot reach it, and its daemon
  hears the comments on its person's artifacts on the poll it makes anyway (`since/2`, on
  `me.memory`). Never input: a comment is somebody else's words, and nothing a reader
  writes reaches an agent unless the person steering it passes it on. The owners and
  editors find it in every gallery, whose rows carry how many comments there are and when
  the last was written.

  **Taking one back.** Its author deletes it or edits it, an edit marked with when; the
  artifact's owners delete any in their thread, and whoever may take the artifact down (a
  platform administrator, the administrator of the team it is for) any too. A deleted
  comment is gone from the thread, with no mark left in its place, and a session told of it
  is not told again; an edit is not announced.

  A comment is audited as `artifact.comment` with its id and length, never its text; a
  deletion as `artifact.comment.delete` with its id, its author and who deleted it, an edit
  as `artifact.comment.edit` with its id and new length.
  """

  import Ecto.Query

  alias Troupe.Plane.Artifacts.{Artifact, Comment}
  alias Troupe.Plane.{Audit, Fleet, Names, Repo}
  alias Troupe.Plane.Control.Router
  alias Troupe.Plane.Identity.User
  alias Troupe.Plane.Sessions.Session
  alias Troupe.Protocol.Error

  @max_body 4000
  @max_thread 500

  @doc "The longest comment, in characters."
  @spec max_body() :: pos_integer()
  def max_body, do: @max_body

  @doc "The roles that write in a thread."
  @spec writers() :: [String.t()]
  def writers, do: ~w(owner edit comment)

  @doc """
  `artifact`'s thread, oldest first, at most the newest #{@max_thread}, as `user` reads it:
  each comment says whether they may edit it (their own, while they may write here) and
  delete it (their own, or any for an owner, or for whoever may take the artifact down,
  `takedown?`).
  """
  @spec list(Artifact.t(), User.t(), String.t() | nil, boolean()) :: [map()]
  def list(%Artifact{id: id}, %User{} = user, role, takedown?) do
    comments =
      from(c in Comment,
        where: c.artifact_id == ^id,
        order_by: [desc: c.inserted_at],
        limit: @max_thread
      )
      |> Repo.all()
      |> Enum.reverse()

    names = Names.of(Enum.map(comments, & &1.author_subject))

    Enum.map(comments, fn comment ->
      comment
      |> json(names)
      |> Map.put("may_edit", editor(comment, user, role) == :ok)
      |> Map.put("may_delete", match?({:ok, _by}, deleter(comment, user, role, takedown?)))
    end)
  end

  @doc """
  Write `body` in `artifact`'s thread as `user`, who holds `role` on it: a writer's
  (`writers/0`), or `forbidden` in a sentence that says who may.
  """
  @spec add(Artifact.t(), User.t(), String.t() | nil, term()) :: {:ok, map()} | {:error, Error.t()}
  def add(%Artifact{} = artifact, %User{} = user, role, body) do
    with :ok <- writer(artifact, role),
         {:ok, body} <- body(body) do
      comment =
        Repo.insert!(%Comment{
          artifact_id: artifact.id,
          author_id: if(is_binary(user.id), do: user.id),
          author_subject: user.subject,
          body: body
        })

      {:ok, _event} =
        Audit.record(user.subject, "artifact.comment", artifact.id, %{
          "comment" => comment.id,
          "length" => String.length(body)
        })

      json = json(comment, Names.of([user.subject]))
      tell_session(artifact, json)
      {:ok, %{"id" => artifact.id, "comment" => json}}
    end
  end

  defp writer(_artifact, role) when is_binary(role) do
    if role in writers(), do: :ok, else: refused()
  end

  defp writer(_artifact, _role), do: refused()

  defp refused,
    do:
      {:error,
       Error.new(:forbidden, %{
         reason:
           "you may read this artifact's comments; its owner gives the people who may write in them comment or edit"
       })}

  defp body(body) when is_binary(body) do
    case String.trim(body) do
      "" -> {:error, invalid("a comment needs some text")}
      text -> if String.length(text) > @max_body, do: {:error, invalid("a comment is at most #{@max_body} characters")}, else: {:ok, text}
    end
  end

  defp body(other), do: {:error, invalid("a comment is text, not #{inspect(other)}")}

  @doc """
  Delete comment `id` from `artifact`'s thread as `user`, who holds `role` on it: its
  author, an owner, or whoever may take the artifact down (`takedown?`). The row goes; the
  audit keeps its id, its author and who deleted it, never its text.
  """
  @spec delete(Artifact.t(), User.t(), String.t() | nil, boolean(), term()) :: {:ok, map()} | {:error, Error.t()}
  def delete(%Artifact{} = artifact, %User{} = user, role, takedown?, id) do
    with {:ok, comment} <- find(artifact, id),
         {:ok, by} <- deleter(comment, user, role, takedown?) do
      Repo.delete!(comment)

      {:ok, _event} =
        Audit.record(user.subject, "artifact.comment.delete", artifact.id, %{
          "comment" => comment.id,
          "author" => comment.author_subject,
          "by" => by
        })

      {:ok, %{"id" => artifact.id, "comment" => comment.id, "deleted" => true}}
    end
  end

  @doc """
  Replace comment `id`'s text with `body` as `user`, its author, while they may write in the
  thread (`role`). Marked edited with when; the session it was told to is not told again.
  """
  @spec edit(Artifact.t(), User.t(), String.t() | nil, term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def edit(%Artifact{} = artifact, %User{} = user, role, id, body) do
    with {:ok, comment} <- find(artifact, id),
         :ok <- editor(comment, user, role),
         {:ok, body} <- body(body) do
      comment =
        comment
        |> Ecto.Changeset.change(%{body: body, edited_at: DateTime.utc_now()})
        |> Repo.update!()

      {:ok, _event} =
        Audit.record(user.subject, "artifact.comment.edit", artifact.id, %{
          "comment" => comment.id,
          "length" => String.length(body)
        })

      {:ok, %{"id" => artifact.id, "comment" => json(comment, Names.of([comment.author_subject]))}}
    end
  end

  defp find(%Artifact{id: artifact_id}, id) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Comment{} = comment <- Repo.get_by(Comment, id: uuid, artifact_id: artifact_id) do
      {:ok, comment}
    else
      _none -> {:error, Error.new(:not_found, %{comment: id})}
    end
  end

  defp find(_artifact, other),
    do: {:error, invalid("a comment is named by its id, not #{inspect(other)}")}

  defp author?(%Comment{author_subject: subject}, %User{subject: subject}) when is_binary(subject), do: true
  defp author?(_comment, _user), do: false

  # Its author while they may still write in the thread: a role taken away takes the
  # editing of what they wrote under it, not its deletion.
  defp editor(comment, user, role) do
    cond do
      not author?(comment, user) ->
        {:error, Error.new(:forbidden, %{reason: "only whoever wrote a comment edits it"})}

      role in writers() ->
        :ok

      true ->
        refused()
    end
  end

  defp deleter(comment, user, role, takedown?) do
    cond do
      author?(comment, user) ->
        {:ok, "author"}

      role == "owner" ->
        {:ok, "owner"}

      takedown? ->
        {:ok, "takedown"}

      true ->
        {:error,
         Error.new(:forbidden, %{
           reason:
             "only whoever wrote a comment, the artifact's owners, or whoever may take the artifact down deletes it"
         })}
    end
  end

  @most_since 200

  @doc """
  What `user`'s daemon hears on its poll (`me.memory` with `artifact_comments`): the comments
  written after `since` on the artifacts they published from a session on their own machine
  (`origin.where: laptop`), oldest first, at most #{@most_since}, each with the session it
  came from, and the `since` to ask with next. With no `since`, none, and the plane's now to
  start from: a daemon hears what is written while it runs, as a pod's session does.
  """
  @spec since(User.t(), term()) :: %{String.t() => term()}
  def since(%User{id: user_id}, since) when is_binary(user_id) do
    case cursor(since) do
      {:ok, at} ->
        rows =
          from(c in Comment,
            join: a in Artifact,
            on: a.id == c.artifact_id,
            where:
              a.owner_id == ^user_id and c.inserted_at > ^at and
                fragment("?->>'where'", a.origin) == "laptop" and
                not is_nil(fragment("?->>'session_id'", a.origin)),
            order_by: [asc: c.inserted_at],
            limit: @most_since,
            select: {c, a.id, a.title, fragment("?->>'session_id'", a.origin)}
          )
          |> Repo.all()

        names = Names.of(Enum.map(rows, fn {comment, _id, _title, _session} -> comment.author_subject end))

        last =
          case List.last(rows) do
            {comment, _id, _title, _session} -> comment.inserted_at
            nil -> at
          end

        %{
          "since" => DateTime.to_iso8601(last),
          "comments" =>
            Enum.map(rows, fn {comment, id, title, session_id} ->
              %{
                "session_id" => session_id,
                "artifact" => %{"id" => id, "title" => title},
                "comment" => json(comment, names)
              }
            end)
        }

      :none ->
        %{"since" => DateTime.to_iso8601(DateTime.utc_now()), "comments" => []}
    end
  end

  def since(_user, _since), do: %{"since" => DateTime.to_iso8601(DateTime.utc_now()), "comments" => []}

  defp cursor(since) when is_binary(since) do
    case DateTime.from_iso8601(since) do
      {:ok, at, _offset} -> {:ok, at}
      _not -> :none
    end
  end

  defp cursor(_since), do: :none

  @doc "How many comments each of `ids` has, and when the newest was written."
  @spec counts([String.t()]) :: %{String.t() => {non_neg_integer(), DateTime.t()}}
  def counts([]), do: %{}

  def counts(ids) do
    from(c in Comment,
      where: c.artifact_id in ^ids,
      group_by: c.artifact_id,
      select: {c.artifact_id, count(c.id), max(c.inserted_at)}
    )
    |> Repo.all()
    |> Map.new(fn {id, n, at} -> {id, {n, at}} end)
  end

  # Best effort, as memory's news is: a pod that does not hear it, or a session that is not
  # running, has the comment in the artifact's thread anyway.
  defp tell_session(%Artifact{origin: %{"session_id" => session_id, "where" => "pod"}} = artifact, comment)
       when is_binary(session_id) do
    with %Session{state: "active", worker_id: worker_id} = session when is_binary(worker_id) <-
           Repo.get(Session, session_id),
         %Fleet.Worker{} = worker <- Fleet.get_worker(worker_id) do
      Router.notify(worker, "artifact.commented", %{
        "session_id" => session.id,
        "epoch" => session.epoch,
        "artifact" => %{"id" => artifact.id, "title" => artifact.title},
        "comment" => comment
      })
    end

    :ok
  end

  defp tell_session(_artifact, _comment), do: :ok

  defp json(%Comment{} = comment, names) do
    %{
      "id" => comment.id,
      "author" => %{
        "subject" => comment.author_subject,
        "display_name" => Map.get(names, comment.author_subject)
      },
      "body" => comment.body,
      "created_at" => comment.inserted_at,
      "edited_at" => comment.edited_at
    }
  end

  defp invalid(reason), do: Error.new(:invalid_params, %{reason: reason})
end
