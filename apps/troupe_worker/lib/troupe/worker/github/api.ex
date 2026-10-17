defmodule Troupe.Worker.GitHub.API do
  @moduledoc """
  The calls the fix loop makes to GitHub's REST API, from this VM, with the session's
  fix-loop token (`Troupe.Worker.GitCredentials`, `access: :write`).

  Every call goes to the API URL the plane put in the credential, under the one
  repository the token was minted for: neither the session nor the activation chooses
  where a token is sent. The token goes in the request's `authorization` header and
  nowhere else: not in a URL, not in an answer, not in an error, which names GitHub's
  status and message. No redirect is followed and nothing is retried here.

  What this can ask GitHub for is exactly what the fix loop does, and nothing that merges,
  approves, deletes a branch or forces one: there is no function here for any of them.
  """

  @timeout_ms 30_000

  @typedoc "Why a call came to nothing: GitHub's status and message, or the transport's."
  @type error :: {:github, pos_integer(), String.t() | nil} | {:unreachable, String.t(), term()}

  @doc "The repository: its default branch, for a pull request whose base nobody named."
  @spec repository(map()) :: {:ok, map()} | {:error, error()}
  def repository(credential), do: call(credential, :get, "")

  @doc "Store a blob's bytes, answering its name, which must be the one git gave it."
  @spec blob(map(), binary()) :: {:ok, String.t()} | {:error, error()}
  def blob(credential, content) do
    with {:ok, %{"sha" => sha}} <-
           call(credential, :post, "/git/blobs", %{
             "content" => Base.encode64(content),
             "encoding" => "base64"
           }),
         do: {:ok, sha}
  end

  @doc "A tree: `base` with `entries` laid over it. Answers its name."
  @spec tree(map(), String.t(), [map()]) :: {:ok, String.t()} | {:error, error()}
  def tree(credential, base, entries) do
    with {:ok, %{"sha" => sha}} <-
           call(credential, :post, "/git/trees", %{"base_tree" => base, "tree" => entries}),
         do: {:ok, sha}
  end

  @doc """
  A commit of `tree` on `parent`. No author, committer or signature is given: GitHub then
  makes it the App's bot's and signs it, so it shows as verified.
  """
  @spec commit(map(), String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, error()}
  def commit(credential, message, tree, parent) do
    call(credential, :post, "/git/commits", %{
      "message" => message,
      "tree" => tree,
      "parents" => [parent]
    })
  end

  @doc "A commit as the Git data API has it: its `tree`, its `parents` and its `message`."
  @spec get_commit(map(), String.t()) :: {:ok, map()} | {:error, error()}
  def get_commit(credential, commit), do: call(credential, :get, "/git/commits/" <> commit)

  @doc "Where a branch is on GitHub, or `:none`."
  @spec branch(map(), String.t()) :: {:ok, String.t() | :none} | {:error, error()}
  def branch(credential, branch) do
    case call(credential, :get, "/git/ref/heads/" <> branch) do
      {:ok, %{"object" => %{"sha" => sha}}} -> {:ok, sha}
      {:error, {:github, 404, _message}} -> {:ok, :none}
      {:ok, _other} -> {:ok, :none}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Make a branch at `commit`; GitHub refuses one that is there already."
  @spec create_branch(map(), String.t(), String.t()) :: {:ok, map()} | {:error, error()}
  def create_branch(credential, branch, commit),
    do: call(credential, :post, "/git/refs", %{"ref" => "refs/heads/" <> branch, "sha" => commit})

  @doc """
  Move a branch to `commit`, which must have its present head among its ancestors:
  `force` is false, always, so GitHub refuses anything but a fast-forward.
  """
  @spec advance_branch(map(), String.t(), String.t()) :: {:ok, map()} | {:error, error()}
  def advance_branch(credential, branch, commit),
    do:
      call(credential, :patch, "/git/refs/heads/" <> branch, %{"sha" => commit, "force" => false})

  @doc "Open a pull request from `head` into `base`, as a draft: `draft` is true, always."
  @spec open_draft(map(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, error()}
  def open_draft(credential, title, body, head, base) do
    call(credential, :post, "/pulls", %{
      "title" => title,
      "body" => body,
      "head" => head,
      "base" => base,
      "draft" => true
    })
  end

  @doc "Comment on a pull request, as its conversation has comments."
  @spec comment(map(), pos_integer(), String.t()) :: {:ok, map()} | {:error, error()}
  def comment(credential, number, body),
    do: call(credential, :post, "/issues/#{number}/comments", %{"body" => body})

  @doc "A commit's check runs."
  @spec check_runs(map(), String.t()) :: {:ok, [map()]} | {:error, error()}
  def check_runs(credential, commit) do
    with {:ok, %{"check_runs" => runs}} when is_list(runs) <-
           call(credential, :get, "/commits/#{commit}/check-runs?per_page=100"),
         do: {:ok, runs}
  end

  @doc "A commit's statuses, as the combined status lists them."
  @spec statuses(map(), String.t()) :: {:ok, [map()]} | {:error, error()}
  def statuses(credential, commit) do
    with {:ok, %{"statuses" => statuses}} when is_list(statuses) <-
           call(credential, :get, "/commits/#{commit}/status"),
         do: {:ok, statuses}
  end

  @doc """
  Revoke the token itself, as GitHub's `DELETE /installation/token` does for the token it
  is made with, so it stops working now rather than at the end of its hour. A token GitHub
  no longer takes (`401`) is gone already, which is what was asked for.
  """
  @spec revoke(map()) :: :ok | {:error, error()}
  def revoke(%{"api_url" => api_url, "token" => token}) when is_binary(api_url) do
    url = api_url <> "/installation/token"

    case Req.request(
           method: :delete,
           url: url,
           headers: [
             {"authorization", "Bearer " <> token},
             {"accept", "application/vnd.github+json"},
             {"x-github-api-version", "2022-11-28"},
             {"user-agent", "troupe-worker"}
           ],
           redirect: false,
           retry: false,
           receive_timeout: 10_000
         ) do
      {:ok, %{status: status}} when status in [204, 401] -> :ok
      {:ok, %{status: status, body: answer}} -> {:error, {:github, status, message(answer)}}
      {:error, %{reason: reason}} -> {:error, {:unreachable, URI.parse(url).host, reason}}
      {:error, reason} -> {:error, {:unreachable, URI.parse(url).host, reason}}
    end
  end

  def revoke(_credential), do: {:error, {:unreachable, "nowhere", :no_api_url}}

  @doc "Why a call came to nothing, as a clause: no capital, no full stop."
  @spec explain(error() | term()) :: String.t()
  def explain({:github, status, nil}), do: "GitHub answered #{status}"
  def explain({:github, status, message}), do: "GitHub answered #{status}: #{message}"

  def explain({:unreachable, host, reason}),
    do: "GitHub at #{host} could not be reached (#{inspect(reason)})"

  def explain(other), do: inspect(other)

  # -- the one place a request is made -------------------------------------------

  defp call(credential, method, path, body \\ nil) do
    url = credential["api_url"] <> "/repos/" <> credential["repository"] <> path

    options =
      [
        method: method,
        url: url,
        headers: [
          {"authorization", "Bearer " <> credential["token"]},
          {"accept", "application/vnd.github+json"},
          {"x-github-api-version", "2022-11-28"},
          {"user-agent", "troupe-worker"}
        ],
        redirect: false,
        retry: false,
        receive_timeout: @timeout_ms
      ] ++ if(body, do: [json: body], else: [])

    case Req.request(options) do
      {:ok, %{status: status, body: answer}} when status in 200..299 ->
        {:ok, answer}

      {:ok, %{status: status, body: answer}} ->
        {:error, {:github, status, message(answer)}}

      {:error, %{reason: reason}} ->
        {:error, {:unreachable, URI.parse(url).host, reason}}

      {:error, reason} ->
        {:error, {:unreachable, URI.parse(url).host, reason}}
    end
  end

  defp message(%{"message" => message}) when is_binary(message), do: String.slice(message, 0, 300)
  defp message(_answer), do: nil
end
