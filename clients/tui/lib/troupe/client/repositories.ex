defmodule Troupe.Client.Repositories do
  @moduledoc """
  The GitHub repositories a session on the platform holds, in the sentences `/repo`,
  `/new --repo` and the status line say (root #1207): the one it was created on at the
  workspace's root, every other one in `<owner>/<name>`, each with its own branch and
  draft pull request. Its owner attaches one with `/repo add owner/name[@ref]`, which its
  pod clones without a restart, and takes one off with `/repo remove owner/name`. A
  session on this computer works in its own folder and holds none.
  """

  @typedoc "What `/repo` asks: the list, or to attach or take off one."
  @type verb :: :list | {:add, map()} | {:remove, String.t()}

  @doc "What `/repo` names after the command: nothing, `add owner/name[@ref]` or `remove owner/name`."
  @spec parse(String.t()) :: {:ok, verb()} | {:error, String.t()}
  def parse(args) do
    case String.split(String.trim(args)) do
      [] ->
        {:ok, :list}

      ["add", given] ->
        case read(given) do
          {:ok, repository} -> {:ok, {:add, repository}}
          :error -> {:error, not_one(given)}
        end

      ["remove", given] ->
        case read(given) do
          {:ok, %{"ref" => nil} = repository} -> {:ok, {:remove, name(repository)}}
          {:ok, _with_ref} -> {:error, "/repo remove takes owner/name, without a branch"}
          :error -> {:error, not_one(given)}
        end

      _other ->
        {:error, "/repo, /repo add owner/name[@ref] or /repo remove owner/name"}
    end
  end

  @doc """
  A repository as a person types it, `owner/name` or `owner/name@ref`, read into what the
  plane takes; `:error` for anything else.
  """
  @spec read(String.t()) :: {:ok, map()} | :error
  def read(text) when is_binary(text) do
    case Regex.run(
           ~r/\A([A-Za-z0-9][A-Za-z0-9-]{0,38})\/([A-Za-z0-9._-]{1,100})(?:@(\S+))?\z/,
           String.trim(text)
         ) do
      [_all, _owner, name | _] when name in [".", ".."] -> :error
      [_all, owner, name] -> {:ok, %{"owner" => owner, "name" => name, "ref" => nil}}
      [_all, owner, name, ref] -> {:ok, %{"owner" => owner, "name" => name, "ref" => ref}}
      nil -> :error
    end
  end

  def read(_text), do: :error

  @doc "Why something typed is not a repository."
  @spec not_one(String.t()) :: String.t()
  def not_one(given), do: "#{given} is not a repository: owner/name, or owner/name@branch"

  @doc "A repository as `session.create` and `session.repository.add` take it."
  @spec param(map()) :: String.t() | map()
  def param(%{"ref" => ref} = repository) when is_binary(ref) and ref != "",
    do: %{"owner" => repository["owner"], "name" => repository["name"], "ref" => ref}

  def param(repository), do: name(repository)

  @doc "A repository's `owner/name`."
  @spec name(map()) :: String.t()
  def name(%{"owner" => owner, "name" => name}), do: "#{owner}/#{name}"
  def name(%{"repository" => full}) when is_binary(full), do: full

  @doc "Every repository a session row says it holds: `repositories`, or an older plane's one `repository`."
  @spec of(map() | nil) :: [map()]
  def of(%{"repositories" => list}) when is_list(list), do: Enum.filter(list, &is_map/1)

  def of(%{"repository" => %{"owner" => _, "name" => _} = one} = row),
    do: [Map.merge(one, %{"path" => ".", "github" => row["github"]})]

  def of(_row), do: []

  @doc "Names in a few words: the first, and how many more. Empty for none."
  @spec summary([String.t()]) :: String.t()
  def summary([]), do: ""
  def summary([one]), do: one
  def summary([first | rest]), do: "#{first} +#{length(rest)} more"

  @doc "What `/repo` alone says of a session row."
  @spec list(map()) :: String.t()
  def list(row) do
    case of(row) do
      [] ->
        "This session holds no GitHub repository." <>
          if(owner?(row), do: " /repo add owner/name attaches one.", else: "")

      held ->
        lines = Enum.map_join(held, "; ", &line/1)
        "On GitHub: " <> lines <> "."
    end
  end

  defp line(entry) do
    "#{name(entry)} #{where(entry["path"])}" <>
      if(entry["ref"], do: ", branch #{entry["ref"]}", else: "") <> ", " <> work(entry["github"])
  end

  @doc "Where a repository's clone is in the workspace."
  @spec where(String.t() | nil) :: String.t()
  def where(path) when path in [nil, "", "."], do: "at the workspace's root"
  def where(path), do: "in #{path}/"

  defp work(%{"pull_request" => %{"number" => n}, "branch" => branch}),
    do: "draft ##{n} from #{branch}"

  defp work(%{"branch" => branch} = g) when is_binary(branch),
    do: "#{branch} at #{String.slice(g["commit"] || "", 0, 7)}"

  defp work(_github), do: "nothing pushed yet"

  @doc "The sentence for a repository just attached."
  @spec added(map(), String.t()) :: String.t()
  def added(row, full) do
    case Enum.find(of(row), &(String.downcase(name(&1)) == String.downcase(full))) do
      nil -> "#{full} is attached; its pod clones it when the session next starts."
      entry -> "#{name(entry)} is attached, cloned #{where(entry["path"])}."
    end
  end

  @doc "The sentence for a repository just taken off."
  @spec removed(String.t()) :: String.t()
  def removed(full), do: "#{full} is taken off: its directory is gone and its tokens are revoked."

  @doc "What a `forbidden` answer says."
  @spec forbidden(map() | nil) :: String.t()
  def forbidden(%{"reason" => reason}) when is_binary(reason), do: reason
  def forbidden(_data), do: "only the session's owner attaches a repository or takes one off"

  @doc "What a plane from before the methods says."
  @spec too_old() :: String.t()
  def too_old, do: "this plane does not attach repositories to a running session yet"

  @doc "Why a session on this computer holds none."
  @spec not_here() :: String.t()
  def not_here,
    do:
      "a session on this computer works in its own folder: it holds no GitHub repository of the platform's"

  @doc "The log's line for `session_repository_changed`."
  @spec changed(map()) :: String.t()
  def changed(data) do
    full = data["repository"] || "a repository"

    who =
      if is_binary(data["by_name"]) and data["by_name"] != "",
        do: " by #{data["by_name"]}",
        else: ""

    case data["action"] do
      "attached" -> "#{full} attached#{who}, cloned #{where(data["path"])}"
      "detached" -> "#{full} taken off#{who}; its directory is gone"
      "failed" -> "#{full} could not be cloned: #{data["reason"] || "the pod did not say why"}"
      _other -> "#{full} changed"
    end
  end

  @doc """
  Why a new session cannot take the repositories asked for on `profile`, or `nil`: a
  profile with no `spec.github` (`max_repositories` null) takes none, and no profile takes
  more than its cap.
  """
  @spec refused(map() | nil, [map()]) :: String.t() | nil
  def refused(_profile, []), do: nil
  def refused(nil, _asked), do: nil

  def refused(%{"name" => name} = profile, asked) do
    case profile["max_repositories"] do
      cap when is_integer(cap) and length(asked) > cap ->
        "#{name} holds at most #{cap} #{if cap == 1, do: "repository", else: "repositories"} " <>
          "a session (spec.github.maxRepositories); --repo names #{length(asked)}"

      cap when is_integer(cap) ->
        nil

      _none ->
        "#{name} takes no GitHub repository (it has no spec.github): start without --repo, " <>
          "or on a profile that has one"
    end
  end

  defp owner?(row), do: row["your_role"] == "owner"
end
