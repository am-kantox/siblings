defmodule SiblingsTest do
  use ExUnit.Case, async: true

  doctest Siblings
  doctest Siblings.Worker

  setup do
    %{
      siblings: start_supervised!(Siblings),
      my_siblings: start_supervised!(Siblings.child_spec(name: MySiblings))
    }

    # on_exit(fn -> Process.sleep(100) end)
  end

  test "Worker with FSM" do
    {:ok, pid} =
      Siblings.start_child(Siblings.Test.Worker, "MyWorker", %{pid: self()},
        name: MySiblings,
        interval: 200
      )

    assert {:error, {:already_started, ^pid}} =
             Siblings.start_child(Siblings.Test.Worker, "MyWorker", %{pid: self()},
               name: MySiblings,
               interval: 200
             )

    assert [%Siblings.InternalWorker.State{id: "MyWorker"}] =
             Siblings.children(:states, MySiblings)

    assert %{"MyWorker" => %Siblings.InternalWorker.State{id: "MyWorker"}} =
             Siblings.children(:map, MySiblings)

    assert_receive :s1_s2, 1_000
    assert_receive :s2_end, 1_000

    Process.sleep(100)

    assert [] == Siblings.children(:states, MySiblings)
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

  test "#multi_transition/3" do
    {:ok, _pid1} =
      Siblings.start_child(Siblings.Test.NoPerform, "NoPerform1", %{pid: self()}, interval: 60_000)

    {:ok, _pid2} =
      Siblings.start_child(Siblings.Test.NoPerform, "NoPerform2", %{pid: self()}, interval: 60_000)

    Siblings.multi_transition(:to_s2, nil)

    assert_receive :s1_s2
    assert_receive :s1_s2

    Siblings.multi_transition(:to_s3, nil)
    Siblings.multi_transition(:__end__, nil)

    assert_receive :s3_end
    assert_receive :s3_end

    Process.sleep(100)

    assert [] == Siblings.children()
  end

  test "#call/3" do
    {:ok, _pid1} =
      Siblings.start_child(Siblings.Test.NoPerform, "Callable1", %{pid: self()}, interval: 60_000)

    {:ok, _pid2} =
      Siblings.start_child(Siblings.Test.Callable, "Callable2", %{pid: self()}, interval: 60_000)

    assert {:error, :callback_not_implemented} == Siblings.call("Callable1", 42)
    assert 84 == Siblings.call("Callable2", 42)

    Siblings.multi_transition(:to_s2, nil)
    Siblings.multi_transition(:to_s3, nil)
    Siblings.multi_transition(:__end__, nil)

    Process.sleep(100)

    assert [] == Siblings.children()
  end

  test "#multi_call/2" do
    {:ok, _pid1} =
      Siblings.start_child(Siblings.Test.NoPerform, "Callable1", %{pid: self()}, interval: 60_000)

    {:ok, _pid2} =
      Siblings.start_child(Siblings.Test.Callable, "Callable2", %{pid: self()}, interval: 60_000)

    assert [84, {:error, :callback_not_implemented}] == Enum.sort(Siblings.multi_call(42))

    Siblings.multi_transition(:to_s2, nil)
    Siblings.multi_transition(:to_s3, nil)
    Siblings.multi_transition(:__end__, nil)

    Process.sleep(100)

    assert [] == Siblings.children()
  end
end
