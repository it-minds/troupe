defmodule Troupe.LocalOnlyHeadlessTest do
  @moduledoc """
  Local only reaches a session the terminal runs on this machine's daemon (root #765): with
  `local_only: true` in the person's own config, the session is under
  Local only from its first turn, the one its prompt starts as it is created, and stays
  under it when a headless `troupe resume` gives it a turn. The connection that gives a
  session its input is its window's own, not the link's, and it says Local only too; one
  that said nothing took the session back out of it at every turn.

  `async: false`: the user file is the suite's, the setting is held in the application
  environment for the run, and the link dials the daemon again with it.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers

  alias Troupe.CLI
  alias Troupe.CLI.Runner
  alias Troupe.Client.Daemon.Link

  setup do
    user = Troupe.Config.user_path()
    before = File.read!(user)

    on_exit(fn ->
      File.write!(user, before)
      Application.delete_env(:troupe, :local_only)
      Application.delete_env(:troupe, :client_name)
      redial_link()
    end)

    # The suite's own file, which trusts the test workspaces, with Local only on.
    File.write!(user, String.trim_trailing(before) <> "\nlocal_only: true\n")
    {:ok, args} = CLI.parse(["run", "hello"])
    {:ok, _args} = Runner.local_only({:ok, args})
    # The link of this VM dialled the daemon in an earlier test, without Local only; a
    # terminal's own run dials it fresh, as this one now does.
    redial_link()
    :ok
  end

  test "the first turn and a headless resume's are under Local only" do
    assert Link.client_info()["local_only"] == true

    {sid, _, ws} =
      start_session!(
        prompt: "write the report",
        script: [{:text_and_tools, "first", []}, {:text_and_tools, "second", []}]
      )

    rested(sid)
    assert Troupe.Gateway.LocalOnly.session?(sid)

    {out, code} =
      printed(fn -> Runner.main(["resume", sid, "--headless", "again", "--workspace", ws]) end)

    assert code == 0, out
    assert out =~ "root> second"
    assert Troupe.Gateway.LocalOnly.session?(sid)

    # Said at the first turn, the one the prompt started inside the create.
    loaded = for e <- Troupe.events(sid), e.type == "instructions_loaded", do: e
    assert [%{data: %{"local_only" => line}} | _] = loaded
    assert line =~ "Local only"

    harness = for e <- loaded, do: hd(e.data["files"])
    assert Enum.all?(harness, &(&1["scope"] == "harness"))
  end

  defp rested(sid) do
    eventually(
      fn ->
        Enum.any?(
          Troupe.Client.events(sid),
          &match?(
            %{agent_path: "root", type: :agent_state, seq: s, data: %{to: :idle}}
            when is_integer(s),
            &1
          )
        )
      end,
      10_000
    )
  end

  # The link's connection closed, so its next call dials again and says what this run says;
  # the link itself, and the embedded daemon it started, stay as they are.
  defp redial_link do
    case :sys.get_state(Link) do
      %{client: client} when is_pid(client) ->
        ref = Process.monitor(client)
        Troupe.Protocol.Client.close(client)
        assert_receive {:DOWN, ^ref, :process, ^client, _}, 5_000

      _no_connection ->
        :ok
    end

    :ok
  end

  defp printed(fun) do
    windows = Process.whereis(Troupe.UI.Windows)
    {:group_leader, before} = Process.info(windows, :group_leader)
    {:ok, io} = StringIO.open("")
    Process.group_leader(windows, io)

    try do
      code = fun.()
      {_, out} = StringIO.contents(io)
      {out, code}
    after
      Process.group_leader(windows, before)
    end
  end
end
