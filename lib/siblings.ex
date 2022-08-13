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

  alias Siblings.{InternalWorker, InternalWorker.State, Lookup, Worker}

  @default_interval Application.compile_env(:siblings, :perform_interval, 5_000)

  @type worker :: %{
          module: module(),
          id: Worker.id(),
          payload: Worker.payload(),
          options: InternalWorker.options()
        }

  @doc """
  Starts the supervision subtree, holding the `PartitionSupervisor`.
  """
  def start_link(opts \\ []) do
    {name, opts} =
      Keyword.get_and_update(opts, :name, fn
        nil -> default_fqn() |> then(&{&1, &1})
        name -> {name, name}
      end)

    {workers, opts} = Keyword.pop(opts, :workers, [])

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
            options: [name: name, hibernate?: hibernate?, interval: interval]
          }
      end)

    result = Supervisor.start_link(Siblings, opts, name: sup_fqn(name))

    case lookup(name) do
      pid when is_pid(pid) -> GenServer.cast(pid, {:initialize, %{start: workers}})
      # start_workers(workers)
      nil -> nil
    end

    result
  end

  @doc false
  @impl Supervisor
  def init(opts) do
    {name, opts} = Keyword.pop(opts, :name, default_fqn())
    {lookup, _opts} = Keyword.pop(opts, :lookup, true)

    lookup =
      case lookup do
        true ->
          [{Lookup, payload: %{name: lookup_fqn(name), siblings: name}, name: lookup_fqn(name)}]

        _ ->
          []
      end

    children = [
      {PartitionSupervisor, child_spec: DynamicSupervisor, name: name} | lookup
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns the [child spec](https://hexdocs.pm/elixir/Supervisor.html#t:child_spec/0)
    for the named or unnamed `Siblings` process.

  Useful when many `Siblings` processes are running simultaneously.
  """
  @spec child_spec([
          {:name, module()} | {:lookup, boolean() | module()} | {:id, any()} | keyword()
        ]) ::
          Supervisor.child_spec()
  def child_spec(opts) do
    {id, opts} = Keyword.pop(opts, :id, Keyword.get(opts, :name, default_fqn()))
    %{id: id, start: {Siblings, :start_link, [opts]}}
  end

  @doc """
  Returns the state of the `Siblings` instance.
  """
  @spec state(module()) :: nil | Finitomata.State.t()
  def state(name \\ default_fqn()) do
    name
    |> lookup()
    |> case do
      pid when is_pid(pid) -> GenServer.call(pid, :state)
      nil -> nil
    end
  end

  @doc false
  @spec lookup(module(), boolean() | :never) :: nil | pid()
  def lookup(name \\ default_fqn(), try_cached? \\ true)

  def lookup(_name, :never), do: nil

  def lookup(name, false) do
    name
    |> sup_fqn()
    |> Process.whereis()
    |> case do
      pid when is_pid(pid) ->
        pid
        |> Supervisor.which_children()
        |> Enum.find(&match?({_name, _pid, :worker, [Lookup]}, &1))
        |> case do
          {_name, pid, :worker, _} -> pid
          nil -> nil
        end

      nil ->
        nil
    end
  end

  def lookup(name, true) do
    fqn = lookup_fqn(name)

    fqn
    |> Process.whereis()
    |> case do
      pid when is_pid(pid) -> pid
      _ -> lookup(name, false)
    end
  end

  @doc false
  @spec lookup?(module()) :: boolean()
  def lookup?(name \\ default_fqn()), do: not is_nil(lookup(name))

  @doc false
  @spec pid(module(), Worker.id()) :: pid()
  def pid(name \\ default_fqn(), id) do
    with {pid, _} when is_pid(pid) <- find_child(name, id, true), do: pid
  end

  @doc """
  Returns the state of the named worker.
  """
  @spec worker_state(module(), Worker.id()) :: State.t()
  def worker_state(name \\ default_fqn(), id) do
    name
    |> pid(id)
    |> InternalWorker.state()
  end

  @doc """
  Returns the payload of FSM behind the named worker.
  """
  @spec payload(module(), Worker.id()) :: Worker.payload()
  def payload(name \\ default_fqn(), id) do
    with {_ref, pid} <- worker_state(name, id).fsm,
         do: GenServer.call(pid, :state).payload
  end

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

  @spec do_start_child(module() | nil, worker(), boolean()) ::
          :ok | DynamicSupervisor.on_start_child()
  defp do_start_child(name, worker, true) do
    Lookup.put(name, worker)
  end

  defp do_start_child(name, worker, false) do
    case find_child(name, worker.id, false) do
      {pid, _child} ->
        {:error, {:already_started, pid}}

      nil ->
        {shutdown, opts} = Keyword.pop(worker.options, :shutdown, 5_000)
        opts = Keyword.put(opts, :lookup, Siblings.lookup(name))

        spec = %{
          id: Enum.join([worker.module, worker.id], ":"),
          start: {InternalWorker, :start_link, [worker.module, worker.id, worker.payload, opts]},
          restart: :transient,
          shutdown: shutdown
        }

        DynamicSupervisor.start_child(
          {:via, PartitionSupervisor, {name, {worker.module, worker.id}}},
          spec
        )
    end
  end

  @doc """
  Returns the child with the given `id`, or `nil` if there is none.
  """
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

  @doc """
  Returns the list of currently managed children.
  """
  @spec children(:pids | :states | :map | :id_pids, module(), boolean() | :never) :: [State.t()]
  def children(type \\ :states, name \\ default_fqn(), try_cached? \\ true),
    do: do_children(type, lookup(name, try_cached?), name)

  @spec do_children(:pids | :states | :map | :id_pids, nil | pid() | atom(), module()) ::
          [State.t()] | [pid]
  defp do_children(:map, nil, name) do
    for state <- do_children(:states, nil, name), into: %{}, do: {state.id, state}
  end

  defp do_children(:map, lookup, name) when is_pid(lookup) or is_atom(lookup) do
    for state <- do_children(:states, lookup, name), into: %{}, do: {state.id, state}
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
  def lookup_fqn(name_or_pid \\ default_fqn())
  def lookup_fqn(pid) when is_pid(pid), do: pid
  def lookup_fqn(name), do: Module.concat([name, "Lookup"])
end
