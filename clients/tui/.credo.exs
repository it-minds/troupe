%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/", "config/"], excluded: ["deps/", "_build/"]},
      # The umbrella's own check, beside the harness this project is built with.
      requires: ["../../apps/troupe_protocol/credo/*.ex"],
      strict: true,
      checks: %{
        disabled: [
          {Credo.Check.Readability.ModuleDoc, []},
          {Credo.Check.Design.TagTODO, []},
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Refactor.Nesting, []},
          {Credo.Check.Design.AliasUsage, []}
        ],
        # A program started by name is found on PATH alone, through
        # Troupe.OS.Process.executable/2 (Decision 846); tests may use find_executable.
        extra: [
          {Troupe.Credo.PathOnlyLookup, [files: %{included: ["lib/"]}]}
        ]
      }
    }
  ]
}
