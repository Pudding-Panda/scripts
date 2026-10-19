defmodule DevtimeServer.ReportCadenceTest do
  use ExUnit.Case

  alias DevtimeServer.Report

  test "interleaved timers with a late tick are machine, scattered prompts are not" do
    timer_a = for k <- 0..9, do: 1_000 + k * 1806
    timer_b = for k <- 0..9, do: 1_400 + k * 1800
    late = [5_000, 6_806, 8_612, 10_418, 13_100, 14_906, 16_712, 18_518]
    human = [1_150, 1_190, 2_777, 4_321, 9_999, 12_345]

    all = Enum.sort(timer_a ++ timer_b ++ late ++ human)
    marked = Report.cadence_indices(List.to_tuple(all), 5, 5)
    machine = marked |> Enum.map(&Enum.at(all, &1)) |> MapSet.new()

    assert MapSet.subset?(MapSet.new(timer_a ++ timer_b ++ late), machine)
    assert MapSet.disjoint?(MapSet.new(human), machine)
  end
end
