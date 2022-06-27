defmodule SiblingsTest do
  use ExUnit.Case
  doctest Siblings
  doctest Siblings.Worker

  setup_all do
    %{siblings: start_supervised!(Siblings)}
  end

  test "FSM" do
    Siblings.start_child(Siblings.Test.Worker, "MyWorker", %{pid: self()}, interval: 100)

    assert [{:undefined, _, :worker, [Siblings.InternalWorker]}] =
             DynamicSupervisor.which_children(
               {:via, PartitionSupervisor, {Siblings, {Siblings.Test.Worker, "MyWorker"}}}
             )

    assert_receive :s1_s2, 1_000
    assert_receive :s2_end, 1_000

    Process.sleep(100)

    assert [] ==
             DynamicSupervisor.which_children(
               {:via, PartitionSupervisor, {Siblings, {Siblings.Test.Worker, "MyWorker"}}}
             )
  end
end
