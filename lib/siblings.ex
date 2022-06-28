defmodule Siblings do
  @moduledoc """
  `Siblings` is the bolerplate to effectively handle many long-lived entities
  of the same shape, driven by FSM.

  Once started,
  """

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
  @spec lookup :: nil | pid()
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

  @doc """
  Starts the supervised child under the `PartitionSupervisor`.
  """
  @spec start_child(module(), Worker.id(), Worker.payload(), InternalWorker.options()) ::
          DynamicSupervisor.on_start_child()
  def start_child(worker, id, payload, opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, default_fqn())
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

  @doc """
  Returns the children with the given `id`.
  """
  @spec children_by_id(module(), Worker.id()) :: [State.t()]
  def children_by_id(name \\ default_fqn(), id) do
    for {_partition_id, pid, :supervisor, [DynamicSupervisor]} <-
          PartitionSupervisor.which_children(name),
        {_name, pid, :worker, [InternalWorker]} <- DynamicSupervisor.which_children(pid),
        %InternalWorker.State{id: ^id} = state <- [InternalWorker.state(pid)],
        do: state
  end

  @doc """
  Returns the list of currently managed children.
  """
  @spec children(module()) :: [State.t()]
  def children(name \\ default_fqn()), do: do_children(lookup(), name)

  @spec do_children(boolean(), module()) :: [State.t()]
  defp do_children(nil, name) do
    for {_partition_id, pid, :supervisor, [DynamicSupervisor]} <-
          PartitionSupervisor.which_children(name),
        {_name, pid, :worker, [InternalWorker]} <- DynamicSupervisor.which_children(pid),
        do: InternalWorker.state(pid)
  end

  defp do_children(lookup, name) when is_atom(lookup) do
    name
    |> lookup.lookup_fqn()
    |> lookup.all()
    |> Map.values()
    |> List.flatten()
    |> Enum.map(&InternalWorker.state/1)
  end

  @spec default_fqn :: module()
  @doc false
  def default_fqn, do: __MODULE__

  @spec sup_fqn(module()) :: module()
  @doc false
  defp sup_fqn(name), do: Module.concat(name, Supervisor)
end
