defmodule Troupe.WorkerProfileUpgradeTest do
  @moduledoc """
  The two halves of a worker upgrade as the plane and the operator read them from one
  `WorkerProfile` (Decision 726): the pods the operator reports behind, and the drains
  the plane has recorded. Both are read by the other side, so what either writes badly
  has to read as nothing rather than as a pod to drain or to delete.
  """

  use ExUnit.Case, async: true

  alias Troupe.WorkerProfile

  test "a recorded drain reads back as it was written" do
    drained = %{"troupe-w-dev-1" => "troupe-w-dev-7c9f", "troupe-w-dev-0" => "troupe-w-dev-7c9f"}
    resource = annotated(WorkerProfile.encode_drained(drained))

    assert WorkerProfile.drained(resource) == drained
  end

  test "no record, or one that does not read, is nothing drained" do
    assert WorkerProfile.drained(%{"metadata" => %{}}) == %{}
    assert WorkerProfile.drained(annotated("not json")) == %{}
    assert WorkerProfile.drained(annotated(~s(["troupe-w-dev-1"]))) == %{}

    # A pod without a revision would match a pod without a revision label.
    assert WorkerProfile.drained(annotated(~s({"troupe-w-dev-1": null, "troupe-w-dev-0": "a"}))) ==
             %{"troupe-w-dev-0" => "a"}
  end

  test "the pods behind are read from the status, and only entries that name a pod" do
    resource = %{
      "status" => %{
        "podsBehind" => [
          %{"pod" => "troupe-w-dev-0", "uid" => "u-0", "revision" => "troupe-w-dev-a"},
          %{"uid" => "u-1"},
          %{"pod" => "troupe-w-dev-2"}
        ]
      }
    }

    assert WorkerProfile.pods_behind(resource) == [
             %{pod: "troupe-w-dev-0", uid: "u-0", revision: "troupe-w-dev-a"},
             %{pod: "troupe-w-dev-2", uid: nil, revision: nil}
           ]

    assert WorkerProfile.pods_behind(%{"status" => %{}}) == []
  end

  defp annotated(value) do
    %{"metadata" => %{"annotations" => %{WorkerProfile.drained_annotation() => value}}}
  end
end
