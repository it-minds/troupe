defmodule Troupe.Tools.OnboardWrite do
  @moduledoc """
  Writes one of Troupe's own files from another tool's, recording where it came from: the
  librarian's way of onboarding (issue #516, Decision 823).

  Confined as `remember` is (Decision 649): the model names a file under one of two roots,
  the workspace's `.troupe/` or the person's config directory, of a kind Troupe reads
  there, and `Troupe.Onboard.write/3` refuses anything else, judged where it really is.
  Unlike `remember` it asks first: what it writes decides what runs (an agent's tools and
  permissions, a command's prompt, an MCP server), so the person sees each file; into the
  config directory it asks even under `auto_approve` or a profile's `auto` (`must_ask?/1`).
  And it is offered only to a profile that names it (`Troupe.Tools`), not to every agent
  with every tool.

  The source's hash is the tool's to take, not the model's to say: it reads the file the
  content was made from, so `troupe instructions check` can tell when that file changes.
  """

  @behaviour Troupe.Tool

  alias Troupe.{Onboard, Tool}
  alias Troupe.Session.Log

  @impl Troupe.Tool
  def name, do: "onboard_write"

  @impl Troupe.Tool
  def description do
    """
    Write one of Troupe's own files from another tool's configuration file, recording where it came from. Use it to onboard what another coding tool keeps (a Claude Code subagent, an opencode command) into Troupe's own files, once, so sessions read Troupe's file from then on.

    `target: "repo"` writes under this repository's `.troupe/`, from a file in the repository; `target: "user"` writes under the person's own Troupe config directory, from a file in their home directory. `path` is relative to that directory and is one of: `agents/<name>.md`, `commands/<name>.md`, `skills/<name>/<file>`, `workflows/<name>.json`, `mcp.json`, or (user only) `AGENTS.md`. `source` is the file you made the content from: relative to the workspace for repo, starting `~/` for user. `content` is the whole file as Troupe should read it.

    The tool records the source's hash beside what it writes, so a later change to the source is reported. It writes nowhere else, and the person approves each file.
    """
    |> String.trim()
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "target" => %{"type" => "string", "enum" => ["repo", "user"]},
        "path" => %{
          "type" => "string",
          "description" => "Relative to .troupe/ (repo) or the config directory (user)."
        },
        "source" => %{
          "type" => "string",
          "description" => "The other tool's file: relative to the workspace, or ~/... for user."
        },
        "content" => %{"type" => "string", "description" => "The whole file to write."}
      },
      "required" => ["target", "path", "source", "content"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :ask

  # The person's config directory is read by every session, and what lands there runs
  # without a trust question (an MCP server, an agent: Decision 700), so a write there is
  # asked about whatever the profile grants or `auto_approve` says (Decision 823).
  @impl Troupe.Tool
  def must_ask?(%{"target" => "user"}), do: true
  def must_ask?(_args), do: false

  @impl Troupe.Tool
  def run(args, ctx) do
    workspace = ctx.workspace.root_real

    with :ok <- local(ctx),
         {:ok, target} <- target(args),
         :ok <- own(target, ctx),
         {:ok, path} <- Tool.fetch_string(args, "path"),
         {:ok, source} <- Tool.fetch_string(args, "source"),
         {:ok, content} <- Tool.fetch_string(args, "content"),
         :ok <- Onboard.check_path(target, path),
         {:ok, hash} <- Onboard.hash_source(target, source, workspace),
         proposal = %{
           target: target,
           path: path,
           content: content,
           source: source,
           source_hash: hash,
           notes: []
         },
         {:ok, written} <- Onboard.write(proposal, workspace) do
      record(ctx, proposal, written)

      {:ok,
       "#{written.action} #{written.shown}, imported from #{source} " <>
         "(sha256 #{binary_part(hash, 0, 12)})"}
    end
  end

  # A pod's agents and skills are the bundle's; onboarding writes a person's own files, on
  # their own machine.
  defp local(%{bundle: nil}), do: :ok

  defp local(_ctx),
    do:
      {:error,
       "onboard_write runs on the person's own machine; this session runs on a pod, " <>
         "where the bundle's files are the ones that count"}

  defp target(%{"target" => "repo"}), do: {:ok, :repo}
  defp target(%{"target" => "user"}), do: {:ok, :user}

  defp target(%{"target" => other}),
    do: {:error, {:invalid_args, "target must be \"repo\" or \"user\", got #{inspect(other)}"}}

  defp target(_args), do: {:error, {:invalid_args, "missing required argument \"target\""}}

  # An agent the workspace defines (`.troupe/agents/`) writes the workspace's files, not the
  # person's: a clone must not reach the config directory every session reads, whatever
  # permission its own agent file gives itself.
  defp own(:user, %{definition: %{source: :project}}),
    do:
      {:error,
       "this agent is the workspace's own (.troupe/agents/), and may not write your config " <>
         "directory: use target \"repo\""}

  defp own(_target, _ctx), do: :ok

  defp record(ctx, proposal, written) do
    Log.append(ctx.session_id, ctx.agent_path, :onboarded, %{
      "target" => Atom.to_string(proposal.target),
      "path" => proposal.path,
      "file" => written.shown,
      "source" => proposal.source,
      "source_hash" => proposal.source_hash,
      "action" => Atom.to_string(written.action)
    })

    :ok
  end
end
