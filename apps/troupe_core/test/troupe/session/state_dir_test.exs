defmodule Troupe.Session.StateDirTest do
  @moduledoc """
  A dormant session is found on disk whatever its state directory is called.

  A dormant session is only its log, and it is found by globbing the state directory.
  On Windows that directory comes from `%LOCALAPPDATA%` written with backslashes, which a
  glob reads as escapes: every pattern built on it matched nothing, and each dormant
  session vanished from the listing when the daemon restarted (#87). A `[` or a `{` in
  the path is misread the same way, as a wildcard.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Session.Log
  alias Troupe.Sessions.Index

  test "a state directory written with backslashes still lists and reads its dormant sessions", context do
    id = dormant_session(context, context.state_dir)
    assert_found(id, windows_form(context.state_dir))
  end

  for name <- ["state[1]", "state{a,b}"] do
    test "a state directory called #{name} lists and reads its own dormant sessions", context do
      state_dir = Path.join(context.base, unquote(name))
      File.mkdir_p!(state_dir)

      id = dormant_session(context, state_dir)
      assert_found(id, state_dir)
    end
  end

  defp dormant_session(context, state_dir) do
    %{session: session} = start_session(%{context | state_dir: state_dir}, steps: [{:text, "hi"}])
    :ok = Troupe.stop_session(session.id)
    session.id
  end

  defp assert_found(id, state_dir) do
    # A daemon's own index, over this state directory instead of the default one.
    index =
      start_supervised!(%{
        id: Index,
        start: {GenServer, :start_link, [Index, [state_dir: state_dir, session_idle_ms: :infinity]]}
      })

    assert [%{id: ^id, state: :dormant}] = GenServer.call(index, {:list, %{}})
    assert %{id: ^id, state: :dormant} = GenServer.call(index, {:get, id})

    assert Log.locate(id, state_dir)
    assert id |> Log.read_session(state_dir) |> Enum.any?(&(&1.type == "session_created"))
  end

  # The directory as `%LOCALAPPDATA%` spells it on Windows. Globbing reads a backslash as
  # a separator on every host, as `Troupe.Workspace` does, so under Linux this reaches
  # the same directory it does on Windows.
  defp windows_form(path), do: String.replace(path, "/", "\\")
end
