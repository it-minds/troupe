defmodule Troupe.AskUserTest do
  use ExUnit.Case, async: true

  alias Troupe.Tools.AskUser

  describe "normalize/1" do
    test "a bare question has no options and is single-choice" do
      assert AskUser.normalize(%{"question" => "Which database?"}) ==
               %{question: "Which database?", options: [], multiple: false}
    end

    test "options may be plain strings" do
      assert %{options: [%{label: "postgres", description: nil}, %{label: "sqlite"}]} =
               AskUser.normalize(%{
                 "question" => "Which?",
                 "options" => ["postgres", "sqlite"]
               })
    end

    test "options may be objects with a label and a description" do
      assert %{options: [%{label: "postgres", description: "what production runs"}]} =
               AskUser.normalize(%{
                 "question" => "Which?",
                 "options" => [
                   %{"label" => "postgres", "description" => "what production runs"}
                 ]
               })
    end

    # Models reach for whichever key they remember; all of them mean the label.
    test "a label is taken from name, value, text or title too" do
      for key <- ["name", "value", "text", "title"] do
        assert %{options: [%{label: "postgres"}]} =
                 AskUser.normalize(%{"question" => "q", "options" => [%{key => "postgres"}]})
      end
    end

    test "blank and unusable options are dropped, duplicates collapse" do
      assert %{options: [%{label: "keep"}]} =
               AskUser.normalize(%{
                 "question" => "q",
                 "options" => ["", "   ", %{}, nil, "keep", "keep", %{"label" => "keep"}]
               })
    end

    test "a label is flattened to one line so it cannot abort a frame" do
      assert %{options: [%{label: "first second"}]} =
               AskUser.normalize(%{"question" => "q", "options" => ["first\n\nsecond"]})
    end

    test "more options than there are digit keys are cut off" do
      options = Enum.map(1..30, &"option #{&1}")
      normalized = AskUser.normalize(%{"question" => "q", "options" => options})

      assert length(normalized.options) == AskUser.max_options()
      assert List.first(normalized.options).label == "option 1"
    end

    test "multiple is only true when actually asked for" do
      assert AskUser.normalize(%{"question" => "q", "multiple" => true}).multiple
      assert AskUser.normalize(%{"question" => "q", "multiple" => "true"}).multiple
      refute AskUser.normalize(%{"question" => "q"}).multiple
      refute AskUser.normalize(%{"question" => "q", "multiple" => "no"}).multiple
      refute AskUser.normalize(%{"question" => "q", "multiple" => nil}).multiple
    end

    test "junk in place of options or the whole input does not raise" do
      assert %{options: []} = AskUser.normalize(%{"question" => "q", "options" => "postgres"})
      assert %{question: "", options: []} = AskUser.normalize(%{})
      assert %{question: "", options: []} = AskUser.normalize(nil)
    end

    test "a non-string question is coerced rather than rejected" do
      assert %{question: "42"} = AskUser.normalize(%{"question" => 42})
    end
  end

  describe "answer_text/1" do
    test "selected labels go back as the labels themselves, not indices" do
      assert AskUser.answer_text(["postgres"]) == "postgres"
      assert AskUser.answer_text(["postgres", "sqlite"]) == "postgres, sqlite"
      assert AskUser.answer_text([]) == ""
    end
  end
end
