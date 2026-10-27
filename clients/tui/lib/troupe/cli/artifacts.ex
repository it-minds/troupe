defmodule Troupe.CLI.Artifacts do
  @moduledoc """
  `troupe artifacts` (root #62): the person's artifacts on the plane from the command line,
  through this machine's daemon and its sign-in, as `/artifacts` reaches them.

      troupe artifacts list [--scope mine|organisation|team:<name>|profile:<name>|shared|private] [--json]
      troupe artifacts open ID [--version N]      the browser, through the plane's one-time address
      troupe artifacts show ID [--version N]      its text on standard output (a Markdown one's source)
      troupe artifacts publish FILE [--to SCOPE] [--title TITLE]   as /publish; Only you when no --to
      troupe artifacts link ID                    a view link to one of yours

  Under Local only nothing is asked, and it says so.
  """

  alias Troupe.CLI.LocalOnly
  alias Troupe.Client.Artifacts

  @type say :: (String.t() -> any())

  @switches [scope: :string, json: :boolean, version: :integer, to: :string, title: :string]

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
  defp verb(["publish", file], opts), do: only(opts, [:to, :title], %{verb: :publish, file: file})
  defp verb(["link", id], opts), do: only(opts, [], %{verb: :link, id: id})
  defp verb(_words, _opts), do: {:error, "usage: " <> usage()}

  defp only(opts, allowed, asked) do
    case Map.keys(opts) -- allowed do
      [] ->
        {:ok, Map.merge(asked, opts)}

      extra ->
        {:error,
         "troupe artifacts #{asked.verb} takes no #{Enum.map_join(extra, ", ", &"--#{&1}")}"}
    end
  end

  defp usage,
    do:
      "troupe artifacts list [--scope SCOPE] [--json] | open ID | show ID [--version N] | publish FILE [--to SCOPE] [--title T] | link ID"

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
    case Artifacts.publish(file, asked[:to] || "private", title: asked[:title]) do
      {:ok, artifact} ->
        say.(
          "published #{file} as #{artifact["id"]} version #{artifact["version"]}" <>
            if(artifact["url"], do: ": #{artifact["url"]}", else: "")
        )

        0

      {:error, reason} ->
        refuse(say, "#{file} not published: #{reason}")
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
        by(row),
        Artifacts.ago(row["published_at"]),
        row["id"]
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    "  " <> new <> Enum.join(fields, " · ")
  end

  defp json_row(row) do
    row
    |> Map.take(~w(id title kind version current visibility scope published_at url mine new))
    |> Map.put("audience", to_string(Artifacts.audience_of(row)))
    |> Map.put("by", by(row))
  end

  defp by(%{"mine" => true}), do: "you"
  defp by(%{"owner" => %{"display_name" => name}}) when is_binary(name), do: name
  defp by(%{"owner" => %{"subject" => subject}}) when is_binary(subject), do: subject
  defp by(_row), do: "someone"
end
