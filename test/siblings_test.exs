defmodule SiblingsTest do
  use ExUnit.Case
  doctest Siblings
  doctest Siblings.Worker

  import ExUnit.CaptureLog

  def setup_all do
  end

  test "FSM" do
    start_supervised(Siblings)

    log =
      capture_log(fn ->
        Siblings.start_child(Siblings.Test.Worker, "MyWorker", %{foo: :bar}, interval: 100)
        Process.sleep(1_000)
      end)

    assert log =~ ~r/PERFORM 1: {:s1, "MyWorker", %{foo: :bar}}/
    assert log =~ ~r/PERFORM 2: {:s2, "MyWorker", %{foo: :bar}}/

    assert [] ==
             DynamicSupervisor.which_children(
               {:via, PartitionSupervisor, {Siblings, {Siblings.Test.Worker, "MyWorker"}}}
             )
  end
end
