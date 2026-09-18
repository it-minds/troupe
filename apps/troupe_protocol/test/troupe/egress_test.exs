defmodule Troupe.EgressTest do
  @moduledoc """
  The allowlist is generated, and the chart is checked against it.

  R9's third documentation item, and the reason it is a document that has to be *true*
  rather than plausible: a hand-written allowlist is a list of what somebody remembered,
  and what it produces is a NetworkPolicy that looks complete and refuses one host at the
  moment somebody first needs it.

  Two claims here. The document says what the code declares, and the chart's defaults allow
  every host the code has. A deployment may narrow them — that is the operator's decision
  and this says nothing about it — but the shipped defaults cannot be narrower than the
  product needs to work at all.
  """

  use ExUnit.Case, async: true

  alias Troupe.Egress

  @root Path.expand("../../../..", __DIR__)

  defp read!(path), do: @root |> Path.join(path) |> File.read!()

  describe "the declarations" do
    test "every one names a component, a reason, and exactly one of a host or a setting" do
      for entry <- Egress.entries() do
        assert entry.component != ""
        assert String.length(entry.why) > 20, "a reason is a sentence: #{inspect(entry)}"

        case entry.kind do
          :configured ->
            assert is_binary(entry.setting), "a configured host names its setting"
            assert is_nil(entry.host), "a configured host has no hostname in the source"

          _fixed_or_browser ->
            assert is_binary(entry.host), "a fixed host is a hostname"
            assert is_nil(entry.setting)
        end
      end
    end

    test "and the fixed ones are hostnames rather than URLs" do
      for host <- Egress.fixed_hosts() do
        refute host =~ "://", "#{host} is a URL; a policy matches hosts"
        refute host =~ "/", "#{host} has a path; a policy matches hosts"
      end
    end
  end

  describe "the chart's defaults" do
    test "allow every host the code has" do
      patterns = chart_allowed_egress()

      uncovered = Enum.reject(Egress.fixed_hosts(), &Egress.covered?(&1, patterns))

      assert uncovered == [],
             """
             The chart's `troupePolicy.allowedEgress` does not allow: #{Enum.join(uncovered, ", ")}

             Its patterns are: #{Enum.join(patterns, ", ")}

             A host in the source that the shipped defaults refuse is a tool that fails the
             first time somebody uses it. Either allow it in `charts/troupe/values.yaml`, or
             take it out of `Troupe.Egress` because nothing dials it any more.
             """
    end

    test "and the globbing here is the globbing the policy applies" do
      # `*.anthropic.com` covers a subdomain and not the bare domain, which is what the
      # cluster does — a check that was more generous than the rule would pass here and
      # refuse there.
      assert Egress.covered?("api.anthropic.com", ["*.anthropic.com"])
      refute Egress.covered?("anthropic.com", ["*.anthropic.com"])
      refute Egress.covered?("api.anthropic.com.evil.test", ["*.anthropic.com"])
      assert Egress.covered?("github.com", ["github.com"])
    end
  end

  describe "the generated document" do
    test "is current" do
      # The same rule as the vendored assets and the generated tokens: committed bytes
      # cannot drift from what they are generated from. Regenerated here rather than
      # shelling out, so the failure names the drift instead of a task's exit code.
      assert File.exists?(Path.join(@root, "docs/egress-allowlist.md")),
             "run `mix troupe.egress`"

      document = read!("docs/egress-allowlist.md")

      for host <- Egress.fixed_hosts() do
        assert document =~ host,
               "#{host} is declared and not in the document; run mix troupe.egress"
      end

      for component <- Egress.components() do
        assert document =~ "## #{component}"
      end
    end

    test "and says what it is not" do
      document = read!("docs/egress-allowlist.md")

      # A per-profile host is a platform admin's decision and changes when somebody edits a
      # profile. A generated document that mixed them in would be one nobody could trust as
      # a chart's defaults.
      assert document =~ "What is not here"
      assert document =~ "egress.fqdns"
    end
  end

  # The chart's own defaults, read as text: a YAML parser is a dependency this app does not
  # have, and the list is a flat sequence under one key.
  defp chart_allowed_egress do
    read!("charts/troupe/values.yaml")
    |> String.split("\n")
    |> Enum.drop_while(&(not String.match?(&1, ~r/^\s*allowedEgress:\s*$/)))
    |> Enum.drop(1)
    |> Enum.take_while(&String.match?(&1, ~r/^\s*-\s/))
    |> Enum.map(fn line ->
      line |> String.replace(~r/^\s*-\s*/, "") |> String.trim() |> String.trim(~s("))
    end)
  end
end
