defmodule Troupe.Config.ExplainTest do
  @moduledoc """
  `troupe config --explain`, `validate` and `migrate`, and the files Troupe writes
  (Decision 686): every value with the layer and file that set it and secrets masked,
  a non-zero exit on any problem, a migration that shows its diff and keeps the file it
  replaces, and a key table the committed schema and reference are generated from.
  """

  use ExUnit.Case, async: true

  alias Troupe.Config
  alias Troupe.Config.{Layers, Migrate, Schema}

  @root Path.expand("../../../../..", __DIR__)

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-explain-#{System.unique_integer([:positive])}")
    ws = Path.join(base, "ws")
    File.mkdir_p!(Path.join(ws, ".troupe"))
    on_exit(fn -> File.rm_rf!(base) end)
    user = Path.join(base, "config.yaml")
    System.put_env("TROUPE_EXPLAIN_TEST_KEY", "sk-from-the-environment-123456")

    File.write!(user, """
    trusted_workspaces: [#{Jason.encode!(ws)}]
    api_key: "{env:TROUPE_EXPLAIN_TEST_KEY}"
    model: user-model
    max_turns: 10
    """)

    File.write!(Path.join(ws, ".troupe/config.yaml"), "max_turns: 20\nmodels: {cheap: project-cheap}\n")
    %{base: base, ws: ws, user: user, opts: [user_path: user]}
  end

  describe "--explain" do
    test "shows every key with its value and the layer that set it, secrets masked", ctx do
      {text, 0} = Config.explain(ctx.ws, nil, ctx.opts)

      assert text =~ "configuration for #{ctx.ws} (trusted)"
      assert text =~ "user     #{ctx.user}"
      assert text =~ ~r/max_turns\s+20\s+project/
      assert text =~ ~r/models\.default\s+user-model\s+user/
      assert text =~ ~r/models\.cheap\s+project-cheap\s+project/
      assert text =~ ~r/max_tokens\s+8192\s+default/
      assert text =~ ~r/\napi_key\s+sk-f…56 \(from/
      refute text =~ "sk-from-the-environment-123456"
      # Every key in the table is there.
      for spec <- Schema.keys(), not match?({:object, _}, spec.type), do: assert(text =~ spec.key)
      assert text =~ "model is the old spelling of models.default"
    end

    test "with a key, its whole ladder: the default, each layer, the one in effect", ctx do
      {text, 0} = Config.explain(ctx.ws, "max_turns", ctx.opts)

      assert text =~ "max_turns = 20"
      assert text =~ ~r/default\s+40/
      assert text =~ ~r/user\s+10\s+#{Regex.escape(ctx.user)}/
      assert text =~ ~r/project\s+20\s+.*config\.yaml  <- in effect/

      {text, 0} = Config.explain(ctx.ws, "api_key", ctx.opts)
      assert text =~ "api_key = sk-f…56 (from {env:TROUPE_EXPLAIN_TEST_KEY})"
      refute text =~ "sk-from-the-environment-123456"
    end

    test "an old spelling is explained as the new one, and an unknown key gets a suggestion", ctx do
      {text, 0} = Config.explain(ctx.ws, "model", ctx.opts)
      assert text =~ "model is the old spelling of models.default."
      assert text =~ "models.default = user-model"

      assert {"max_tokns is not a setting Troupe knows; did you mean max_tokens?", 1} =
               Config.explain(ctx.ws, "max_tokns", ctx.opts)
    end

    test "says why a workspace's key is ignored", ctx do
      File.write!(ctx.user, "api_key: user-key-1234567890\n")
      File.write!(Path.join(ctx.ws, ".troupe/config.yaml"), "auto_approve: true\n")

      {text, 0} = Config.explain(ctx.ws, "auto_approve", ctx.opts)
      assert text =~ "auto_approve = false"
      assert text =~ ~r/\n\s+ignored: a project's file sets it only in a trusted workspace/
    end

    test "--json has every key, its value, layer, file and ladder, secrets masked", ctx do
      {json, 0} = Config.explain(ctx.ws, nil, Keyword.put(ctx.opts, :json, true))
      decoded = Jason.decode!(json)

      assert decoded["trusted"] == true
      keys = Map.new(decoded["keys"], &{&1["key"], &1})
      assert keys["max_turns"]["value"] == 20
      assert keys["max_turns"]["layer"] == "project"
      assert keys["max_turns"]["source"] == Path.join(ctx.ws, ".troupe/config.yaml")
      assert Enum.map(keys["max_turns"]["ladder"], & &1["layer"]) == ["default", "user", "project"]
      assert keys["api_key"]["value"] == "sk-f…56"
      assert hd(tl(keys["api_key"]["ladder"]))["from"] == "{env:TROUPE_EXPLAIN_TEST_KEY}"
      refute json =~ "sk-from-the-environment-123456"
    end
  end

  describe "validate" do
    test "a file that is fine exits 0; a typo or an old spelling exits 1, naming it", ctx do
      good = Path.join(ctx.base, "good.yaml")
      File.write!(good, "version: 1\nmodels:\n  default: m\n")
      assert {"#{good} is valid\n", 0} == Config.validate(ctx.ws, good)

      bad = Path.join(ctx.base, "bad.yaml")
      File.write!(bad, "max_tokns: 1\nmodel: m\n")
      {text, 1} = Config.validate(ctx.ws, bad)
      assert text =~ "#{bad}:1: max_tokns is not a setting Troupe knows, and is ignored; did you mean max_tokens?"
      assert text =~ "#{bad}:2: model is the old spelling of models.default"
      assert text =~ "2 problems. `troupe config migrate` rewrites the old spellings."
    end

    test "a refused file exits 1 with the reason", ctx do
      bad = Path.join(ctx.base, "refused.yaml")
      File.write!(bad, "approvals: sometimes\n")
      assert {text, 1} = Config.validate(ctx.ws, bad)
      assert text =~ "approvals must be one of wait, deny, not \"sometimes\""
    end

    test "without a path, everything a session here would read, unset variables included", ctx do
      File.write!(ctx.user, "providers:\n  gw:\n    api_key: \"{env:TROUPE_EXPLAIN_SURELY_UNSET}\"\n")
      {text, 1} = Config.validate(ctx.ws, nil, ctx.opts)
      assert text =~ "providers.gw.api_key reads {env:TROUPE_EXPLAIN_SURELY_UNSET}"

      File.write!(ctx.user, "version: 1\n")
      File.rm!(Path.join(ctx.ws, ".troupe/config.yaml"))
      assert {"valid: " <> _, 0} = Config.validate(ctx.ws, nil, ctx.opts)
    end
  end

  describe "migrate" do
    test "prints the rewrite, and --write makes it and keeps the file as it was", ctx do
      {text, 0} = Config.migrate(ctx.ws, nil, ctx.opts)
      assert text =~ "--- #{ctx.user}"
      assert text =~ "- model: user-model"
      assert text =~ "+ models:"
      assert text =~ "+   default: \"user-model\""
      assert text =~ "#{Path.join(ctx.ws, ".troupe/config.yaml")}: uses the current spellings; nothing to change"
      assert text =~ "run `troupe config migrate --write`"
      assert File.read!(ctx.user) =~ "model: user-model"

      before = File.read!(ctx.user)
      {_text, 0} = Config.migrate(ctx.ws, nil, Keyword.put(ctx.opts, :write, true))
      assert File.read!(ctx.user <> ".previous") == before

      {:ok, config, layers} = Config.resolve(ctx.ws, [], ctx.opts)
      assert config.model == "user-model"
      assert layers.warnings == []
      assert {_text, 0} = Config.migrate(ctx.ws, nil, ctx.opts)
    end

    test "rewrites yes and no as the booleans they mean", ctx do
      File.write!(ctx.user, "auto_approve: no\nwatch: yes\n")
      assert {:ok, %{migrated: migrated, changed?: true}} = Migrate.plan(ctx.user)
      assert migrated =~ "auto_approve: false\n"
      assert migrated =~ "watch: true\n"
    end
  end

  describe "what a writer writes" do
    test "the new spellings only, version 1, and a header that names the schema", ctx do
      path = Path.join(ctx.base, "written.yaml")
      File.write!(path, "# a note\nold: 1\n")

      :ok = Config.write_file(path, %{"model" => "m", "small_model" => "c", "auth_token" => "t", "x-mine" => 1})
      text = File.read!(path)

      assert text =~ ~r/\A# yaml-language-server: \$schema=https:\/\/troupe\.dev\/schema\/config\/v1\.json\n/
      assert text =~ "\nversion: 1\n"
      {:ok, written, _} = Layers.parse(path)
      assert written["models"] == %{"default" => "m", "cheap" => "c"}
      assert {written["api_key"], written["auth"]} == {"t", "bearer"}
      refute Enum.any?(~w(model small_model auth_token), &Map.has_key?(written, &1))
      assert File.read!(path <> ".previous") == "# a note\nold: 1\n"
    end

    test "refuses a map that spells one setting two ways", ctx do
      path = Path.join(ctx.base, "both.yaml")
      assert {:error, message} = Config.write_file(path, %{"model" => "a", "models" => %{"default" => "b"}})
      assert message =~ "model and models.default both set models.default"
      refute File.exists?(path)
    end
  end

  describe "the key table" do
    test "is what protocol/schema/config/v1.json and the reference say (mix troupe.config.schema)" do
      committed = File.read!(Path.join(@root, "protocol/schema/config/v1.json"))
      assert committed == Jason.encode!(Schema.json_schema(), pretty: true) <> "\n"

      page = File.read!(Path.join(@root, "docs/user/configuration.md"))
      assert page =~ "<!-- config-keys:begin -->\n" <> Schema.reference() <> "<!-- config-keys:end -->"
    end

    test "every example in the documentation is a valid config file", ctx do
      for doc <- ["docs/user/configuration.md", "clients/tui/README.md", "apps/troupe_daemon/README.md"],
          {block, n} <- doc |> then(&File.read!(Path.join(@root, &1))) |> yaml_blocks() |> Enum.with_index(1) do
        path = Path.join(ctx.base, "example-#{n}.yaml")
        File.write!(path, block)
        found = Layers.check(:user, path)
        assert {found.errors, found.warnings} == {[], []}, "#{doc}, example #{n}:\n#{block}"
      end
    end
  end

  defp yaml_blocks(markdown) do
    ~r/```yaml\n(.*?)```/s
    |> Regex.scan(markdown, capture: :all_but_first)
    |> Enum.map(&hd/1)
  end
end
