defmodule Troupe.Worker.Tools.PrOpen do
  @moduledoc """
  `pr_open`: the session's pull request, from its pushed `troupe/*` branch, always as a
  draft (`Troupe.Worker.GitHub.open_pull_request/4`). A person reviews and merges it; no
  tool here can.
  """

  @behaviour Troupe.Tool

  alias Troupe.Worker.GitHub

  @impl Troupe.Tool
  def name, do: "pr_open"

  @impl Troupe.Tool
  def description do
    "Open this session's pull request on GitHub, from the branch git_push pushed into the " <>
      "branch the repository was cloned from. It is always a draft, for a person to review " <>
      "and merge; nothing you can call merges, approves or marks it ready. One per session: " <>
      "asked again, it answers the one there is."
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string", "description" => "The pull request's title."},
        "body" => %{
          "type" => "string",
          "description" => "What it changes and why, and how it was checked."
        }
      },
      "required" => ["title"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :ask

  @impl Troupe.Tool
  def available?(session_id), do: GitHub.available?(session_id)

  @impl Troupe.Tool
  def run(args, ctx) do
    case GitHub.open_pull_request(ctx.session_id, args["title"], args["body"]) do
      {:ok, %{opened: true} = pull} ->
        {:ok,
         "Opened draft pull request ##{pull.number} into #{pull.base}: #{pull.url}. Read its " <>
           "CI with pr_checks."}

      {:ok, pull} ->
        {:ok,
         "This session's pull request is ##{pull.number}: #{pull.url}. Nothing new was opened."}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
