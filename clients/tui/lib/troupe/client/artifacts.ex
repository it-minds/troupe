defmodule Troupe.Client.Artifacts do
  @moduledoc """
  A person's artifacts on the plane (root #62), as the terminal browses them: through this
  computer's daemon and its sign-in, never the terminal's own, so `/artifacts`, `troupe
  artifacts` and the desktop app see the same and Local only is the daemon's to keep.

  The list is grouped by who can see each one, in the words the desktop app's gallery uses:
  *Everyone at* the organisation (◉), *Your teams* (◎, a team of theirs reads it), *Shared
  with you* (◐, reached through a link or a grant by name) and *Only you* (○), as the plane
  says each row's `scope`: the person's own are under the widest that reads them. A version the person has not opened on this
  machine is *new to you*, kept in the state directory (`artifacts-seen.json`), never on the
  plane.

  `publish/3` is `/publish`'s and `troupe artifacts publish`'s: one file of this machine as a
  page (`.html`), a document (`.md`) or a file, titled by its own heading or title, else its
  name, read by the teams named (`--team`) and the whole organisation where it says so.
  Who reads one already is its Access menu's, in the desktop app and the console: the
  terminal shares by link alone.

  An artifact may be a team's rather than one person's: every member of the owning team is
  its owner, and a person leaving changes nothing. A row says so in `owner_team`, and
  `may_transfer` whether this person may hand it to a team they are in or take it back
  (`transfer/2`). A publication is the person's unless they say `owner: "team"`, the one
  team named; `owner/1` is the words a row's owner is shown by.
  """

  alias Troupe.Client.Daemon.Link
  alias Troupe.Protocol.Words
  alias Troupe.Remote.RPC

  @type audience :: :organisation | :team | :shared | :private

  @audiences [:organisation, :team, :shared, :private]

  @doc "The four audiences, in the gallery's order."
  @spec audiences() :: [audience()]
  def audiences, do: @audiences

  @doc """
  What the person may see, newest first: `%{artifacts, organisation, teams, gallery_url}`,
  each row with `new` beside what the plane said of it; `teams` are the person's own, by
  name, which may read what they publish.
  """
  @spec list(map()) :: {:ok, map()} | {:error, String.t()}
  def list(params \\ %{}) do
    with {:ok, answer} <- call("artifact.list", params) do
      teams = List.wrap(answer["teams"])
      seen = seen()
      rows = for row <- List.wrap(answer["artifacts"]), do: Map.put(row, "new", new?(row, seen))

      {:ok,
       %{
         artifacts: rows,
         organisation: answer["organisation"],
         teams: teams,
         gallery_url: answer["gallery_url"],
         enabled: answer["enabled"] != false
       }}
    end
  end

  @doc "The audience a scope is shown under."
  @spec audience(String.t()) :: audience()
  def audience("organisation"), do: :organisation
  def audience("team:" <> _), do: :team
  def audience("private"), do: :private
  def audience(_shared), do: :shared

  @doc """
  A row's audience, as its `scope` says: the person's own that others read (`mine`) is under
  the widest that does, the organisation, else its teams, else only them.
  """
  @spec audience_of(map()) :: audience()
  def audience_of(%{"scope" => "mine"} = row) do
    cond do
      row["visibility"] == "organisation" or row["organisation"] == true -> :organisation
      List.wrap(row["teams"]) != [] -> :team
      true -> :private
    end
  end

  def audience_of(%{"scope" => scope}) when is_binary(scope), do: audience(scope)
  def audience_of(_row), do: :shared

  @doc """
  Who reads a row beside its owner, in words: "the core and billing teams", "the whole
  organisation and the core team"; nil where nobody but its owner does, by team or as the
  organisation.
  """
  @spec readers(map()) :: String.t() | nil
  def readers(row) do
    teams =
      case List.wrap(row["teams"]) do
        [] -> nil
        [one] -> "the #{one} team"
        many -> "the #{Words.and_list(many)} teams"
      end

    org = if row["visibility"] == "organisation", do: "the whole organisation"

    case Enum.reject([org, teams], &is_nil/1) do
      [] -> nil
      parts -> Words.and_list(parts)
    end
  end

  @doc "An audience's glyph and its name, as the desktop app's gallery says them."
  @spec label(audience(), String.t() | nil) :: {String.t(), String.t()}
  def label(audience, organisation \\ nil)
  def label(:organisation, org) when is_binary(org) and org != "", do: {"◉", "Everyone at " <> org}
  def label(:organisation, _org), do: {"◉", "Everyone at your organisation"}
  def label(:team, _org), do: {"◎", "Your teams"}
  def label(:shared, _org), do: {"◐", "Shared with you"}
  def label(:private, _org), do: {"○", "Only you"}

  @doc "What `--scope` names, to the audience it lists; `mine` is every one of the person's own."
  @spec scope_param(String.t()) :: {:ok, map(), (map() -> boolean())} | {:error, String.t()}
  def scope_param("all"), do: {:ok, %{}, fn _ -> true end}
  def scope_param("mine"), do: {:ok, %{"mine" => true}, fn _ -> true end}
  def scope_param("shared"), do: {:ok, %{"shared" => true}, fn _ -> true end}
  def scope_param("organisation"), do: {:ok, %{}, &(audience_of(&1) == :organisation)}
  def scope_param("private"), do: {:ok, %{"mine" => true}, &(audience_of(&1) == :private)}

  def scope_param("team:" <> name) when name != "",
    do: {:ok, %{"team" => name}, &(name in List.wrap(&1["teams"]))}

  def scope_param(other),
    do:
      {:error,
       "--scope is mine, organisation, team:<name>, shared or private, not #{inspect(other)}"}

  @doc "One artifact with its versions."
  @spec get(String.t()) :: {:ok, map()} | {:error, String.t()}
  def get(id), do: call("artifact.get", %{"id" => id})

  @doc """
  Whose a row is, in words: `team finance` for a team's (whoever is looking, since every
  member owns it), `you` for the person's own, else who published it.
  """
  @spec owner(map()) :: String.t()
  def owner(%{"owner_team" => team}) when is_binary(team) and team != "", do: "team " <> team
  def owner(%{"mine" => true}), do: "you"
  def owner(%{"owner" => %{"display_name" => name}}) when is_binary(name), do: name
  def owner(%{"owner" => %{"subject" => subject}}) when is_binary(subject), do: subject
  def owner(_row), do: "someone"

  @doc """
  Hand an artifact to a team the person is in (`to` is `team:<name>`), or take a team's
  back (`me`, an admin of that team's or a platform admin's to do): the artifact as it now
  is. Whom it may go to is the plane's to decide; `may_transfer` on a row says whether it
  would be allowed at all.
  """
  @spec transfer(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def transfer(id, "team:" <> name = to) when name != "", do: transfer_call(id, to)
  def transfer(id, "me"), do: transfer_call(id, "me")
  def transfer(_id, to), do: {:error, "--to is team:<name> or me, not #{inspect(to)}"}

  defp transfer_call(id, to),
    do: call("artifact.transfer", %{"id" => id, "to" => to, "command_id" => RPC.command_id()})

  @doc """
  The one-time address that opens it (a version of it, where one is named) on the artifacts
  host, as the console's Open asks it; good for a minute, and spent by the browser.
  """
  @spec open(String.t(), pos_integer() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def open(id, version \\ nil) do
    params = if version, do: %{"id" => id, "version" => version}, else: %{"id" => id}

    case call("artifact.open", params) do
      {:ok, %{"url" => url}} -> {:ok, url}
      {:ok, _other} -> {:error, "the plane gave no address to open it at"}
      error -> error
    end
  end

  @doc "One text file of a version (its entry where no path is named), as the plane reads it."
  @spec read(String.t(), pos_integer() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def read(id, version \\ nil, path \\ nil) do
    params =
      %{"id" => id}
      |> then(&if(version, do: Map.put(&1, "version", version), else: &1))
      |> then(&if(path, do: Map.put(&1, "path", path), else: &1))

    call("artifact.read", params)
  end

  @doc "A view link to one of the person's own: the address, shown once."
  @spec link(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def link(id) do
    case call("artifact.share", %{"id" => id, "role" => "view", "command_id" => RPC.command_id()}) do
      {:ok, %{"url" => url}} -> {:ok, url}
      {:ok, _other} -> {:error, "the plane made no link"}
      error -> error
    end
  end

  @usage "<path> [private | organisation] [--team <name>]... [--owner me | team]"

  @doc """
  What `/publish` takes after its name, read into `{path, visibility, opts}`: a path, then
  in any order `private` or `organisation` (only the person and those the teams named, or
  every signed-in person too), `--team <name>` once for each team that reads it, and
  `--owner team` to make it the one team's named. Anything else is the usage.
  """
  @spec publish_args([String.t()]) ::
          {:ok, String.t(), String.t(), keyword()} | {:error, String.t()}
  def publish_args([path | rest]) when path != "", do: publish_args(rest, {path, "private", []})
  def publish_args(_words), do: {:error, "usage: /publish " <> @usage}

  defp publish_args([], {path, visibility, opts}),
    do: {:ok, path, visibility, Keyword.update(opts, :teams, [], &Enum.reverse/1)}

  defp publish_args([visibility | rest], {path, _v, opts})
       when visibility in ["private", "organisation"],
       do: publish_args(rest, {path, visibility, opts})

  defp publish_args(["--team", team | rest], {path, visibility, opts}) when team != "",
    do: publish_args(rest, {path, visibility, Keyword.update(opts, :teams, [team], &[team | &1])})

  defp publish_args(["--owner", owner | rest], {path, visibility, opts})
       when owner in ["me", "team"],
       do: publish_args(rest, {path, visibility, Keyword.put(opts, :owner, owner)})

  defp publish_args([other | _rest], _acc),
    do: {:error, "/publish takes #{inspect(other)} nowhere; usage: /publish " <> @usage}

  @doc "`/publish`'s usage, after its name."
  @spec publish_usage() :: String.t()
  def publish_usage, do: @usage

  @doc """
  Publish one file of this machine (`/publish`, `troupe artifacts publish`), read by the
  person and, with `visibility` `organisation`, every signed-in person. `opts`: `teams`, the
  teams that read it besides; `title` instead of the file's own; `session_id`, the session it
  came from; and `owner`, `"me"` or `"team"` (the one team in `teams`), whose it is, the
  person's where nothing is said.
  """
  @spec publish(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def publish(path, visibility, opts \\ []) do
    local = Path.expand(path)
    name = Path.basename(local)

    case File.read(local) do
      {:ok, content} ->
        kind = kind(name)

        %{
          "title" => opts[:title] || title(kind, content, name),
          "kind" => kind,
          "visibility" => visibility,
          "files" => [%{"path" => name, "bytes" => Base.encode64(content)}]
        }
        |> then(&if(opts[:session_id], do: Map.put(&1, "session_id", opts[:session_id]), else: &1))
        |> then(
          &if(opts[:teams] not in [nil, []], do: Map.put(&1, "teams", opts[:teams]), else: &1)
        )
        |> then(
          &if(opts[:owner] in ["me", "team"], do: Map.put(&1, "owner", opts[:owner]), else: &1)
        )
        |> Map.put("command_id", RPC.command_id())
        |> then(&call("artifact.publish", &1))

      {:error, reason} ->
        {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc "A file's kind, by its name: a page, a Markdown document or a file."
  @spec kind(String.t()) :: String.t()
  def kind(name) do
    case name |> Path.extname() |> String.downcase() do
      ext when ext in [".html", ".htm"] -> "html"
      ext when ext in [".md", ".markdown"] -> "markdown"
      _other -> "file"
    end
  end

  defp title(kind, content, name) do
    found =
      case kind do
        "html" ->
          Regex.run(~r/<title[^>]*>\s*([^<]+?)\s*<\/title>/i, content, capture: :all_but_first)

        "markdown" ->
          Regex.run(~r/^#\s+(.+?)\s*$/m, content, capture: :all_but_first)

        "file" ->
          nil
      end

    case found do
      [title] -> if String.valid?(title), do: title, else: name
      _none -> name
    end
  end

  @doc "When, as a person says it: `just now`, `3 min ago`, `2 h ago`, `yesterday`, `4 days ago`, or the date."
  @spec ago(String.t() | nil, DateTime.t()) :: String.t()
  def ago(at, now \\ DateTime.utc_now())

  def ago(at, now) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, then, _} -> Words.ago(then, now)
      _ -> naive(at, now)
    end
  end

  def ago(_at, _now), do: ""

  # A timestamp with no zone, as Ecto writes a `naive_datetime`, is the plane's UTC.
  defp naive(at, now) do
    case NaiveDateTime.from_iso8601(at) do
      {:ok, naive} -> ago(DateTime.to_iso8601(DateTime.from_naive!(naive, "Etc/UTC")), now)
      _ -> ""
    end
  end

  ## New to you

  @doc "Whether a version of the row is one the person has not opened here; their own never is."
  @spec new?(map(), map()) :: boolean()
  def new?(%{"mine" => true}, _seen), do: false

  def new?(%{"id" => id, "version" => version}, seen) when is_integer(version),
    do: Map.get(seen, id, 0) < version

  def new?(_row, _seen), do: false

  @doc "Remember that the person opened version `version` of `id` on this machine."
  @spec seen(String.t(), pos_integer()) :: :ok
  def seen(id, version) when is_binary(id) and is_integer(version) do
    held = seen()

    if Map.get(held, id, 0) < version do
      path = seen_path()
      _ = File.mkdir_p(Path.dirname(path))
      _ = File.write(path, Jason.encode!(Map.put(held, id, version)))
    end

    :ok
  end

  def seen(_id, _version), do: :ok

  @doc "Every artifact's highest version opened on this machine, by id."
  @spec seen() :: %{String.t() => pos_integer()}
  def seen do
    with {:ok, text} <- File.read(seen_path()),
         {:ok, %{} = held} <- Jason.decode(text) do
      for {id, n} <- held, is_integer(n), into: %{}, do: {id, n}
    else
      _none -> %{}
    end
  end

  defp seen_path, do: Path.join(Troupe.Paths.state_dir(), "artifacts-seen.json")

  ## The daemon

  defp call(method, params) do
    case Link.call(method, params) do
      {:ok, answer} -> {:ok, answer}
      {:error, reason} -> {:error, reason(reason)}
    end
  end

  @doc "The daemon's sentence, or the plane's, whichever way a refusal came."
  @spec reason(term()) :: String.t()
  def reason(%{"data" => %{"reason" => reason}}) when is_binary(reason), do: reason
  def reason(%{data: %{"reason" => reason}}) when is_binary(reason), do: reason
  def reason(%{data: %{reason: reason}}) when is_binary(reason), do: reason
  def reason(%{message: message}) when is_binary(message), do: message
  # The daemon's link says the error's code before its sentence: the sentence is enough.
  def reason(reason) when is_binary(reason),
    do: String.replace(reason, ~r/^(unavailable|invalid_params|forbidden|not_found): /, "")

  def reason(reason), do: inspect(reason)
end
