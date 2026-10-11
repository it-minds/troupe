defmodule Troupe.OrgSettingsTest do
  @moduledoc """
  The organisation's layer in the terminal (root Decision 869): the settings page shows
  a key the organisation enforces as set by it and does not edit it, an organisation's
  default as the organisation's, and `troupe config pull` keeps a plane's document through
  the daemon and says what this machine now takes from it.
  """

  # The managed file and the plane's copy are the whole VM's, the embedded daemon's too.
  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.CLI.ModelConfig
  alias Troupe.Config
  alias Troupe.Config.Org
  alias Troupe.Settings

  @plane "https://plane.example.test"

  setup do
    File.mkdir_p!(Path.dirname(Org.managed_path()))

    on_exit(fn ->
      File.rm(Org.managed_path())
      File.rm(Org.cache_path())
    end)

    :ok
  end

  describe "the page's view" do
    test "a key the organisation enforces is written to no scope, and says whose it is" do
      view =
        Settings.view(%{
          "keys" => [
            %{
              "key" => "max_turns",
              "value" => 25,
              "layer" => "enforced",
              "scopes" => [],
              "enforced" => %{"value" => 25, "source" => @plane}
            }
          ],
          "files" => [%{"scope" => "user", "path" => "/home/me/.config/troupe/config.yaml"}]
        })

      assert Settings.enforced(view, "max_turns") == %{"value" => 25, "source" => @plane}
      assert Settings.next_scope(view, "max_turns", nil) == "user"

      assert Settings.enforced_line(view, "max_turns") ==
               "max_turns is set by your organisation (25, from #{@plane}); it cannot be changed here"
    end
  end

  describe "the settings page" do
    test "an enforced key is the organisation's and is not edited; a default is the organisation's too" do
      File.write!(Org.managed_path(), "defaults:\n  max_depth: 2\nenforced:\n  max_turns: 25\n")

      {sid, _fake, ws} = start_session!()
      {pid, session} = start_tui(sid)

      type(pid, "/settings")
      press(pid, "enter")

      text = screen_text(pid, session)
      assert text =~ ~r/max turns\s+25  · set by your organisation/
      assert text =~ ~r/delegation depth\s+2  · organisation/

      to_setting(pid, "max_turns")
      text = screen_text(pid, session)
      assert text =~ "max turns is set by your organisation"
      assert text =~ "set by: your organisation (#{Org.managed_path()}), which enforces it"

      press(pid, "enter")
      assert user_state(pid).settings.editing == nil
      assert screen_text(pid, session) =~ "max_turns is set by your organisation (25, from"

      press(pid, "s")
      assert screen_text(pid, session) =~ "it cannot be changed here"

      refute File.read!(Path.join(ws, ".troupe/config.yaml")) =~ "max_turns"
      assert Config.load(ws).max_turns == 25
    end
  end

  describe "troupe config pull" do
    test "keeps the plane's document through the daemon, and says what it holds" do
      answer = %{
        "configured" => true,
        "provider" => "openai",
        "base_url" => "https://llm.example.test/v1",
        "auth" => "bearer",
        "models" => %{"default" => "org-model", "cheap" => nil, "expensive" => nil},
        "defaults" => %{"provider" => "openai", "models" => %{"default" => "org-model"}},
        "enforced" => %{"approvals" => "deny"}
      }

      {:ok, said} = Agent.start_link(fn -> [] end)
      say = fn line -> Agent.update(said, &(&1 ++ [line])) end

      assert ModelConfig.keep(@plane, answer, say) == 0
      lines = Agent.get(said, & &1)

      assert hd(lines) =~ "#{@plane}'s settings for this machine, kept in"
      assert "  default   models.default = org-model" in lines
      assert "  default   provider = openai" in lines
      assert "  enforced  approvals = deny" in lines

      assert {:ok, %{"plane_url" => @plane}} = Org.read_cache()
      assert Config.load(nil).approvals == :deny
    end

    test "a plane that sets nothing says where an administrator sets it" do
      {:ok, said} = Agent.start_link(fn -> [] end)
      say = fn line -> Agent.update(said, &(&1 ++ [line])) end

      call = fn "config.organisation", params ->
        {:ok, %{"plane_url" => params["plane_url"], "defaults" => %{}, "enforced" => %{}}}
      end

      assert ModelConfig.keep(@plane, %{"configured" => false}, say, call) == 0
      assert [line] = Agent.get(said, & &1)
      assert line =~ "sets no defaults or limits for people's own machines"
    end

    test "a document the daemon refuses is said, and exits 1" do
      {:ok, said} = Agent.start_link(fn -> [] end)
      say = fn line -> Agent.update(said, &(&1 ++ [line])) end

      bad = %{"defaults" => %{}, "enforced" => %{"max_turns" => "lots"}}
      assert ModelConfig.keep(@plane, bad, say) == 1
      assert [line] = Agent.get(said, & &1)
      assert line =~ "could not keep the organisation's settings"
      assert line =~ "max_turns must be a whole number"
    end
  end
end
