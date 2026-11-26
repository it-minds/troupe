defmodule Troupe.Worker.Session.Repositories do
  @moduledoc """
  The GitHub repositories a pod session holds, each a clone in its workspace (#1207).

  The plane keeps the list on the session's row and hands it to every activation, each
  entry `{owner, name, ref, path}`: the repository the session was created on at the
  workspace's root (`path: "."`, cloned before the tree starts, `Troupe.Worker.Session.
  Clone.ensure/4`), every other one in a directory of its own, `<owner>/<name>`. Each has
  its own token, its own record on the plane and its own lock (`Troupe.Worker.GitHub`).

  ## At an activation

  Once the tree is up (`settle/3`): a repository whose directory is missing is cloned into
  it, as one attached while the session slept is; a directory the session's log says it
  held and the list no longer has is deleted, as one taken off while it slept is; the
  workspace root's clone is told to leave the others' directories out of what it stages
  (`.git/info/exclude`), so a push from it never carries another repository. Otherwise the
  archive restored them, and they are as the session left them: a clone happens once.

  ## While it runs

  `attach/4` and `detach/4`, for `session.repository.add` and `.remove`: a clone into its
  directory without a restart, and a directory deleted with its tokens revoked, refused
  while a push, a pull request or a CI read on that repository is going.

  ## What the agent is told

  Every change is a `session_repository_changed` the root writes, carrying the whole list
  as it now is, and its turn context's `configuration` section says what it holds and what
  moved (`Troupe.set_repositories/3`). A clone that fails at an activation is said there
  too, and the session goes on with the rest.
  """

  alias Troupe.Protocol.Event.Actor
  alias Troupe.Worker.{GitCredentials, GitHub}
  alias Troupe.Worker.Session.Clone

  require Logger

  @keys ~w(owner name ref path attached_by)

  # The block in the root clone's `.git/info/exclude` that is this module's, rewritten
  # whole each time, so a line the agent wrote there is left alone.
  @begin "# troupe: the session's other repositories, each a clone of its own"
  @finish "# troupe: end"

  @doc """
  The repositories an activation's params carry, each with its directory: `repositories`,
  or a plane from before the list's one `repository`, at the workspace's root. `nil` for
  none.
  """
  @spec of_activation(map()) :: [map()] | nil
  def of_activation(%{"repositories" => [_ | _] = list}), do: Enum.map(list, &entry/1)

  def of_activation(%{"repository" => %{} = one}),
    do: [one |> entry() |> Map.put("path", one["path"] || ".")]

  def of_activation(_params), do: nil

  @doc "The repositories in an activation's options, read as `of_activation/1` reads params."
  @spec of_opts(keyword()) :: [map()]
  def of_opts(opts) do
    case {Keyword.get(opts, :repositories), Keyword.get(opts, :repository)} do
      {[_ | _] = list, _one} -> list
      {_none, %{} = one} -> of_activation(%{"repository" => one})
      _none -> []
    end
  end

  defp entry(%{} = given) do
    given = Map.new(given, fn {key, value} -> {to_string(key), value} end)
    Map.put(Map.take(given, @keys), "path", given["path"] || ".")
  end

  @doc """
  Bring the workspace at `root` to the list an activation carries, once the tree is up:
  clone what is missing, delete what the log held and the list does not, exclude the
  others from the root's clone, hold the list for the tools, and tell the root what moved.
  """
  @spec settle(String.t(), Path.t(), [map()]) :: :ok
  def settle(session_id, root, entries) do
    known = Troupe.repositories(session_id) || []

    {held, changes} =
      Enum.reduce(entries, {[], []}, fn entry, {held, changes} ->
        case Clone.into(session_id, root, entry, []) do
          {:ok, _cloned_or_there} ->
            {held ++ [entry], changes ++ attached_change(entry, known)}

          {:error, reason} ->
            {held, changes ++ [change("failed", entry, %{"reason" => failure(reason)})]}
        end
      end)

    gone =
      for said <- known,
          not Enum.any?(held, &(GitHub.full(&1) == said["repository"])),
          not Enum.any?(changes, &(&1["repository"] == said["repository"])) do
        remove_directory(root, said["path"])
        change("detached", %{"path" => said["path"]}, %{"repository" => said["repository"]})
      end

    exclude(root, held)
    GitHub.hold(session_id, held)
    Enum.each(changes ++ gone, &tell(session_id, &1, held, nil))
    :ok
  end

  defp attached_change(entry, known) do
    if Enum.any?(known, &(&1["repository"] == GitHub.full(entry))),
      do: [],
      else: [change("attached", entry, by(entry["attached_by"], nil))]
  end

  @doc """
  Clone `entry` into its directory of the running session's workspace at `root`, as `by`
  (`{subject, name}`) asked, and hold it beside the others. Answers why it could not.
  """
  @spec attach(String.t(), Path.t(), map(), {String.t() | nil, String.t() | nil}) ::
          :ok | {:error, String.t()}
  def attach(session_id, root, entry, {subject, name}) do
    entry = entry(entry)

    case Clone.into(session_id, root, entry, []) do
      {:ok, _cloned_or_there} ->
        held = without(GitHub.holding(session_id), entry) ++ [entry]
        exclude(root, held)
        GitHub.hold(session_id, held)
        tell(session_id, change("attached", entry, by(subject, name)), held, actor(subject, name))
        :ok

      {:error, reason} ->
        {:error, failure(reason)}
    end
  end

  @doc """
  Take `entry` off the running session: its directory deleted (the root clone's `.git`
  alone, for the one at the workspace's root, whose files stay the session's), its tokens
  dropped and revoked, and the root told. `{:error, :busy}` while a push, a pull request or
  a CI read on it is going.
  """
  @spec detach(String.t(), Path.t(), map(), {String.t() | nil, String.t() | nil}) ::
          :ok | {:error, :busy}
  def detach(session_id, root, entry, {subject, name}) do
    entry = entry(entry)

    GitHub.unless_busy(session_id, entry, fn ->
      remove_directory(root, entry["path"])
      GitCredentials.forget(session_id, repository: GitHub.full(entry))
      held = without(GitHub.holding(session_id), entry)
      exclude(root, held)
      GitHub.hold(session_id, held)
      tell(session_id, change("detached", entry, by(subject, name)), held, actor(subject, name))
      :ok
    end)
  end

  defp without(held, entry), do: Enum.reject(held, &(GitHub.full(&1) == GitHub.full(entry)))

  # The directory is the workspace's own, by the plane's path for it, which is never one
  # that climbs out: `<owner>/<name>` of names GitHub allows, or the root.
  defp remove_directory(root, path) when path in [nil, "."],
    do: File.rm_rf(Path.join(root, ".git"))

  defp remove_directory(root, path) do
    dir = Path.expand(path, root)

    if String.starts_with?(dir, Path.expand(root) <> "/") do
      File.rm_rf(dir)
      parent = Path.dirname(dir)
      if parent != Path.expand(root) and File.ls(parent) == {:ok, []}, do: File.rmdir(parent)
    end

    :ok
  end

  # The root clone leaves every other repository's directory out of what `git add -A`
  # stages, so neither the agent's own git nor a push sees another clone in its tree.
  defp exclude(root, held) do
    info = Path.join([root, ".git", "info"])

    if File.dir?(Path.join(root, ".git")) and Enum.any?(held, &(&1["path"] in [nil, "."])) do
      others = for entry <- held, entry["path"] not in [nil, "."], do: "/#{entry["path"]}/"
      file = Path.join(info, "exclude")
      kept = file |> File.read() |> elem_or("") |> without_block()

      block =
        if others == [], do: "", else: Enum.join([@begin | others] ++ [@finish], "\n") <> "\n"

      File.mkdir_p!(info)
      File.write!(file, kept <> block)
    end

    :ok
  end

  defp elem_or({:ok, text}, _default), do: text
  defp elem_or(_error, default), do: default

  defp without_block(text) do
    text
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn
      @begin, {kept, _in} -> {kept, true}
      @finish, {kept, true} -> {kept, false}
      _line, {kept, true} -> {kept, true}
      line, {kept, false} -> {kept ++ [line], false}
    end)
    |> elem(0)
    |> Enum.join("\n")
    |> String.trim_trailing()
    |> then(&if(&1 == "", do: "", else: &1 <> "\n"))
  end

  defp change(action, entry, extra) do
    %{
      "action" => action,
      "repository" => extra["repository"] || GitHub.full(entry),
      "path" => entry["path"]
    }
    |> then(&if(entry["ref"], do: Map.put(&1, "ref", entry["ref"]), else: &1))
    |> Map.merge(Map.drop(extra, ["repository"]))
  end

  defp by(nil, _name), do: %{}
  defp by(subject, nil), do: %{"by" => subject}
  defp by(subject, name), do: %{"by" => subject, "by_name" => name}

  defp actor(nil, _name), do: nil
  defp actor(subject, name), do: Actor.user(subject, name)

  defp tell(session_id, change, held, actor) do
    listed =
      for entry <- held do
        %{"repository" => GitHub.full(entry), "path" => entry["path"], "ref" => entry["ref"]}
      end

    case Troupe.set_repositories(session_id, Map.put(change, "repositories", listed), actor) do
      :ok ->
        :ok

      {:error, :no_session} ->
        Logger.warning(
          "troupe worker: #{session_id}'s tree is not up to be told #{change["repository"]} " <>
            "was #{change["action"]}"
        )
    end
  end

  defp failure({:clone_failed, _named, {:git, _status, output}}), do: "git said: #{output}"

  defp failure({:clone_failed, _named, {:refused, _message, reason}}) when is_binary(reason),
    do: reason

  defp failure({:clone_failed, _named, reason}), do: inspect(reason)
end
