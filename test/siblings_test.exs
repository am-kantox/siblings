defmodule SiblingsTest do
  use ExUnit.Case
  doctest Siblings
  doctest Siblings.Worker

  setup_all do
    %{siblings: start_supervised!(Siblings)}
  end

  test "Worker with FSM" do
    {:ok, pid} =
      Siblings.start_child(Siblings.Test.Worker, "MyWorker", %{pid: self()}, interval: 200)

    assert {:error, {:already_started, ^pid}} =
             Siblings.start_child(Siblings.Test.Worker, "MyWorker", %{pid: self()}, interval: 200)

    assert [%Siblings.InternalWorker.State{id: "MyWorker"}] = Siblings.children()

    assert %{"MyWorker" => %Siblings.InternalWorker.State{id: "MyWorker"}} =
             Siblings.children(:map)

    assert_receive :s1_s2, 1_000
    assert_receive :s2_end, 1_000

    Process.sleep(100)

    assert [] == Siblings.children()
  end

  test "Worker-FSM" do
    {:ok, pid} =
      Siblings.start_child(Siblings.Test.WorkerFSM, "MyWorkerFSM", %{pid: self()}, interval: 200)

    assert {:error, {:already_started, ^pid}} =
             Siblings.start_child(Siblings.Test.Worker, "MyWorkerFSM", %{pid: self()},
               interval: 200
             )

    assert [%Siblings.InternalWorker.State{id: "MyWorkerFSM"}] = Siblings.children()

    assert %{"MyWorkerFSM" => %Siblings.InternalWorker.State{id: "MyWorkerFSM"}} =
             Siblings.children(:map)

    assert_receive :s1_s2, 1_000
    refute_receive :s3_end, 1_000

    Siblings.InternalWorker.transition(pid, :to_s3)

    assert_receive :s3_end, 1_000
    Process.sleep(100)

    assert [] == Siblings.children()
  end
end
