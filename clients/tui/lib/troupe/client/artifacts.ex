defmodule Troupe.Client.Artifacts do
  @moduledoc """
  A person's artifacts on the plane (root #62), as the terminal browses them: through this
  computer's daemon and its sign-in, never the terminal's own, so `/artifacts`, `troupe
  artifacts` and the desktop app see the same and Local only is the daemon's to keep.

  The list is grouped by who can see each one, in the words the desktop app's gallery uses:
  *Everyone at* the organisation (◉), *Your teams* (◎, a team's or a profile's), *Shared with
  you* (◐, reached through a link) and *Only you* (○). The plane says which of those a row is
  (`scope`); a plane from before that is read from `visibility` and the profiles the list
  names. A version the person has not opened on this machine is *new to you*, kept in the
  state directory (`artifacts-seen.json`), never on the plane.

  `publish/3` is `/publish`'s and `troupe artifacts publish`'s: one file of this machine as a
  page (`.html`), a document (`.md`) or a file, titled by its own heading or title, else its
  name.
  """

  alias Troupe.Client.Daemon.Link
  alias Troupe.Remote.RPC

  @type audience :: :organisation | :team | :shared | :private

  @audiences [:organisation, :team, :shared, :private]

  @doc "The four audiences, in the gallery's order."
  @spec audiences() :: [audience()]
  def audiences, do: @audiences

  @doc """
  What the person may see, newest first: `%{artifacts, organisation, profiles, gallery_url}`,
  each row with `audience` and `new` beside what the plane said of it.
  """
  @spec list(map()) :: {:ok, map()} | {:error, String.t()}
  def list(params \\ %{}) do
    with {:ok, answer} <- call("artifact.list", params) do
      profiles = List.wrap(answer["profiles"])
      seen = seen()

      rows =
        for row <- List.wrap(answer["artifacts"]) do
          scope = scope(row, profiles)

          row
          |> Map.put("scope", scope)
          |> Map.put("audience", audience(scope))
          |> Map.put("new", new?(row, seen))
        end

      {:ok,
       %{
         artifacts: rows,
         organisation: answer["organisation"],
         profiles: profiles,
         gallery_url: answer["gallery_url"],
         enabled: answer["enabled"] != false
       }}
    end
  end

  @doc """
  Which of the gallery's scopes a row is in: the plane's `scope` where it says one, else
  read from `visibility`: `mine` for the person's own, `shared` for one they see only through
  a link (a profile's they are not covered by, or another's `private`).
  """
  @spec scope(map(), [String.t()]) :: String.t()
  def scope(%{"scope" => scope}, _profiles) when is_binary(scope), do: scope
  def scope(%{"mine" => true}, _profiles), do: "mine"

  def scope(%{"visibility" => "profile:" <> name = visibility}, profiles),
    do: if(name in profiles, do: visibility, else: "shared")

  def scope(%{"visibility" => "team:" <> _ = visibility}, _profiles), do: visibility
  def scope(%{"visibility" => "organisation"}, _profiles), do: "organisation"
  def scope(_row, _profiles), do: "shared"

  @doc "The audience a scope is shown under; the person's own are under who they are for."
  @spec audience(String.t(), String.t() | nil) :: audience()
  def audience(scope, visibility \\ nil)
  def audience("mine", visibility), do: audience(visibility || "private", nil)
  def audience("organisation", _visibility), do: :organisation
  def audience("team:" <> _, _visibility), do: :team
  def audience("profile:" <> _, _visibility), do: :team
  def audience("private", _visibility), do: :private
  def audience(_shared, _visibility), do: :shared

  @doc "A row's audience, its own `visibility` deciding for the person's own."
  @spec audience_of(map()) :: audience()
  def audience_of(%{"scope" => "mine"} = row), do: audience("mine", row["visibility"])
  def audience_of(%{"scope" => scope}), do: audience(scope)
  def audience_of(_row), do: :shared

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
  def scope_param("private"), do: {:ok, %{"mine" => true}, &(&1["visibility"] == "private")}

  def scope_param("team:" <> name = scope) when name != "",
    do: {:ok, %{}, &(&1["visibility"] == scope)}

  def scope_param("profile:" <> name = scope) when name != "",
    do: {:ok, %{}, &(&1["visibility"] == scope)}

  def scope_param(other),
    do:
      {:error,
       "--scope is mine, organisation, team:<name>, profile:<name>, shared or private, not #{inspect(other)}"}

  @doc "One artifact with its versions."
  @spec get(String.t()) :: {:ok, map()} | {:error, String.t()}
  def get(id), do: call("artifact.get", %{"id" => id})

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

  @doc """
  Publish one file of this machine (`/publish`, `troupe artifacts publish`) for `visibility`
  (`private`, `organisation`, `team:<name>` or `profile:<name>`). `opts`: `title` instead of
  the file's own, and `session_id`, the session it came from.
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
      {:ok, then, _} -> words(DateTime.diff(now, then), then)
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

  defp words(s, _then) when s < 60, do: "just now"
  defp words(s, _then) when s < 3600, do: "#{div(s, 60)} min ago"
  defp words(s, _then) when s < 86_400, do: "#{div(s, 3600)} h ago"
  defp words(s, _then) when s < 2 * 86_400, do: "yesterday"
  defp words(s, _then) when s < 30 * 86_400, do: "#{div(s, 86_400)} days ago"
  defp words(_s, then), do: then |> DateTime.to_date() |> Date.to_iso8601()

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
