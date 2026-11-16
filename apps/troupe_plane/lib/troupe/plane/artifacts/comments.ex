defmodule Troupe.Plane.Artifacts.Comments do
  @moduledoc """
  An artifact's thread of comments (#62): one per artifact, kept on the plane, oldest
  first, each with its author's name and when.

  **Who reads it** is whoever may open the artifact. **Who writes in it** is whoever holds
  `comment` or above on it: its owners, and the people a link or the owner's naming them
  gave `comment` or `edit`. Somebody who reads an artifact because of who it is for (the
  organisation, a team, a profile) reads its thread too and writes in it only once an
  owner gives them a role.

  **Who is told.** The session the artifact came from, where that is a pod's and it runs:
  the comment arrives there as an `artifact_commented` event, so whoever steers the
  session reads it beside the work and may ask the agent to act on it. Never input: a
  comment is somebody else's words, and nothing a reader writes reaches an agent unless the
  person steering it passes it on. The owners and editors find it in every gallery, whose
  rows carry how many comments there are and when the last was written.

  A comment is audited as `artifact.comment` with its id and length, never its text.
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

  @doc "`artifact`'s thread, oldest first, at most the newest #{@max_thread}."
  @spec list(Artifact.t()) :: [map()]
  def list(%Artifact{id: id}) do
    comments =
      from(c in Comment,
        where: c.artifact_id == ^id,
        order_by: [desc: c.inserted_at],
        limit: @max_thread
      )
      |> Repo.all()
      |> Enum.reverse()

    names = Names.of(Enum.map(comments, & &1.author_subject))
    Enum.map(comments, &json(&1, names))
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
      "created_at" => comment.inserted_at
    }
  end

  defp invalid(reason), do: Error.new(:invalid_params, %{reason: reason})
end
