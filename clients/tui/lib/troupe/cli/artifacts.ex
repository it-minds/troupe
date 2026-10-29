defmodule Troupe.CLI.Artifacts do
  @moduledoc """
  `troupe artifacts` (root #62): the person's artifacts on the plane from the command line,
  through this machine's daemon and its sign-in, as `/artifacts` reaches them.

      troupe artifacts list [--scope mine|organisation|team:<name>|profile:<name>|shared|private] [--json]
      troupe artifacts open ID [--version N]      the browser, through the plane's one-time address
      troupe artifacts show ID [--version N]      its text on standard output (a Markdown one's source)
      troupe artifacts publish FILE [--to SCOPE] [--title TITLE] [--owner me|team]
                                                  as /publish; Only you when no --to; a team's
                                                  when --to names a team, unless --owner me
      troupe artifacts transfer ID --to team:NAME|me   hand one of yours to a team you are in,
                                                  or take a team's back (its admins', or a
                                                  platform admin's)
      troupe artifacts link ID                    a view link to one of yours

  A row says whose each artifact is (`team finance`, `you`, or who published it) and
  `transferable` where the person may hand it on. Under Local only nothing is asked, and it
  says so.
  """

  alias Troupe.CLI.LocalOnly
  alias Troupe.Client.Artifacts

  @type say :: (String.t() -> any())

  @switches [
    scope: :string,
    json: :boolean,
    version: :integer,
    to: :string,
    title: :string,
    owner: :string
  ]

  @doc "What `troupe artifacts …` asks, from the words after `artifacts`."
  @spec parse([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, words, []} ->
        verb(words, Map.new(opts))

      {_opts, _words, invalid} ->
        {:error, "unknown option: #{Enum.map_join(invalid, ", ", &elem(&1, 0))} (#{usage()})"}
    end
  end

  defp verb(["list"], opts), do: only(opts, [:scope, :json], %{verb: :list})
  defp verb(["open", id], opts), do: only(opts, [:version], %{verb: :open, id: id})
  defp verb(["show", id], opts), do: only(opts, [:version], %{verb: :show, id: id})

  defp verb(["publish", file], opts),
    do: only(opts, [:to, :title, :owner], %{verb: :publish, file: file})

  defp verb(["transfer", id], opts), do: only(opts, [:to], %{verb: :transfer, id: id})
  defp verb(["link", id], opts), do: only(opts, [], %{verb: :link, id: id})
  defp verb(_words, _opts), do: {:error, "usage: " <> usage()}

  defp only(opts, allowed, asked) do
    case Map.keys(opts) -- allowed do
      [] ->
        checked(Map.merge(asked, opts))

      extra ->
        {:error,
         "troupe artifacts #{asked.verb} takes no #{Enum.map_join(extra, ", ", &"--#{&1}")}"}
    end
  end

  # What the words must agree on before anything is asked: whose a publication is, and
  # where a transfer goes.
  defp checked(%{verb: :publish, owner: owner}) when owner not in ["me", "team"],
    do: {:error, "--owner is me or team, not #{inspect(owner)}"}

  defp checked(%{verb: :publish, owner: "team"} = asked) do
    case asked[:to] do
      "team:" <> name when name != "" -> {:ok, asked}
      _other -> {:error, "--owner team needs --to team:<name>: only a team publication is a team's"}
    end
  end

  defp checked(%{verb: :transfer} = asked) do
    case asked[:to] do
      "team:" <> name when name != "" -> {:ok, asked}
      "me" -> {:ok, asked}
      nil -> {:error, "troupe artifacts transfer needs --to team:<name> or --to me"}
      other -> {:error, "--to is team:<name> or me, not #{inspect(other)}"}
    end
  end

  defp checked(asked), do: {:ok, asked}

  defp usage,
    do:
      "troupe artifacts list [--scope SCOPE] [--json] | open ID | show ID [--version N] | " <>
        "publish FILE [--to SCOPE] [--title T] [--owner me|team] | transfer ID --to team:NAME|me | link ID"

  @doc "Run it; returns the exit status."
  @spec run(map(), say()) :: non_neg_integer()
  def run(asked, say \\ &IO.puts/1) do
    if LocalOnly.on?(),
      do: refuse(say, LocalOnly.refusal("troupe artifacts")),
      else: verb_run(asked, say)
  end

  defp verb_run(%{verb: :list} = asked, say) do
    with {:ok, params, keep} <- Artifacts.scope_param(asked[:scope] || "all"),
         {:ok, answer} <- Artifacts.list(params) do
      rows = Enum.filter(answer.artifacts, keep)

      if asked[:json],
        do: say.(Jason.encode!(Enum.map(rows, &json_row/1), pretty: true)),
        else: Enum.each(listing(rows, answer.organisation), say)

      0
    else
      {:error, reason} -> refuse(say, reason)
    end
  end

  defp verb_run(%{verb: :open, id: id} = asked, say) do
    case Artifacts.open(id, asked[:version]) do
      {:ok, url} ->
        _ = Artifacts.seen(id, asked[:version] || 0)
        browse(url, id, say)
        0

      {:error, reason} ->
        refuse(say, reason)
    end
  end

  defp verb_run(%{verb: :show, id: id} = asked, say) do
    case Artifacts.read(id, asked[:version]) do
      {:ok, %{"text" => text} = read} ->
        _ = Artifacts.seen(id, read["version"] || 0)
        say.(text)
        0

      {:ok, _other} ->
        refuse(say, "the plane read no text of #{id}")

      {:error, reason} ->
        refuse(say, reason)
    end
  end

  defp verb_run(%{verb: :publish, file: file} = asked, say) do
    case Artifacts.publish(file, asked[:to] || "private",
           title: asked[:title],
           owner: asked[:owner]
         ) do
      {:ok, artifact} ->
        say.(
          "published #{file} as #{artifact["id"]} version #{artifact["version"]}" <>
            whose(artifact) <> if(artifact["url"], do: ": #{artifact["url"]}", else: "")
        )

        0

      {:error, reason} ->
        refuse(say, "#{file} not published: #{reason}")
    end
  end

  defp verb_run(%{verb: :transfer, id: id, to: to}, say) do
    case Artifacts.transfer(id, to) do
      {:ok, artifact} ->
        say.("#{artifact["id"] || id} is now #{owner_words(artifact)}")
        0

      {:error, reason} ->
        refuse(say, "#{id} not transferred: #{reason}")
    end
  end

  defp verb_run(%{verb: :link, id: id}, say) do
    case Artifacts.link(id) do
      {:ok, url} ->
        say.(url)
        0

      {:error, reason} ->
        refuse(say, reason)
    end
  end

  defp browse(url, id, say) do
    case Troupe.Browser.open(url) do
      :ok ->
        say.("opened #{id} in the browser")

      {:error, why} ->
        say.("the browser could not be started (#{why}); open this within a minute:\n#{url}")
    end
  end

  defp refuse(say, reason) do
    say.("troupe artifacts: " <> String.replace_prefix(reason, "troupe: ", ""))
    1
  end

  # A team's publication says so on the spot, since the default made it the team's.
  defp whose(%{"owner_team" => team}) when is_binary(team), do: " (team #{team}'s)"
  defp whose(_artifact), do: ""

  defp owner_words(%{"owner_team" => team}) when is_binary(team), do: "team #{team}'s"
  defp owner_words(_artifact), do: "yours"

  @doc "The list as lines: a heading per audience, then a row per artifact, newest first."
  @spec listing([map()], String.t() | nil) :: [String.t()]
  def listing([], _organisation), do: ["nothing published for you here yet"]

  def listing(rows, organisation) do
    Artifacts.audiences()
    |> Enum.flat_map(fn audience ->
      case Enum.filter(rows, &(Artifacts.audience_of(&1) == audience)) do
        [] ->
          []

        mine ->
          {glyph, name} = Artifacts.label(audience, organisation)
          ["#{glyph} #{name}"] ++ Enum.map(mine, &row_line/1) ++ [""]
      end
    end)
    |> Enum.drop(-1)
  end

  defp row_line(row) do
    new = if row["new"], do: "new ", else: "    "

    fields =
      [
        row["title"],
        row["kind"],
        "v#{row["current"] || row["version"]}",
        Artifacts.owner(row),
        Artifacts.ago(row["published_at"]),
        row["id"],
        if(row["may_transfer"], do: "transferable")
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    "  " <> new <> Enum.join(fields, " · ")
  end

  defp json_row(row) do
    row
    |> Map.take(
      ~w(id title kind version current visibility scope published_at url mine new owner_team may_transfer)
    )
    |> Map.put("audience", to_string(Artifacts.audience_of(row)))
    |> Map.put("by", Artifacts.owner(row))
  end
end
