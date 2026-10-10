Code.require_file("../../support/fake_gateway.exs", __DIR__)

defmodule Troupe.Agent.ValidateTest do
  @moduledoc """
  An agent definition checked as it is saved (#503, Decision 841): each thing a file can
  get wrong that the loader forgives, as an error naming its field, and what cannot be
  checked here as a warning. Every built-in passes, since copying one is the common way
  to make an agent. The model is checked against the list the daemon keeps of what the
  provider serves (Decision 778), here a stand-in gateway on a loopback port.
  `async: false`: that list is in the config directory, which is process-global.
  """

  use ExUnit.Case, async: false

  alias Troupe.Agent.{Definitions, Validate}
  alias Troupe.Config
  alias Troupe.LLM.Catalog.Store
  alias Troupe.Test.FakeGateway

  defp check(source, opts \\ []), do: Validate.check(source, opts)
  defp fields(findings), do: Enum.map(findings, & &1.field)

  defp errors(source, opts \\ []), do: check(source, opts).errors

  defp with_model(model),
    do: "---\ndescription: x\nmode: primary\nmodel: #{model}\n---\nYou.\n"

  test "every built-in is a definition a person may save as it is" do
    for file <- Path.wildcard(Path.join(Definitions.builtin_dir(), "*.md")) do
      name = Path.basename(file, ".md")
      result = check(File.read!(file), name: name)
      assert result.ok, "#{name}: #{inspect(result.errors)}"
    end
  end

  test "a key no agent has, a missing mode and a wrong one" do
    assert [%{field: "colour", message: colour}, %{field: "mode", message: missing}] =
             errors("---\ndescription: x\ncolour: blue\n---\nYou work.\n")

    assert colour =~ "not a key an agent has"
    assert missing =~ "mode is missing"

    assert [%{field: "mode", message: wrong}] =
             errors("---\ndescription: x\nmode: main\n---\nYou.\n")

    assert wrong =~ ~s(not "main")

    # A file with no frontmatter loads, as a subagent; saved, it says what it is.
    assert ["mode"] = fields(errors("Just a paragraph of instruction.\n"))
  end

  test "a tool that does not exist, with the nearest that do" do
    assert [%{field: "tools", message: message}] =
             errors("---\ndescription: x\nmode: primary\ntools:\n  - read_fil\n---\nYou.\n")

    assert message =~ "read_fil is not a tool"
    assert message =~ "read_file"
  end

  test "a permission that grants a tool the list leaves out never applies; a deny of one is fine" do
    source = """
    ---
    description: x
    mode: primary
    tools:
      - read_file
    permissions:
      shell: auto
      edit_file: ask
      write_file: deny
      read_file: sometimes
    ---
    You.
    """

    errors = errors(source)

    assert fields(errors) == [
             "permissions.edit_file",
             "permissions.read_file",
             "permissions.shell"
           ]

    assert Enum.find(errors, &(&1.field == "permissions.shell")).message =~ "never applies"

    assert Enum.find(errors, &(&1.field == "permissions.read_file")).message =~
             "auto, ask or deny"

    # With every tool, any known one may be granted; an unknown one may not.
    assert [%{field: "permissions.teleport"}] =
             errors(
               "---\ndescription: x\nmode: primary\npermissions:\n  shell: auto\n  teleport: ask\n---\nYou.\n"
             )
  end

  test "numbers, lists and switches of the wrong kind" do
    source = """
    ---
    description: x
    mode: subagent
    tools: some
    skills: 3
    max_turns: ten
    budget_share: 0
    override: maybe
    ---
    You.
    """

    assert fields(errors(source)) == ["tools", "skills", "max_turns", "budget_share", "override"]
  end

  test "a frontmatter that is not YAML, and a name an agent may not have" do
    assert [%{field: "frontmatter", message: message}] =
             errors("---\nmode: [primary\n---\nYou.\n")

    assert message =~ "not YAML"

    assert [%{field: "name"}] =
             errors("---\ndescription: x\nmode: primary\n---\nYou.\n", name: "Not A Name")
  end

  test "what cannot be checked here is a warning, and so is what is merely odd" do
    source = """
    ---
    mode: primary
    model: some-model
    tools:
      - read_file
      - mcp.tracker.search
      - client.open_editor
    budget_share: 2
    imported_from: ".claude/agents/x.md"
    imported_hash: "00"
    ---
    """

    result = check(source)
    assert result.ok

    assert fields(result.warnings) == [
             "tools",
             "tools",
             "model",
             "budget_share",
             "description",
             "prompt"
           ]
  end

  test "the parser's errors in words, as a file that does not load is listed with" do
    assert Validate.describe({:bad_mode, "main"}) =~ "mode must be primary or subagent"
    assert Validate.describe({:bad_permission, "shell", "yes"}) =~ "auto, ask or deny"
    assert Validate.describe(:eacces) =~ "cannot be read"
  end

  describe "the model, by what the provider serves" do
    setup do
      base = Path.join(System.tmp_dir!(), "troupe-validate-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(base, "config"))
      previous = System.get_env("TROUPE_CONFIG_HOME")
      System.put_env("TROUPE_CONFIG_HOME", Path.join(base, "config"))
      gateway = FakeGateway.start()

      on_exit(fn ->
        FakeGateway.stop(gateway)
        System.put_env("TROUPE_CONFIG_HOME", previous)
        File.rm_rf!(base)
      end)

      config = %Config{
        provider: "openai",
        base_url: gateway.base_url,
        api_key: FakeGateway.key(),
        model: "qwen3-235b",
        small_model: "qwen3.6-35b"
      }

      %{config: config}
    end

    test "unchecked until the provider has listed its models here, then served or not", %{
      config: config
    } do
      assert %{ok: true, warnings: [%{field: "model", message: unchecked}]} =
               check(with_model("qwen3.5"), config: config)

      assert unchecked =~ "not checked"

      {:ok, _catalog, []} = Store.refresh(config)

      assert [%{field: "model", message: message}] = errors(with_model("qwen3.5"), config: config)
      assert message =~ "qwen3.5 is not a model the provider serves"
      assert message =~ "qwen3.6-35b"

      assert %{ok: true, warnings: []} = check(with_model("qwen3-235b"), config: config)
      # An alias is the model the configuration names for it.
      assert %{ok: true, warnings: []} = check(with_model("cheap"), config: config)
    end

    test "without a configuration, the model is a warning" do
      assert %{ok: true, warnings: [%{field: "model"}]} = check(with_model("anything"))
    end
  end
end
