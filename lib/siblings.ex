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

  @doc """
  Starts the supervision subtree, holding the `PartitionSupervisor`.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, default_fqn())

    lookup =
      case Keyword.get(opts, :lookup, :agent) do
        :agent -> [{Lookup, name: name}]
        _ -> []
      end

    children = [{PartitionSupervisor, child_spec: DynamicSupervisor, name: name} | lookup]

    Supervisor.start_link(children, strategy: :one_for_one, name: sup_fqn(name))
  end

  @doc false
  @impl Supervisor
  def init(state), do: {:ok, state}

  @doc false
  @spec lookup :: nil | pid() | atom()
  def lookup(name \\ default_fqn()) do
    fqn = Siblings.Lookup.lookup_fqn(name)

    fqn
    |> Process.whereis()
    |> is_pid()
    |> if do
      fqn
    else
      name
      |> sup_fqn()
      |> Supervisor.which_children()
      |> Enum.find(&match?({_name, _pid, :worker, [Lookup]}, &1))
      |> then(fn
        {_name, pid, :worker, [Lookup]} -> pid
        _ -> nil
      end)
    end
  end

  @doc false
  @spec lookup? :: boolean()
  def lookup?, do: not is_nil(lookup())

  @doc false
  @spec pid(module(), Worker.id()) :: pid()
  def pid(name \\ default_fqn(), id) do
    name
    |> find_child(id, true)
    |> elem(0)
  end

  @doc """
  Returns the state of the named worker.
  """
  @spec state(module(), Worker.id()) :: State.t()
  def state(name \\ default_fqn(), id) do
    name
    |> pid(id)
    |> InternalWorker.state()
  end

  @doc """
  Returns the payload of FSM behind the named worker.
  """
  @spec payload(module(), Worker.id()) :: Worker.payload()
  def payload(name \\ default_fqn(), id) do
    case state(name, id).fsm do
      {_ref, pid} -> GenServer.call(pid, :state).payload
      nil -> nil
    end
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
  Starts the supervised child under the `PartitionSupervisor`.
  """
  @spec start_child(module(), Worker.id(), Worker.payload(), InternalWorker.options()) ::
          DynamicSupervisor.on_start_child()
  def start_child(worker, id, payload, opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, default_fqn())

    case find_child(name, id, true) do
      {pid, _child} ->
        {:error, {:already_started, pid}}

      nil ->
        {shutdown, opts} = Keyword.pop(opts, :shutdown, 5_000)
        opts = Keyword.put(opts, :lookup, Siblings.lookup(name))

        spec = %{
          id: worker,
          start: {InternalWorker, :start_link, [worker, id, payload, opts]},
          restart: :transient,
          shutdown: shutdown
        }

        DynamicSupervisor.start_child({:via, PartitionSupervisor, {name, {worker, id}}}, spec)
    end
  end

  @doc """
  Returns the child with the given `id`, or `nil` if there is none.
  """
  @spec find_child(module(), Worker.id(), boolean()) :: nil | State.t() | {pid(), State.t()}
  def find_child(name \\ default_fqn(), id, with_pid? \\ false),
    do: do_find_child(lookup(), name, id, with_pid?)

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
    lookup
    |> Lookup.get(id)
    |> then(fn
      nil ->
        nil

      pid when is_pid(pid) ->
        state = InternalWorker.state(pid)
        if with_pid?, do: {pid, state}, else: state
    end)
  end

  @doc """
  Returns the list of currently managed children.
  """
  @spec children(:list | :map, module()) :: [State.t()]
  def children(type \\ :list, name \\ default_fqn()), do: do_children(type, lookup(), name)

  @spec do_children(:list | :map, nil | pid() | atom(), module()) :: [State.t()]
  defp do_children(:map, nil, name) do
    for state <- do_children(:list, nil, name), into: %{}, do: {state.id, state}
  end

  defp do_children(:map, lookup, _name) when is_pid(lookup) or is_atom(lookup) do
    for {id, pid} <- Lookup.all(lookup), into: %{}, do: {id, InternalWorker.state(pid)}
  end

  defp do_children(:list, nil, name) do
    for {_partition_id, dyn_sup_pid, :supervisor, [DynamicSupervisor]} <-
          PartitionSupervisor.which_children(name),
        {_name, pid, :worker, [InternalWorker]} <- DynamicSupervisor.which_children(dyn_sup_pid),
        do: InternalWorker.state(pid)
  end

  defp do_children(:list, lookup, _name) when is_pid(lookup) or is_atom(lookup) do
    lookup
    |> Lookup.all()
    |> Map.values()
    |> Enum.map(&InternalWorker.state/1)
  end

  @spec default_fqn :: module()
  @doc false
  def default_fqn, do: __MODULE__

  @spec sup_fqn(module()) :: module()
  @doc false
  defp sup_fqn(name), do: Module.concat(name, Supervisor)
end
