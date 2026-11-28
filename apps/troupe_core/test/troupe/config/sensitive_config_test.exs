defmodule Troupe.Config.SensitiveConfigTest do
  @moduledoc """
  A sensitive session on this computer (#1239 slice 3): `sensitive` from the organisation's
  enforced file and the user's own `config.yaml`, the organisation's first, each rule with
  where it came from; the user's file adds rules and may tighten `sharing`, never loosen it;
  a value the loader cannot read is an error with the sentence; a project's file and a pod
  read none.
  """

  # The managed file's path is the application environment's, which is the whole VM's.
  use ExUnit.Case, async: false

  alias Troupe.Config
  alias Troupe.Config.{Explain, Permissions}
  alias Troupe.Tool.Result

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-sensitive-config-#{System.unique_integer([:positive])}")
    ws = Path.join(base, "ws")
    File.mkdir_p!(Path.join(ws, ".troupe"))
    user = Path.join(base, "user.yaml")
    managed = Path.join(base, "managed.yaml")
    previous = Application.get_env(:troupe_core, :organisation)

    Application.put_env(:troupe_core, :organisation,
      managed_path: managed,
      cache_path: Path.join(base, "state/organisation.json"),
      keys_path: Path.join(base, "state/plane-keys.json")
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:troupe_core, :organisation, previous),
        else: Application.delete_env(:troupe_core, :organisation)

      File.rm_rf!(base)
    end)

    %{ws: ws, user: user, managed: managed, project: Path.join(ws, ".troupe/config.yaml")}
  end

  @org """
  version: 1
  enforced:
    sensitive:
      marked_by: ["mcp(records.*)"]
      deny: [publish_artifact, web_fetch]
      sharing: ask
  """

  defp resolve(ctx, opts \\ []),
    do: Config.resolve(Keyword.get(opts, :workspace), [], [user_path: ctx.user] ++ Keyword.delete(opts, :workspace))

  defp texts(rules), do: Enum.map(rules, &{&1.text, &1.origin})

  test "the organisation's enforced rules come first, the user's own are added, each with its file", ctx do
    File.write!(ctx.managed, @org)

    File.write!(ctx.user, """
    version: 1
    sensitive:
      marked_by: ["read_file(/srv/hr/**)"]
      deny: ["mcp(chat.*)"]
      sharing: deny
    """)

    assert {:ok, config, layers} = resolve(ctx)
    sensitive = config.sensitive

    assert texts(sensitive.marked_by) == [{"mcp(records.*)", :enforced}, {"read_file(/srv/hr/**)", :user}]
    assert texts(sensitive.deny) == [{"publish_artifact", :enforced}, {"web_fetch", :enforced}, {"mcp(chat.*)", :user}]
    assert Enum.all?(sensitive.deny, &(&1.layer == :sensitive))
    assert hd(sensitive.marked_by).source == ctx.managed
    assert List.last(sensitive.marked_by).source == ctx.user
    # Tighter than the organisation's ask: the user's word holds, and says whose it is.
    assert sensitive.sharing == "deny"
    assert sensitive.sharing_from == %{layer: :user, source: ctx.user}
    assert sensitive.profile == nil

    # Where each came from, for a settings page and for --explain.
    json = Explain.sensitive_json(layers.sensitive)
    assert [%{"rule" => "mcp(records.*)", "scope" => "enforced"}, %{"rule" => "read_file(/srv/hr/**)", "scope" => "user"}] =
             json["marked_by"]

    assert json["sharing"]["value"] == "deny"
    assert json["sharing"]["scope"] == "user"

    assert {said, 0} = Explain.explain(nil, "sensitive", user_path: ctx.user)
    assert said =~ "sensitive sessions"
    assert said =~ "mcp(records.*)"
    assert said =~ "enforced"
  end

  test "the user's file cannot loosen sharing: the organisation's word holds, and it is said", ctx do
    File.write!(ctx.managed, @org)
    File.write!(ctx.user, "version: 1\nsensitive:\n  sharing: allow\n")

    assert {:ok, config, layers} = resolve(ctx)
    assert config.sensitive.sharing == "ask"
    assert config.sensitive.sharing_from == %{layer: :enforced, source: ctx.managed}
    assert Enum.any?(layers.warnings, &(&1.message =~ "sensitive.sharing is allow, looser than the ask your organisation enforces"))
    # Nothing it wrote takes a rule away: the organisation's are all there.
    assert texts(config.sensitive.deny) == [{"publish_artifact", :enforced}, {"web_fetch", :enforced}]
  end

  test "a value the loader cannot read is an error with the sentence", ctx do
    File.write!(ctx.user, "version: 1\nsensitive:\n  marked_by: [\"mcp(records.*)\"]\n  deny: [web_fetch]\n  sharing: maybe\n")
    assert {:error, error} = resolve(ctx)
    assert Exception.message(error) =~ "sensitive.sharing must be one of allow, ask, deny, not \"maybe\""

    File.write!(ctx.user, "version: 1\nsensitive:\n  marked_by: [\"mcp.records\"]\n  deny: [web_fetch]\n")
    assert {:error, error} = resolve(ctx)
    assert Exception.message(error) =~ "sensitive.marked_by"
    assert Exception.message(error) =~ "mcp(records)"

    File.write!(ctx.managed, "version: 1\nenforced:\n  sensitive:\n    sharing: sometimes\n")
    File.write!(ctx.user, "version: 1\n")
    assert {:error, error} = resolve(ctx)
    assert Exception.message(error) =~ "enforced: sensitive.sharing must be one of allow, ask, deny"
  end

  test "marked_by without deny anywhere is refused, so the choice is explicit", ctx do
    File.write!(ctx.user, "version: 1\nsensitive:\n  marked_by: [\"mcp(records.*)\"]\n")
    assert {:error, error} = resolve(ctx)
    assert Exception.message(error) =~ "sensitive.marked_by is set and sensitive.deny is not"

    # The organisation's deny is the deny of a user's marked_by too.
    File.write!(ctx.managed, "version: 1\nenforced:\n  sensitive:\n    deny: [publish_artifact]\n")
    assert {:ok, config, _layers} = resolve(ctx)
    assert texts(config.sensitive.marked_by) == [{"mcp(records.*)", :user}]
  end

  test "a project's file, an organisation's defaults and a pod read none of it", ctx do
    File.write!(ctx.user, "version: 1\ntrusted_workspaces:\n  - #{Jason.encode!(ctx.ws)}\n")
    File.write!(ctx.project, "version: 1\nsensitive:\n  deny: [web_fetch]\n")

    assert {:ok, config, layers} = resolve(ctx, workspace: ctx.ws)
    assert config.sensitive == nil
    assert Enum.any?(layers.warnings, &(&1.message =~ "sensitive is ignored: it is read only from the user's config.yaml"))

    File.write!(ctx.managed, "version: 1\ndefaults:\n  sensitive:\n    deny: [web_fetch]\n")
    assert {:ok, config, layers} = resolve(ctx)
    assert config.sensitive == nil
    assert Enum.any?(layers.warnings, &(&1.message =~ "defaults.sensitive is ignored: sensitive goes under enforced:"))

    File.write!(ctx.managed, @org)
    assert {:ok, pod, _layers} = resolve(ctx, trust: :never)
    assert pod.sensitive == nil
  end

  test "a refusal by this computer's rule names whose rule it is", ctx do
    File.write!(ctx.managed, @org)
    assert {:ok, config, _layers} = resolve(ctx)
    rule = Enum.find(config.sensitive.deny, &(&1.text == "publish_artifact"))
    mark = %{"how" => "call", "by" => "mcp.records.lookup", "at" => "2026-11-28T10:14:00Z"}

    said = Result.describe({:denied_sensitive, "publish_artifact", rule, mark})
    assert said =~ "publish_artifact is refused in a sensitive session by what your organisation enforces"
    assert said =~ "managed.yaml"
    assert Permissions.to_json(rule)["scope"] == "enforced"
  end
end
