defmodule Troupe.Watch.Backend do
  @moduledoc """
  Behaviour for watch-mode backends. A backend is linked to the Watcher and
  sends `{:file_changed, absolute_path}` to `notify` for every change.
  """

  @callback start_link(dir :: String.t(), notify :: pid(), opts :: keyword()) ::
              {:ok, pid()} | {:error, term()}
  @callback available?() :: boolean()
  @callback name() :: :file_system | :polling
end
