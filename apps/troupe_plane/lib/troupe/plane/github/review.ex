defmodule Troupe.Plane.GitHub.Review do
  @moduledoc """
  A review on a draft pull request a run opened sends that run's session back to work.

  GitHub sends `pull_request_review` with `submitted` for every review a person makes:
  one that requests changes, one that only comments, and each single comment or reply
  made on the pull request's lines, which GitHub makes a review of its own. That is the
  one event this reads. The review's comments on lines come as `pull_request_review_comment`
  too, one delivery each; those are left alone, and the plane reads a review's comments
  from GitHub instead (`GitHub.review_comments/3`), so that one review is one input to the
  session rather than one for each line.

  A review resumes a session only when all of these hold, and does nothing otherwise:

  - it requests changes, or comments with something to say (an approval asks for nothing);
  - the pull request is a draft, on a repository of the plane's App's installations, and it
    is the one a session recorded (`sessions.github`), by number and by link;
  - that session is a trigger's run, which acts as the trigger's principal, as its first
    firing did. A session a person started stays theirs to steer;
  - the reviewer is the repository's owner, a member or a collaborator, and not a bot;
  - the session's pushes are not closed by three red CI rounds: that draft is a person's.

  A comment on the pull request's conversation (`issue_comment` with `created` on a pull
  request) resumes it the same way, under the same rules, with the comment as the input
  (`resume_comment/2`); whether the pull request is still a draft is read from GitHub,
  since such a delivery does not say.

  The session is woken as the run's principal, through `session.open`, as anything that
  wakes a session does, and the review is pushed to its pod as its next input, fenced and
  marked as data (`session.input`), the one other piece of session content the control
  channel carries besides a first prompt. Every resume is an audit entry, `github.review`,
  for the session's owner.
  """

  import Ecto.Query, only: [from: 2]

  alias Troupe.Plane.{Audit, Fleet, GitHub, Harness, Repo, Sessions, Triggers}
  alias Troupe.Plane.Control.Router
  alias Troupe.Plane.GitHub.Issue
  alias Troupe.Plane.Sessions.Session

  require Logger

  @states ~w(changes_requested commented)

  # What one review may put in front of a session, encoded: the body and the comments,
  # each bounded, under the 64 KiB a first prompt may be.
  @body_bytes 8_192
  @comment_bytes 2_048
  @input_bytes 49_152

  @doc """
  Resume the session a review is about, if it is one this may resume. Answers what was
  done, for the delivery's record: `%{"resumed" => session_id}`, `%{"ignored" => why}`, or
  `%{"failed" => why}` where it should have and could not.
  """
  @spec resume(String.t(), map()) :: map()
  def resume(delivery, payload) do
    with {:ok, review} <- review(payload),
         {:ok, pull} <- pull_request(payload),
         {:ok, session, run} <- session_for(payload, pull),
         :ok <- open(session),
         {:ok, comments} <- comments(session, pull, review),
         {:ok, user} <- acting(run),
         {:ok, _endpoint} <- wake(session, user),
         :ok <-
           push(
             session.id,
             "github-review-#{delivery}",
             input(pull, review, comments),
             "a GitHub review by #{review.author}"
           ) do
      audit(session, pull, review, delivery)
      %{"resumed" => session.id}
    else
      {:ignore, why} ->
        %{"ignored" => why}

      {:error, why} ->
        reason = explain(why)
        Logger.warning("troupe plane: a review on GitHub could not resume its session: #{reason}")
        %{"failed" => reason}
    end
  end

  @doc """
  A comment on the conversation of a draft pull request a run opened resumes that run's
  session with the comment as its next input, as a review does and under the same rules:
  a comment GitHub calls the repository's owner's, a member's or a collaborator's, never a
  bot's (the App's own among them), with something to say; a pull request that is a draft,
  of an installation the plane lists, recorded by exactly one session that is a trigger's
  run and whose pushes are not closed. Whether it is still a draft is read from GitHub, with
  a token of the plane's own (`pull_requests: read`), since an issue's comment does not say.
  """
  @spec resume_comment(String.t(), map()) :: map()
  def resume_comment(delivery, payload) do
    with {:ok, comment} <- comment(payload),
         {:ok, pull} <- commented_pull_request(payload),
         {:ok, session, run} <- session_for(payload, pull),
         :ok <- open(session),
         :ok <- still_draft(session, pull, comment),
         {:ok, user} <- acting(run),
         {:ok, _endpoint} <- wake(session, user),
         :ok <-
           push(
             session.id,
             "github-comment-#{delivery}",
             comment_input(pull, comment),
             "a GitHub comment by #{comment.author}"
           ) do
      audit_comment(session, pull, comment, delivery)
      %{"resumed" => session.id}
    else
      {:ignore, why} ->
        %{"ignored" => why}

      {:error, why} ->
        reason = explain(why)

        Logger.warning(
          "troupe plane: a comment on GitHub could not resume its session: #{reason}"
        )

        %{"failed" => reason}
    end
  end

  # -- what the comment is -----------------------------------------------------------------

  defp comment(%{"action" => "created", "comment" => %{} = comment} = payload) do
    cond do
      Issue.bot?(comment["user"]) or Issue.bot?(payload["sender"]) ->
        {:ignore, "a bot's comment"}

      not Issue.own?(comment["author_association"]) ->
        {:ignore, "a comment by somebody the repository does not count as its own"}

      blank?(comment["body"]) ->
        {:ignore, "a comment with nothing to say"}

      true ->
        {:ok,
         %{
           id: comment["id"],
           body: Issue.cut(comment["body"], @body_bytes),
           author: get_in(comment, ["user", "login"]),
           url: comment["html_url"]
         }}
    end
  end

  defp comment(_payload), do: {:ignore, "not a new comment"}

  defp commented_pull_request(%{"issue" => %{"number" => number} = issue} = payload)
       when is_integer(number) do
    cond do
      not is_map(issue["pull_request"]) ->
        {:ignore, "a comment on an issue, not on a pull request's conversation"}

      not installed?(payload) ->
        {:ignore, "a repository of no installation of this plane's App"}

      true ->
        {:ok, %{number: number, url: issue["pull_request"]["html_url"] || issue["html_url"]}}
    end
  end

  defp commented_pull_request(_payload), do: {:ignore, "a comment on no pull request"}

  defp still_draft(
         %Session{repository: %{"owner" => owner, "name" => name}} = session,
         pull,
         comment
       ) do
    audit = %{
      "session_id" => session.id,
      "for" => "comment #{comment.id} on pull request #{pull.number}"
    }

    with {:ok, reader} <-
           GitHub.reader(owner, name, %{"pull_requests" => "read"}, audit, session.owner_subject),
         {:ok, %{} = read} <- reader.get.("/pulls/#{pull.number}", []) do
      cond do
        read["state"] not in [nil, "open"] ->
          {:ignore, "a comment on a pull request that is closed"}

        read["draft"] != true ->
          {:ignore, "a comment on a pull request that is not a draft"}

        true ->
          :ok
      end
    else
      {:ok, _other} -> {:error, "GitHub's answer for pull request ##{pull.number} was not one"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The input a comment gives a session: what happened and what to do, then the comment,
  fenced and marked as data.
  """
  @spec comment_input(map(), map()) :: String.t()
  def comment_input(pull, comment) do
    head =
      "A comment on your draft pull request ##{pull.number} (#{pull.url}) by " <>
        "#{comment.author}. Work on what it asks in this repository, then push with " <>
        "git_push and read CI with pr_checks, as before. If it asks for something you will " <>
        "not do, say why with pr_comment."

    text = Issue.cut("Comment by #{comment.author}:\n\n#{comment.body}", @input_bytes)

    Enum.join([head, "", Issue.data_note("comment"), Issue.fence("github-comment", text)], "\n")
  end

  defp audit_comment(session, pull, comment, delivery) do
    {:ok, _} =
      Audit.record(
        "github",
        "github.comment",
        "#{session.repository["owner"]}/#{session.repository["name"]}",
        %{
          "session_id" => session.id,
          "pull_request" => pull.number,
          "commenter" => comment.author,
          "comment" => comment.id,
          "delivery" => delivery
        },
        on_behalf_of: session.owner_subject
      )
  end

  # -- what the review is ----------------------------------------------------------------

  defp review(%{"action" => "submitted", "review" => %{} = review} = payload) do
    state = review["state"] |> to_string() |> String.downcase()

    cond do
      state not in @states ->
        {:ignore, "a review that #{state} asks nothing of a session"}

      Issue.bot?(review["user"]) or Issue.bot?(payload["sender"]) ->
        {:ignore, "a bot's review"}

      not Issue.own?(review["author_association"]) ->
        {:ignore, "a review by somebody the repository does not count as its own"}

      not is_integer(review["id"]) ->
        {:ignore, "a review GitHub gave no id"}

      true ->
        {:ok,
         %{
           id: review["id"],
           state: state,
           body: Issue.cut(review["body"], @body_bytes),
           author: get_in(review, ["user", "login"]),
           url: review["html_url"]
         }}
    end
  end

  defp review(_payload), do: {:ignore, "not a submitted review"}

  defp pull_request(%{"pull_request" => %{"number" => number} = pull} = payload)
       when is_integer(number) do
    cond do
      pull["draft"] != true ->
        {:ignore, "a review on a pull request that is not a draft"}

      not installed?(payload) ->
        {:ignore, "a repository of no installation of this plane's App"}

      true ->
        {:ok, %{number: number, url: pull["html_url"]}}
    end
  end

  defp pull_request(_payload), do: {:ignore, "a review on no pull request"}

  defp installed?(payload) do
    GitHub.installed?(
      get_in(payload, ["repository", "owner", "login"]),
      get_in(payload, ["installation", "id"])
    )
  end

  # The session that recorded this pull request, by its repository and number, and then by
  # its link, which the plane checked was this repository's on the App's host when the pod
  # reported it. And the trigger's run it is.
  defp session_for(payload, pull) do
    case recorded(payload, pull) do
      [session] -> run_for(session)
      [] -> {:ignore, "a pull request no session of this plane opened"}
      _several -> {:ignore, "a pull request more than one session recorded"}
    end
  end

  defp recorded(payload, pull) do
    owner = get_in(payload, ["repository", "owner", "login"]) || ""
    name = get_in(payload, ["repository", "name"]) || ""
    number = Integer.to_string(pull.number)

    from(s in Session,
      where:
        fragment("lower(?->>'owner')", s.repository) == ^String.downcase(owner) and
          fragment("lower(?->>'name')", s.repository) == ^String.downcase(name) and
          fragment("?->'pull_request'->>'number'", s.github) == ^number
    )
    |> Repo.all()
    |> Enum.filter(&same_link?(&1, pull))
  end

  defp run_for(session) do
    case Triggers.run_of(session.id) do
      {run, _trigger} -> {:ok, session, run}
      nil -> {:ignore, "a pull request a person's session opened, not a run's"}
    end
  end

  defp same_link?(%Session{github: %{"pull_request" => %{"url" => url}}}, %{url: given})
       when is_binary(url) and is_binary(given),
       do: String.downcase(url) == String.downcase(given)

  defp same_link?(_session, _pull), do: false

  defp open(%Session{state: state}) when state not in ["active", "dormant"],
    do: {:ignore, "a session that is #{state}"}

  defp open(%Session{github: github}) do
    if GitHub.stopped?(github),
      do:
        {:ignore,
         "a session whose pushes three red CI rounds closed; its draft is a person's now"},
      else: :ok
  end

  defp comments(session, pull, review) do
    case GitHub.review_comments(session, pull.number, review.id) do
      {:ok, comments} ->
        comments = Enum.filter(comments, &is_binary(&1["body"]))

        if comments == [] and blank?(review.body),
          do: {:ignore, "a review with nothing to say"},
          else: {:ok, comments}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp blank?(nil), do: true
  defp blank?(text), do: String.trim(text) == ""

  defp acting(run) do
    case Triggers.acting_user(run) do
      {:ok, user} -> {:ok, user}
      {:error, error} -> {:error, error.data[:reason] || error.message}
    end
  end

  # Woken as the run's principal, as anything that wakes a session is: its grant, its
  # budget and its placement are checked as they are for a person opening it.
  defp wake(session, user) do
    case Harness.call(
           "session.open",
           %{"session_id" => session.id, "mode" => "activate"},
           %{user: user, platform_admin?: false}
         ) do
      {:ok, endpoint} -> {:ok, endpoint}
      {:error, error} -> {:error, error.data[:reason] || error.message}
    end
  end

  defp push(session_id, input_id, text, display_name) do
    with %Session{worker_id: worker_id} = session when is_binary(worker_id) <-
           Sessions.get(session_id),
         %{} = worker <- Fleet.get_worker(worker_id) do
      params = %{
        "session_id" => session_id,
        "epoch" => session.epoch,
        "input" => %{"id" => input_id, "text" => text},
        "actor" => %{
          "kind" => "service",
          "subject" => session.owner_subject,
          "display_name" => display_name
        }
      }

      case Router.push(worker, "session.input", params) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, "its pod did not take the input: #{inspect(reason)}"}
      end
    else
      _ -> {:error, "no pod holds the session"}
    end
  end

  # -- what the session is given ------------------------------------------------------

  @doc """
  The input a review gives a session: what happened and what to do, then the review's body
  and its comments on lines, fenced and marked as data.
  """
  @spec input(map(), map(), [map()]) :: String.t()
  def input(pull, review, comments) do
    asked =
      if review.state == "changes_requested", do: "requests changes", else: "comments"

    head =
      "A review on your draft pull request ##{pull.number} (#{pull.url}) by " <>
        "#{review.author} #{asked}. Work on what it asks in this repository, then push with " <>
        "git_push and read CI with pr_checks, as before. If it asks for something you will " <>
        "not do, say why with pr_comment."

    Enum.join(
      [head, "", Issue.data_note("review"), Issue.fence("github-review", text(review, comments))],
      "\n"
    )
  end

  defp text(review, comments) do
    body = if blank?(review.body), do: "(no summary)", else: review.body

    lines =
      Enum.map(comments, fn comment ->
        where = Enum.join(Enum.reject([comment["path"], comment["line"]], &is_nil/1), ":")
        "On #{where} (#{comment["author"]}):\n#{Issue.cut(comment["body"], @comment_bytes)}"
      end)

    ["Review by #{review.author}:", "", body | Enum.flat_map(lines, &["", &1])]
    |> Enum.join("\n")
    |> Issue.cut(@input_bytes)
  end

  defp audit(session, pull, review, delivery) do
    {:ok, _} =
      Audit.record(
        "github",
        "github.review",
        "#{session.repository["owner"]}/#{session.repository["name"]}",
        %{
          "session_id" => session.id,
          "pull_request" => pull.number,
          "reviewer" => review.author,
          "state" => review.state,
          "delivery" => delivery
        },
        on_behalf_of: session.owner_subject
      )
  end

  defp explain(reason) when is_binary(reason), do: reason
  defp explain(reason), do: GitHub.explain(reason)
end
