defmodule Troupe.Scratch do
  @moduledoc """
  A session's scratchpad: named documents an agent shows a person beside the chat
  (issue #472, Decision 870).

  A long answer - a plan, a report, a comparison, a diagram, a table - written as
  assistant text scrolls away and cannot be revised without printing it again. `show`
  writes it here instead, and each write is a durable `scratch_updated` event, so every
  client attached learns of it as it happens and one that attaches later, reconnects or
  replays learns of it from the log.

  **Where the documents are.** In the session's own directory, beside its log and blobs:
  `<state>/sessions/<workspace>/<id>/scratch/<name>`. Not under `session:/`, which is the
  checkout the agent works in: a document about the work is not the work, two sessions in
  one checkout would write over each other's `plan.md`, and an erasure, which deletes the
  session's directory, would leave it behind. They are addressed as `scratch:/<name>`, a
  mount of their own, resolved by `Troupe.Mounts.resolve/3` like any other path, and a
  client reads one with `fs.read`, the one read path the protocol has.

  **What the log says.** The listing is a fold over the log's `scratch_updated` events,
  the latest of each name, so it is the same for a running session and a dormant one and
  rebuilt by a replay. The documents themselves are files; their words are in the log
  already, as the `show` call's arguments, and nothing replaces those with a pointer: the
  prompt prefix stays the same (Decisions 863 and 867).
  """

  alias Troupe.{Config, Mounts}
  alias Troupe.Protocol.Event
  alias Troupe.Session.Log
  alias Troupe.Sessions.Index

  @kinds ~w(markdown mermaid json csv text)

  # A file name every file system Troupe runs on takes as it is, and the same under any
  # case: Windows and macOS fold case, so `Plan.md` and `plan.md` would be one file and
  # two documents. A name is lowered before it is checked.
  @name ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/
  # Names Windows keeps for devices, with or without an extension.
  @reserved ~w(con prn aux nul) ++
              Enum.map(1..9, &"com#{&1}") ++ Enum.map(1..9, &"lpt#{&1}")

  @type document :: %{
          name: String.t(),
          path: String.t(),
          kind: String.t(),
          title: String.t(),
          size: non_neg_integer(),
          hash: String.t(),
          version: pos_integer(),
          updated_at: String.t() | nil
        }

  @doc "The kinds a document may be, which is how a client shows it."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  A document's name as it is stored, or the sentence a model reads when it is refused.

  A name is a file name: lowered, then letters, digits, `.`, `-` and `_`, starting with
  a letter or digit. A separator, `..` or a control character is refused by name, so the
  model is told what was wrong rather than what is allowed.
  """
  @spec name(term()) :: {:ok, String.t()} | {:error, String.t()}
  def name(name) when is_binary(name) do
    lowered = String.downcase(name)

    cond do
      String.contains?(name, ["/", "\\"]) ->
        {:error,
         "A document's name is a file name, not a path: #{inspect(name)} has a separator. " <>
           "Use a name such as plan.md."}

      String.contains?(name, "..") ->
        {:error, "A document's name may not contain \"..\". Use a name such as plan.md."}

      String.match?(name, ~r/[\x00-\x1F\x7F]/) ->
        {:error,
         "A document's name may not contain a control character. Use a name such as plan.md."}

      not Regex.match?(@name, lowered) ->
        {:error,
         "A document's name is at most 64 lowercase letters, digits, '.', '-' and '_', " <>
           "starting with a letter or digit: #{inspect(name)} is not. Use a name such as plan.md."}

      (lowered |> String.split(".") |> hd()) in @reserved ->
        {:error,
         "#{inspect(name)} is a name Windows keeps for a device. Use another, such as plan.md."}

      true ->
        {:ok, lowered}
    end
  end

  def name(_name), do: {:error, "A document's name must be a string, such as plan.md."}

  @doc "A document's kind, `markdown` when none is given, or the sentence it is refused with."
  @spec kind(term()) :: {:ok, String.t()} | {:error, String.t()}
  def kind(nil), do: {:ok, "markdown"}
  def kind(kind) when kind in @kinds, do: {:ok, kind}

  def kind(kind),
    do: {:error, "kind is one of markdown, mermaid, json, csv or text, not #{inspect(kind)}."}

  @doc """
  Write or replace a document and log it.

  Refused, with a sentence the model can act on, past `scratch_max_bytes` for the
  document or, for a name the session has not used, past `scratch_max_documents`. One
  write at a time per session, so two calls in one response count their versions in
  order.
  """
  @spec write(Troupe.Tool.Ctx.t(), map()) :: {:ok, document()} | {:error, String.t()}
  def write(ctx, %{name: name, kind: kind, title: title, content: content}) do
    config = ctx.config || %Config{}

    if byte_size(content) > config.scratch_max_bytes do
      {:error,
       "The document is #{byte_size(content)} bytes, and a scratchpad document is at most " <>
         "#{config.scratch_max_bytes} (scratch_max_bytes). Show a shorter one, or split it " <>
         "across names."}
    else
      :global.trans(
        {{__MODULE__, ctx.session_id}, self()},
        fn -> write_locked(ctx, config, name, kind, title, content) end,
        [node()]
      )
    end
  end

  defp write_locked(ctx, config, name, kind, title, content) do
    documents = list(ctx.session_id)
    previous = Enum.find(documents, &(&1.name == name))

    if previous == nil and length(documents) >= config.scratch_max_documents do
      {:error,
       "This session's scratchpad holds #{length(documents)} documents, the most it takes " <>
         "(scratch_max_documents). Replace one by showing it again under its name, or " <>
         "answer in the chat."}
    else
      with {:ok, path} <- resolve(ctx.session_id, name),
           :ok <- File.write(path, content) do
        document = %{
          name: name,
          path: "scratch:/" <> name,
          kind: kind,
          title: title,
          size: byte_size(content),
          hash: hash(content),
          version: if(previous, do: previous.version + 1, else: 1),
          updated_at: nil
        }

        Log.append(
          ctx.session_id,
          ctx.agent_path,
          :scratch_updated,
          event_data(document, ctx.call_id)
        )

        {:ok, document}
      else
        {:error, reason} ->
          {:error, "The document could not be written: #{:file.format_error(reason)}."}
      end
    end
  end

  # Through the mount table, as every other write is: the name was checked already, and
  # the table holds it to the scratchpad's directory however it is spelled.
  defp resolve(session_id, name) do
    case dir(session_id) do
      nil ->
        {:error, :enoent}

      dir ->
        File.mkdir_p!(dir)

        case Mounts.resolve(Mounts.new([entry(dir, :rw)]), "scratch:/" <> name, :write) do
          {:ok, path, _entry} -> {:ok, path}
          {:error, _reason} -> {:error, :eacces}
        end
    end
  end

  # Everything a client shows of a document but its words, and the call that wrote it, so
  # a transcript can put the card where the call was.
  defp event_data(document, call_id) do
    data = document |> to_json() |> Map.delete("updated_at")
    if is_binary(call_id), do: Map.put(data, "call_id", call_id), else: data
  end

  @doc """
  The session's documents, the latest of each name, in the order each was first shown:
  a fold over its log, running or dormant.
  """
  @spec list(String.t() | [Event.t()]) :: [document()]
  def list(session_id) when is_binary(session_id),
    do: session_id |> Troupe.replay_from(0) |> list()

  def list(events) when is_list(events) do
    events
    |> Enum.filter(&(&1.type == "scratch_updated"))
    |> Enum.reduce({[], %{}}, fn %Event{data: data, ts: ts}, {order, latest} ->
      name = data["name"]
      order = if Map.has_key?(latest, name), do: order, else: [name | order]
      {order, Map.put(latest, name, document(data, ts))}
    end)
    |> then(fn {order, latest} ->
      order |> Enum.reverse() |> Enum.map(&Map.fetch!(latest, &1))
    end)
  end

  defp document(data, ts) do
    %{
      name: data["name"],
      path: data["path"] || "scratch:/" <> data["name"],
      kind: data["kind"],
      title: data["title"],
      size: data["size"],
      hash: data["hash"],
      version: data["version"],
      updated_at: ts
    }
  end

  @doc "A document as `scratch.list` answers it."
  @spec to_json(document()) :: map()
  def to_json(document) do
    %{
      "name" => document.name,
      "path" => document.path,
      "kind" => document.kind,
      "title" => document.title,
      "size" => document.size,
      "hash" => document.hash,
      "version" => document.version,
      "updated_at" => document.updated_at
    }
  end

  @doc """
  Give a fork the documents its history shows (`Troupe.fork_session/2`): each its events
  list, copied from the parent's scratchpad while the parent's copy is still the version
  the fork's log names. One the parent has since replaced stays behind, and a client
  reading it is told it is not found rather than handed words the fork's log never saw.
  """
  @spec carry(String.t(), [Event.t()], Path.t()) :: :ok
  def carry(parent_id, events, session_dir) do
    with from when is_binary(from) <- dir(parent_id),
         [_ | _] = documents <- list(events) do
      to = Path.join(session_dir, "scratch")
      File.mkdir_p!(to)
      Enum.each(documents, &carry_one(&1, from, to))
    end

    :ok
  end

  defp carry_one(document, from, to) do
    with {:ok, content} <- File.read(Path.join(from, document.name)),
         true <- hash(content) == document.hash do
      File.write!(Path.join(to, document.name), content)
    end
  end

  @doc """
  The directory a session's documents are in, beside its log wherever its config put it,
  or `nil` for a session with no log here.
  """
  @spec dir(String.t()) :: Path.t() | nil
  def dir(session_id) do
    log =
      try do
        Log.path(session_id)
      catch
        :exit, _ -> Log.locate(session_id, roots())
      end

    log && Path.join(Path.dirname(log), "scratch")
  end

  defp roots do
    Index.roots()
  catch
    :exit, _ -> [nil]
  end

  @doc """
  The table a session's mounts have, with its scratchpad first: what a client's `fs.read`
  of `scratch:/<name>` resolves against. Read-only there, so `fs.upload` cannot put a
  document on the pad that no event announced.
  """
  @spec with_mount(Mounts.t(), String.t()) :: Mounts.t()
  def with_mount(%Mounts{} = mounts, session_id) do
    case dir(session_id) do
      nil -> mounts
      dir -> Mounts.new([entry(dir, :ro) | mounts.entries])
    end
  end

  defp entry(dir, mode), do: %{name: "scratch", kind: :scratch, root: dir, mode: mode}

  @doc "What `fs.read` answers as a document's `hash`, and `scratch_updated` carries."
  @spec hash(binary()) :: String.t()
  def hash(content),
    do: "sha256:" <> (:sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower))
end
