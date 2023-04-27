defmodule Siblings do
  from_readme =
    "README.md"
    |> File.read!()
    |> String.split("\n## Usage")
    |> Enum.at(1)
    |> String.split("\n## ")
    |> Enum.at(0)

  @moduledoc """
             Bolerplate to effectively handle many long-lived entities
             of the same shape, driven by FSM.

             """ <> from_readme

  use Supervisor
  use Boundary, deps: [PartitionSupervisor], exports: [Worker]

  require Logger

  alias Siblings.{InternalState, InternalWorker, InternalWorker.State, Lookup, Worker}

  @default_interval Application.compile_env(:siblings, :perform_interval, 5_000)

  @type worker :: %{
          module: module(),
          id: Worker.id(),
          payload: Worker.payload(),
          options: InternalWorker.options()
        }

  @type start_options :: [
          {:name, atom()}
          | {:workers, [worker() | {module(), keyword()}]}
          | {:callbacks, [function()]}
          | {:throttler, keyword()}
          | {:die_with_children, boolean() | (() -> :ok) | {(() -> :ok), non_neg_integer()}}
        ]

  @doc """
  Starts the supervision subtree, holding the `PartitionSupervisor`.

  This is the main entry point of `Siblings`.
    It starts the supervision tree, holding the partitioned
    `DynamicSupervisor`s, the lookup to access children,
    and the optional set of workers to start immediately.

  `Siblings` are fully controlled by _FSM_ instances. Children
    are added using `Siblings.Lookup` interface methods which go
    all the way through underlying _FSM_ implementation.

  `opts` might include:

  - `name: atom()` which is a name of the `Siblings` instance, defaults to `Siblings`
  - `workers: list()` the list of the workers to start imminently upon `Siblings` start
  - `throttler: keyword()` the throttler options, see `Siblings.Throttler` for details
  - `die_with_children: true | false | (-> :ok) | {(-> :ok), timeout}` shutdown
    the process when there is no more active child, defaults to `false`
    (if a function of arity 0 is given, it’ll be called before the process shuts down)
  - `callbacks: list()` the list of the handler to call back upon `Lookup` transitions
  """
  @spec start_link(start_options()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {name, opts} =
      Keyword.get_and_update(opts, :name, fn
        nil -> default_fqn() |> then(&{&1, &1})
        name -> {name, name}
      end)

    {workers, opts} = Keyword.pop(opts, :workers, [])
    {callbacks, opts} = Keyword.pop(opts, :callbacks, [])

    workers =
      Enum.map(workers, fn
        %{module: _, id: _} = worker ->
          worker

        {worker, opts} ->
          {id, opts} = Keyword.pop(opts, :id, worker)
          {interval, opts} = Keyword.pop(opts, :interval, @default_interval)
          {hibernate?, opts} = Keyword.pop(opts, :hibernate?, false)

          %{
            id: id,
            module: worker,
            payload: Map.new(opts),
            options: [hibernate?: hibernate?, interval: interval]
          }
      end)

    case Supervisor.start_link(Siblings, opts, name: sup_fqn(name)) do
      {:ok, pid} ->
        case lookup(name) do
          nil ->
            # credo:disable-for-next-line Credo.Check.Refactor.Nesting
            if [] != workers, do: Logger.warning("workers without lookup are not [yet] supported")

          fsm when is_pid(fsm) or is_atom(fsm) ->
            GenServer.cast(fsm, {:initialize, %{workers: workers, callbacks: callbacks}})
        end

        {:ok, pid}

      other ->
        other
    end
  end

  @doc false
  @impl Supervisor
  def init(opts) do
    {name, opts} = Keyword.pop(opts, :name, default_fqn())
    {lookup, opts} = Keyword.pop(opts, :lookup, true)
    {throttler, opts} = Keyword.pop(opts, :throttler, [])
    {die_with_children, _opts} = Keyword.pop(opts, :die_with_children, false)

    helpers = [
      {Siblings.Throttler, Keyword.put(throttler, :name, name)}
      | case lookup do
          true ->
            [{Lookup, payload: %{name: lookup_fqn(name), siblings: name}, name: lookup_fqn(name)}]

          _ ->
            []
        end
    ]

    state_opts =
      [name: name, pid: self()]
      |> Keyword.merge(
        case die_with_children do
          {cb, timeout} -> [callback: cb, timeout: timeout]
          cb when is_function(cb) -> [callback: cb]
          true -> [callback: true]
          _ -> [callback: false]
        end
      )

    children = [
      {InternalState, state_opts},
      {PartitionSupervisor, child_spec: DynamicSupervisor, name: name}
      | helpers
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns the [child spec](https://hexdocs.pm/elixir/Supervisor.html#t:child_spec/0)
    for the named or unnamed `Siblings` process.

  Useful when many `Siblings` processes are running simultaneously.
  """
  @spec child_spec(start_options()) :: Supervisor.child_spec()
  def child_spec(opts) do
    {id, opts} = Keyword.pop(opts, :id, Keyword.get(opts, :name, default_fqn()))
    %{id: id, start: {Siblings, :start_link, [opts]}}
  end

  @doc """
  Returns the states of all the workers as a map.
  """
  @spec states(module()) :: %{Worker.id() => Finitomata.State.t()}
  def states(name \\ default_fqn()), do: children(:map, name)

  @doc """
  Returns the state of the `Siblings` instance itself, of the named worker, or
    the named worker’s underlying _FSM_, depending on the first argument.
  """
  @spec state(
          request :: :instance | :sibling | :fsm | Worker.id(),
          Worker.id() | module(),
          module()
        ) ::
          nil | State.t() | Finitomata.State.t()
  def state(request \\ :instance, id \\ nil, name \\ default_fqn())

  def state(:instance, nil, name) do
    name
    |> lookup()
    |> case do
      pid when is_pid(pid) -> GenServer.call(pid, :state)
      nil -> nil
    end
  end

  def state(:instance, name, _name), do: state(:instance, nil, name)
  def state(id, nil, name), do: state(:fsm, id, name)
  def state(:sibling, id, name), do: name |> pid(id) |> InternalWorker.state()

  def state(:fsm, id, name) do
    %State{fsm: {_ref, pid}} = state(:sibling, id, name)
    GenServer.call(pid, :state)
  end

  @doc false
  @spec lookup(module(), true | false | :name | :never) :: nil | pid() | atom()
  def lookup(name \\ default_fqn(), try_cached? \\ true)
  def lookup(_name, :never), do: nil
  def lookup(name, false), do: find_helper_by_pid(name, Lookup)

  def lookup(name, try_cached?) do
    fqn = lookup_fqn(name)

    case {try_cached?, Process.whereis(fqn)} do
      {:name, pid} when is_pid(pid) -> fqn
      {true, pid} when is_pid(pid) -> pid
      _ -> lookup(name, false)
    end
  end

  @doc false
  @spec lookup?(module()) :: boolean()
  def lookup?(name \\ default_fqn()), do: not is_nil(lookup(name))

  @doc false
  @spec internal_state(module(), true | false | :name | :never) :: nil | pid() | atom()
  def internal_state(name \\ default_fqn(), try_cached? \\ true)
  def internal_state(_name, :never), do: nil
  def internal_state(name, false), do: find_helper_by_pid(name, InternalState)

  def internal_state(name, try_cached?) do
    fqn = internal_state_fqn(name)

    case {try_cached?, Process.whereis(fqn)} do
      {:name, pid} when is_pid(pid) -> fqn
      {true, pid} when is_pid(pid) -> pid
      _ -> internal_state(name, false)
    end
  end

  @doc false
  @spec internal_state?(module()) :: boolean()
  def internal_state?(name \\ default_fqn()), do: not is_nil(internal_state(name))

  @spec find_helper_by_pid(module(), module()) :: nil | pid()
  defp find_helper_by_pid(name, module) do
    name
    |> sup_fqn()
    |> Process.whereis()
    |> case do
      pid when is_pid(pid) ->
        pid
        |> Supervisor.which_children()
        |> Enum.find(&match?({_name, _pid, :worker, [^module]}, &1))
        |> case do
          {_name, pid, :worker, _} -> pid
          nil -> nil
        end

      nil ->
        nil
    end
  end

  @doc false
  @spec pid(module(), Worker.id()) :: pid()
  def pid(name \\ default_fqn(), id) do
    with {pid, _} when is_pid(pid) <- find_child(name, id, true), do: pid
  end

  @doc """
  Returns the payload of _FSM_ behind the named worker.
  """
  @spec payload(module(), Worker.id()) :: Worker.payload()
  def payload(name \\ default_fqn(), id), do: state(:fsm, id, name).payload

  @doc """
  Performs a `GenServer.call/3` on the named worker.
  """
  @spec call(module(), Worker.id(), Worker.message()) ::
          Worker.call_result() | {:error, :callback_not_implemented}
  def call(name \\ default_fqn(), id, message) do
    name
    |> pid(id)
    |> InternalWorker.call(message)
  end

  @doc """
  Performs a `GenServer.call/3` on all the workers.
  """
  @spec multi_call(module(), Worker.message()) ::
          [Worker.call_result() | {:error, :callback_not_implemented}]
  def multi_call(name \\ default_fqn(), message) do
    :pids
    |> children(name)
    |> Task.async_stream(&InternalWorker.call(&1, message))
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Resets the the named worker’s interval.
  """
  @spec reset(module(), Worker.id(), non_neg_integer()) :: :ok
  def reset(name \\ default_fqn(), id, interval) do
    name
    |> pid(id)
    |> InternalWorker.reset(interval)
  end

  @doc """
  Initiates the transition of the named worker.
  """
  @spec transition(
          module(),
          Worker.id(),
          Finitomata.Transition.event(),
          Finitomata.event_payload()
        ) :: :ok
  def transition(name \\ default_fqn(), id, event, payload) do
    name
    |> pid(id)
    |> InternalWorker.transition(event, payload)
  end

  @doc """
  Initiates the transition of all the workers.
  """
  @spec multi_transition(
          module(),
          Finitomata.Transition.event(),
          Finitomata.event_payload()
        ) :: :ok
  def multi_transition(name \\ default_fqn(), event, payload) do
    :pids
    |> children(name)
    |> Task.async_stream(&InternalWorker.transition(&1, event, payload))
    |> Stream.run()
  end

  @doc """
  Starts the supervised child under the `PartitionSupervisor`.
  """
  @spec start_child(module(), Worker.id(), Worker.payload(), InternalWorker.options()) ::
          :ok | DynamicSupervisor.on_start_child()
  def start_child(worker, id, payload, opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, default_fqn())

    do_start_child(
      name,
      %{module: worker, id: id, payload: payload, options: opts},
      lookup?(name)
    )
  end

  @spec do_start_child(name :: module() | nil, worker :: worker(), has_lookup? :: boolean()) ::
          :ok | DynamicSupervisor.on_start_child()
  defp do_start_child(name, worker, true) do
    case Lookup.get(name, worker.id) do
      nil -> Lookup.put(name, worker)
      pid when is_pid(pid) -> {:error, {:already_started, pid}}
    end
  end

  defp do_start_child(name, worker, false) do
    case find_child(name, worker.id, false) do
      nil -> Lookup.start_child(name, worker)
      {pid, _child} -> {:error, {:already_started, pid}}
    end
  end

  @doc false
  @spec find_child(module(), Worker.id(), boolean()) :: nil | State.t() | {pid(), State.t()}
  def find_child(name \\ default_fqn(), id, with_pid? \\ false),
    do: do_find_child(lookup(name), name, id, with_pid?)

  @spec do_find_child(nil | pid() | atom(), module(), Worker.id(), boolean()) ::
          nil | State.t() | {pid(), State.t()}
  defp do_find_child(nil, name, id, with_pid?) do
    children =
      for {_partition_id, dyn_sup_pid, :supervisor, [DynamicSupervisor]} <-
            PartitionSupervisor.which_children(name),
          {_name, pid, :worker, [InternalWorker]} <-
            DynamicSupervisor.which_children(dyn_sup_pid),
          %InternalWorker.State{id: ^id} = state <- [InternalWorker.state(pid)],
          do: {pid, state}

    case children do
      [{pid, child}] -> if with_pid?, do: {pid, child}, else: child
      [] -> nil
    end
  end

  defp do_find_child(lookup, _name, id, with_pid?) when is_pid(lookup) or is_atom(lookup) do
    with pid when is_pid(pid) <- Lookup.get(lookup, id) do
      state = InternalWorker.state(pid)
      if with_pid?, do: {pid, state}, else: state
    end
  end

  @doc false
  @spec children(:pids | :states | :map | :id_pids, module(), boolean() | :never) ::
          [State.t()] | [pid] | %{Worker.id() => pid()} | %{Worker.id() => Finitomata.State.t()}
  def children(type \\ :states, name \\ default_fqn(), try_cached? \\ true),
    do: do_children(type, lookup(name, try_cached?), name)

  @spec do_children(:pids | :states | :map | :id_pids, nil | pid() | atom(), module()) ::
          [State.t()] | [pid] | %{Worker.id() => pid()} | %{Worker.id() => Finitomata.State.t()}
  defp do_children(:map, nil, name) do
    for %InternalWorker.State{id: id, fsm: {_ref, pid}} <- do_children(:states, nil, name),
        into: %{},
        do: {id, GenServer.call(pid, :state)}
  end

  defp do_children(:map, lookup, name) when is_pid(lookup) or is_atom(lookup) do
    for %InternalWorker.State{id: id, fsm: {_ref, pid}} <- do_children(:states, lookup, name),
        into: %{},
        do: {id, GenServer.call(pid, :state)}
  end

  defp do_children(:pids, nil, name) do
    for {_partition_id, dyn_sup_pid, :supervisor, [DynamicSupervisor]} <-
          PartitionSupervisor.which_children(name),
        {_name, pid, :worker, [InternalWorker]} <- DynamicSupervisor.which_children(dyn_sup_pid),
        do: pid
  end

  defp do_children(:pids, lookup, _name) when is_pid(lookup) or is_atom(lookup) do
    for {_id, pid} <- Lookup.all(lookup), do: pid
  end

  defp do_children(:states, lookup, name) when is_pid(lookup) or is_atom(lookup),
    do: :pids |> do_children(lookup, name) |> Enum.map(&InternalWorker.state/1)

  defp do_children(:id_pids, lookup, name) when is_pid(lookup) or is_atom(lookup) do
    for pid <- do_children(:pids, lookup, name), into: %{} do
      {InternalWorker.state(pid).id, pid}
    end
  end

  @spec default_fqn :: module()
  @doc false
  def default_fqn, do: __MODULE__

  @spec sup_fqn(module()) :: module()
  @doc false
  defp sup_fqn(name), do: Module.concat(name, Supervisor)

  @spec lookup_fqn(pid() | module()) :: module()
  @doc false
  def lookup_fqn(name_or_pid \\ default_fqn())
  def lookup_fqn(pid) when is_pid(pid), do: pid
  def lookup_fqn(name), do: Module.concat([name, "Lookup"])

  @spec internal_state_fqn(pid() | module()) :: module()
  @doc false
  def internal_state_fqn(name_or_pid \\ default_fqn())
  def internal_state_fqn(pid) when is_pid(pid), do: pid
  def internal_state_fqn(name), do: Module.concat([name, "InternalState"])

  @spec throttler_fqn(pid() | module()) :: module()
  @doc false
  def throttler_fqn(name_or_pid \\ default_fqn())
  def throttler_fqn(pid) when is_pid(pid), do: pid
  def throttler_fqn(name), do: Module.concat([name, "Throttler"])
end
