defmodule Siblings.Test.Siblings do
  use ExUnit.Case, async: true

  doctest Siblings
  doctest Siblings.InternalWorker
  doctest Siblings.Worker

  alias Siblings.InternalWorker

  setup do
    %{
      siblings: start_supervised!(Siblings),
      my_siblings:
        start_supervised!(
          Siblings.child_spec(name: MySiblings, lookup: :none, die_with_children: false),
          restart: :temporary
        ),
      my_siblings_with_killer:
        start_supervised!(
          Siblings.child_spec(
            name: MySiblingsWithKiller,
            lookup: :none,
            die_with_children: fn data -> assert %{id: "MyWorkerFSM"} = data end
          ),
          restart: :temporary
        ),
      init_siblings:
        start_supervised!(
          Siblings.child_spec(
            name: InitSiblings,
            workers: [{Siblings.Test.Worker, id: "InitWorker"}]
          )
        )
    }

    # on_exit(fn -> Process.sleep(1_000) end)
  end

  test "Worker with FSM" do
    Siblings.start_child(Siblings.Test.Worker, "MyWorker", %{pid: self()},
      name: MySiblings,
      hibernate?: true,
      interval: 200
    )

    assert [%InternalWorker.State{id: "MyWorker"}] = Siblings.children(:states, MySiblings)
    assert %{"MyWorker" => %Finitomata.State{current: :s1}} = Siblings.children(:map, MySiblings)

    assert_receive :s1_s2, 1_000
    assert_receive :s2_end, 1_000

    Process.sleep(200)

    assert [] == Siblings.children(:states, MySiblings)
  end

  test "Worker-FSM" do
    Siblings.start_child(Siblings.Test.WorkerFSM, "MyWorkerFSM", %{pid: self()}, interval: 200)

    {pid, _} = Siblings.find_child(Siblings, "MyWorkerFSM", true)

    assert [%InternalWorker.State{id: "MyWorkerFSM"}] = Siblings.children()
    assert %{"MyWorkerFSM" => %Finitomata.State{current: :s1}} = Siblings.states()
    assert %{"MyWorkerFSM" => %Finitomata.State{current: :s1}} = Siblings.children(:map)

    assert %Finitomata.State{current: :ready, payload: %{workers: %{"MyWorkerFSM" => _}}} =
             Siblings.state()

    assert %Finitomata.State{current: :ready, payload: %{workers: %{"MyWorkerFSM" => _}}} =
             Siblings.state(:instance, Siblings)

    assert %Siblings.InternalWorker.State{id: "MyWorkerFSM"} =
             Siblings.state(:sibling, "MyWorkerFSM")

    assert %Finitomata.State{current: :s1} = Siblings.state("MyWorkerFSM")
    assert %Finitomata.State{current: :s1} = Siblings.state(:fsm, "MyWorkerFSM")

    assert_receive :s1_s2, 1_000
    refute_receive :s3_end, 1_000

    InternalWorker.transition(pid, :to_s3)

    assert_receive :s3_end, 1_000

    Process.sleep(200)

    assert [] == Siblings.children()
    assert Process.whereis(MySiblings)
  end

  test "Worker-FSM with Killer" do
    Siblings.start_child(Siblings.Test.WorkerFSM, "MyWorkerFSM", %{pid: self()},
      name: MySiblingsWithKiller,
      interval: 100
    )

    assert Process.whereis(MySiblingsWithKiller.Killer)

    assert_receive :s1_s2, 1_000
    refute_receive :s3_end, 1_000

    Siblings.transition(MySiblingsWithKiller, "MyWorkerFSM", :to_s3, nil)
    assert_receive :s3_end, 1_000

    Process.sleep(5_100)
    refute Process.whereis(MySiblingsWithKiller.Killer)
    refute Process.whereis(MySiblingsWithKiller)
  end

  test "#multi_transition/3" do
    Siblings.start_child(Siblings.Test.NoPerform, "NoPerform1", %{pid: self()}, interval: 60_000)
    Siblings.start_child(Siblings.Test.NoPerform, "NoPerform2", %{pid: self()}, interval: 60_000)

    Siblings.multi_transition(:to_s2, nil)

    assert_receive :s1_s2
    assert_receive :s1_s2

    Siblings.multi_transition(:to_s3, nil)
    Siblings.multi_transition(:__end__, nil)

    assert_receive :s3_end
    assert_receive :s3_end

    Process.sleep(200)

    assert [] == Siblings.children()
  end

  test "#call/3" do
    Siblings.start_child(Siblings.Test.NoPerform, "Callable1", %{pid: self()}, interval: 60_000)
    Siblings.start_child(Siblings.Test.Callable, "Callable2", %{pid: self()}, interval: 60_000)

    assert {:error, :callback_not_implemented} == Siblings.call("Callable1", 42)
    assert 84 == Siblings.call("Callable2", 42)

    Siblings.multi_transition(:to_s2, nil)
    Siblings.multi_transition(:to_s3, nil)
    Siblings.multi_transition(:__end__, nil)

    Process.sleep(200)

    assert [] == Siblings.children()
  end

  test "#multi_call/2" do
    Siblings.start_child(Siblings.Test.NoPerform, "Callable1", %{pid: self()}, interval: 60_000)
    Siblings.start_child(Siblings.Test.Callable, "Callable2", %{pid: self()}, interval: 60_000)

    assert [84, {:error, :callback_not_implemented}] == Enum.sort(Siblings.multi_call(42))

    Siblings.multi_transition(:to_s2, nil)
    Siblings.multi_transition(:to_s3, nil)
    Siblings.multi_transition(:__end__, nil)

    Process.sleep(200)

    assert [] == Siblings.children()
  end
end
