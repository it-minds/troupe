defmodule SampleRepoTest do
  use ExUnit.Case

  test "sums integers" do
    assert SampleRepo.sum([1, 2, 3]) == 6
  end
end
