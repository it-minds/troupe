defmodule Troupe.Worker.Tools.PrComment do
  @moduledoc """
  `pr_comment`: a comment on the session's own pull request, as the plane's GitHub App
  (`Troupe.Worker.GitHub.comment/3`). It cannot comment anywhere else, and a comment is
  not a review: it approves nothing.
  """

  @behaviour Troupe.Tool

  alias Troupe.Worker.GitHub

  @impl Troupe.Tool
  def name, do: "pr_comment"

  @impl Troupe.Tool
  def description do
    "Comment on this session's own pull request on GitHub. Use it to say what you tried and " <>
      "what still fails when you stop, or anything a reviewer should know. It comments on " <>
      "nothing else."
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "body" => %{"type" => "string", "description" => "The comment, in Markdown."}
      },
      "required" => ["body"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :ask

  @impl Troupe.Tool
  def available?(session_id), do: GitHub.available?(session_id)

  @impl Troupe.Tool
  def run(args, ctx) do
    case GitHub.comment(ctx.session_id, args["body"]) do
      {:ok, url} -> {:ok, "Commented: #{url}"}
      {:error, reason} -> {:error, reason}
    end
  end
end
