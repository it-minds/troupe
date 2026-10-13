defmodule Troupe.Worker.Session.Clone do
  @moduledoc """
  A session's repository, cloned into its workspace on the activation that finds none.

  A session created with a `repository` starts from it: the first activation, whose
  restore found no archive and left an empty directory, clones the repository there.
  Every later activation restores the archive as before, so a clone happens once per
  session, and what the session did to the tree is what comes back.

  ## The clone

  Shallow, one branch, no tags: the `ref` the session was created with, or the
  repository's default branch. The URL is the plane's, from its answer to
  `git.credential`, never the activation's or the session's.

  The git is the pod's own, run through `Troupe.Reaper` like every command here, so on a
  worker it is in the sandbox over the workspace alone. It is given the token in its own
  environment and a credential helper for the one Git host on its command line, which
  answers git's request for a password with it and nothing else; the system's and the
  user's git configuration are not read, hooks and the filesystem monitor are off, the
  only protocol is the URL's, and a redirect is not followed. None of that is written into
  the clone, so the workspace's `.git/config` names the remote and no credential, and an
  archive of the workspace holds none.

  What git says when it fails is returned with the token taken out, and logged so too.

  The commit the clone checked out is told to the plane (`github.record`, `base`), before
  the agent has run anything: it is what the session's first push builds on
  (`Troupe.Worker.GitHub`).
  """

  alias Troupe.Reaper
  alias Troupe.Worker.{GitCredentials, GitHub}
  alias Troupe.Worker.GitHub.Tree

  require Logger

  @timeout_ms 300_000

  # git's request for a credential, answered from the variable this git alone was given.
  # Only `get`: there is nothing to `store`, and an `erase` has nothing here to erase.
  @helper ~S|!f() { if [ "$1" = get ]; then printf 'username=%s\npassword=%s\n' "$TROUPE_GIT_USERNAME" "$TROUPE_GIT_TOKEN"; fi; }; f|

  @doc """
  Clone the session's repository into `root` if this activation found nothing there:
  `tree` is what `Restore.workspace/2` answered, and `opts` the activation's, where the
  plane put `:repository`. `:ok` when there is nothing to do.
  """
  @spec ensure(String.t(), Path.t(), map(), keyword()) :: :ok | {:error, term()}
  def ensure(session_id, root, tree, opts) do
    case {Keyword.get(opts, :repository), tree} do
      {%{} = repository, %{restored: false}} ->
        if empty?(root), do: clone(session_id, root, repository, opts), else: :ok

      _nothing_to_clone ->
        :ok
    end
  end

  defp empty?(root), do: File.ls(root) in [{:ok, []}, {:error, :enoent}]

  defp clone(session_id, root, repository, opts) do
    named = "#{repository["owner"]}/#{repository["name"]}"

    with {:ok, credential} <- GitCredentials.credential(session_id, opts),
         :ok <- run(root, credential) do
      Logger.info(
        "troupe worker: cloned #{credential["repository"]}" <>
          if(credential["ref"], do: " at #{credential["ref"]}", else: "") <>
          " for #{session_id}"
      )

      record_base(session_id, root, opts)
      :ok
    else
      {:error, reason} ->
        Logger.error(
          "troupe worker: could not clone #{named} for #{session_id}: #{inspect(reason)}"
        )

        {:error, {:clone_failed, named, reason}}
    end
  end

  # The commit the clone checked out is what the session's first push builds on, so the
  # plane keeps it: read now, before the agent has run anything in the tree. A plane that
  # cannot take it leaves the session able to work and unable to push, which its first
  # push says.
  defp record_base(session_id, root, opts) do
    with {:ok, base} <- Tree.head(root),
         {:ok, _record} <- GitHub.record(session_id, %{"base" => base}, opts) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "troupe worker: the plane does not know where #{session_id}'s clone started: #{reason}"
        )
    end
  end

  defp run(root, credential) do
    File.mkdir_p!(root)
    token = credential["token"]

    case Reaper.run(root, argv(credential), env: env(credential), timeout_ms: @timeout_ms) do
      {:ok, _output, 0} ->
        :ok

      {:ok, output, :timeout} ->
        {:error, {:timeout, redact(output, token)}}

      {:ok, output, status} ->
        {:error, {:git, status, output |> redact(token) |> String.trim()}}

      {:error, reason} ->
        {:error, {:not_run, Reaper.explain(reason)}}
    end
  end

  @doc false
  # What the clone runs, for the test that reads it: never the token, which is in the
  # environment `env/1` gives this one process.
  @spec argv(map()) :: [String.t()]
  def argv(credential) do
    base = base_url(credential["url"])

    [
      "git",
      "-c",
      "credential.helper=",
      "-c",
      "credential.#{base}.helper=#{@helper}",
      "-c",
      "credential.interactive=false",
      "-c",
      "http.followRedirects=false",
      "-c",
      "core.hooksPath=/dev/null/hooks",
      "-c",
      "core.fsmonitor=false",
      "-c",
      "submodule.recurse=false",
      "-c",
      "transfer.fsckObjects=true",
      "clone",
      "--depth=1",
      "--single-branch",
      "--no-tags"
    ] ++ branch(credential["ref"]) ++ ["--", credential["url"], "."]
  end

  defp branch(nil), do: []
  defp branch(ref), do: ["--branch", ref]

  # The token and the username for the helper, git told not to prompt and to read no
  # configuration but its command line's, and only the URL's own protocol allowed. Every
  # other `GIT_*` the pod was started with is taken away.
  defp env(credential) do
    set = [
      {"TROUPE_GIT_TOKEN", credential["token"]},
      {"TROUPE_GIT_USERNAME", credential["username"] || "x-access-token"},
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_ALLOW_PROTOCOL", URI.parse(credential["url"]).scheme}
    ]

    names = MapSet.new(set, fn {name, _} -> name end)

    unset =
      for {name, _} <- System.get_env(),
          String.starts_with?(name, "GIT_") or name in ["SSH_ASKPASS"],
          not MapSet.member?(names, name),
          do: {name, nil}

    unset ++ set
  end

  defp base_url(url) do
    uri = URI.parse(url)
    URI.to_string(%URI{scheme: uri.scheme, host: uri.host, port: uri.port})
  end

  defp redact(text, token) when is_binary(token) and token != "",
    do: String.replace(text, token, "[redacted]")

  defp redact(text, _token), do: text
end
