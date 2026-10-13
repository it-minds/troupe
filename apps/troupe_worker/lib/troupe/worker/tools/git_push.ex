defmodule Troupe.Worker.Tools.GitPush do
  @moduledoc """
  `git_push`: the session's working tree, pushed to its `troupe/*` branch as one commit of
  the plane's GitHub App (`Troupe.Worker.GitHub.push/5`).

  A pod's tool, for a session created with a repository and no other. It asks like
  `shell` does unless a profile says otherwise; a profile made for unattended fixing
  marks it `auto`. The token it pushes with is the pod's, never the agent's.
  """

  @behaviour Troupe.Tool

  alias Troupe.Worker.GitHub

  @impl Troupe.Tool
  def name, do: "git_push"

  @impl Troupe.Tool
  def description do
    "Push the working tree to this session's branch on GitHub, as one commit made by the " <>
      "organisation's GitHub App. Everything `git add -A` would stage is pushed, whatever " <>
      "you committed yourself; .gitignore keeps build output out. The first push names the " <>
      "branch, which must start with `troupe/` (default `troupe/session-<id>`); every later " <>
      "push goes to the same branch, never with force. Once the session has a pull request, " <>
      "a push waits until CI on the last one has finished (read it with pr_checks), and after " <>
      "#{GitHub.red_rounds()} red CI rounds pushes are closed."
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "message" => %{
          "type" => "string",
          "description" => "The commit message: what this push changes and why."
        },
        "branch" => %{
          "type" => "string",
          "description" =>
            "The branch, under troupe/, such as troupe/issue-123-fix-login. Only for the " <>
              "first push; later ones go to the same branch."
        }
      },
      "required" => ["message"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :ask

  @impl Troupe.Tool
  def available?(session_id), do: GitHub.available?(session_id)

  @impl Troupe.Tool
  def run(args, ctx) do
    case GitHub.push(ctx.session_id, ctx.workspace.root_real, args["message"], args["branch"]) do
      {:ok, pushed} ->
        verified = if pushed.verified, do: ", signed by GitHub", else: ""

        pr =
          case pushed.pull_request do
            %{"url" => url} -> " Its pull request is #{url}; read its CI with pr_checks."
            _none -> " Open a draft pull request from it with pr_open."
          end

        {:ok,
         "Pushed #{String.slice(pushed.commit, 0, 7)} to #{pushed.branch} " <>
           "(#{pushed.files} #{if pushed.files == 1, do: "file", else: "files"} changed#{verified}): " <>
           "#{pushed.url}." <> pr}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
