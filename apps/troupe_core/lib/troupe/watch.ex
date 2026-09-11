defmodule Troupe.Watch do
  @moduledoc """
  Watch-mode types and the tool-facing entry point.

  `expect_write/3` is how the harness avoids triggering itself: the write and edit
  tools announce a write before making it, and the watcher drops the change event
  whose content hash matches. A `nil` watcher — watch mode off — makes it a no-op,
  so the tools do not branch on whether watching is on.
  """

  @doc """
  Tell the watcher a write is about to happen, so it ignores the resulting event.

  Sent before the write, never after: the inotify event can arrive before `File.write`
  even returns.
  """
  @spec expect_write(pid() | nil, Path.t(), binary()) :: :ok
  def expect_write(nil, _path, _content), do: :ok

  def expect_write(watcher, path, content) when is_pid(watcher) do
    send(watcher, {:expect_write, path, content_hash(content)})
    :ok
  end

  @doc "The hash the watcher compares against."
  @spec content_hash(binary()) :: binary()
  def content_hash(content), do: :crypto.hash(:sha256, content)
end

defmodule Troupe.Watch.Trigger do
  @moduledoc """
  What the watcher hands the root agent: one message per debounced scan.

  `markers` holds every `AI!` or `AI?` comment found, and `context` every bare `AI`
  comment in the workspace. `mode` is `:change` unless every marker was a question,
  in which case the turn runs under the `plan` permission set and cannot edit.
  """

  alias Troupe.Watch.Marker

  @enforce_keys [:markers, :context, :mode]
  defstruct [:markers, :context, :mode]

  @type t :: %__MODULE__{markers: [Marker.t()], context: [Marker.t()], mode: :change | :question}

  @spec new([Marker.t()], [Marker.t()]) :: t()
  def new(markers, context) do
    mode = if Enum.all?(markers, &(&1.kind == :question)), do: :question, else: :change
    %__MODULE__{markers: markers, context: context, mode: mode}
  end

  @doc "Render the trigger as the user-role message the agent sends to the model."
  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = trigger) do
    [
      header(trigger),
      Enum.map(trigger.markers, &render_marker/1),
      render_context(trigger.context)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp header(%__MODULE__{mode: :question}) do
    """
    A file in the workspace has an AI? comment. Answer the question in prose.
    You are running under the read-only plan profile for this turn: you cannot edit
    files, and you should not try.
    """
    |> String.trim()
  end

  defp header(%__MODULE__{}) do
    """
    A file in the workspace has an AI! comment. Make the requested change.
    Remove the AI! comment as part of the same edit — leaving it there triggers you
    again on the next save.
    """
    |> String.trim()
  end

  defp render_marker(marker) do
    """
    #{marker.file}:#{marker.line} — #{marker.comment}

    ```
    #{marker.context}
    ```
    """
    |> String.trim()
  end

  defp render_context([]), do: ""

  defp render_context(markers) do
    body =
      Enum.map_join(markers, "\n", fn m -> "#{m.file}:#{m.line} — #{m.comment}" end)

    "Other AI comments in the workspace, for context:\n" <> body
  end
end

defmodule Troupe.Watch.Backend do
  @moduledoc """
  How the watcher learns that files changed.

  Two implementations, one behaviour: the native `file_system` watcher where it
  works, and a polling scan where it does not. Backends are processes linked to the
  watcher, so a backend crash is the watcher's crash — and `rest_for_one` in the
  session keeps that away from the agents.

  Both send `{:watch_paths, [absolute_path]}` to the listener.
  """

  @callback available?(Path.t()) :: boolean()
  @callback start_link(root :: Path.t(), listener :: pid(), opts :: keyword()) ::
              GenServer.on_start()
  @callback name() :: atom()

  @doc "Whether a backend can actually run here. Dispatches so callers need no `apply`."
  @spec usable?(module(), Path.t()) :: boolean()
  def usable?(backend, root), do: backend.available?(root)
end
