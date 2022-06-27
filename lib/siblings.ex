defmodule Siblings do
  @moduledoc """
  `Siblings` is the bolerplate to effectively handle many long-lived entities
  of the same shape, driven by FSM.

  Once started,
  """

  use Supervisor
  use Boundary, exports: [Worker]

  alias Siblings.{InternalWorker, Lookup, Worker}

  @doc """
  Starts the supervision subtree, holding the `PartitionSupervisor`.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    lookup =
      case Keyword.get(opts, :lookup, :agent) do
        :agent -> [Lookup]
        _ -> []
      end

    children = [{PartitionSupervisor, child_spec: DynamicSupervisor, name: name} | lookup]

    Supervisor.start_link(children, strategy: :one_for_one, name: Siblings.Supervisor)
  end

  @doc false
  @impl Supervisor
  def init(state), do: {:ok, state}

  @doc false
  @spec has_lookup? :: boolean()
  def has_lookup? do
    Siblings.Supervisor
    |> Supervisor.which_children()
    |> Enum.any?(&match?({_name, _pid, :worker, [Lookup]}, &1))
  end

  @doc """
  Starts the supervised child under the `PartitionSupervisor`.
  """
  @spec start_child(module(), Worker.id(), Worker.payload(), InternalWorker.options()) ::
          DynamicSupervisor.on_start_child()
  def start_child(worker, id, payload, opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    {shutdown, opts} = Keyword.pop(opts, :shutdown, 5_000)

    spec = %{
      id: worker,
      start: {InternalWorker, :start_link, [worker, id, payload, opts]},
      restart: :transient,
      shutdown: shutdown
    }

    DynamicSupervisor.start_child({:via, PartitionSupervisor, {name, worker}}, spec)
  end

  @doc """
  Returns the child with the given `id` or `nil` if there is no such child.
  """
  @spec find_child(module(), module(), Worker.id()) :: State.t() | nil
  def find_child(name \\ __MODULE__, worker, id) do
    {:via, PartitionSupervisor, {name, worker}}
    |> DynamicSupervisor.which_children()
    |> Enum.find(fn
      {_name, pid, :worker, [InternalWorker]} ->
        match?(%InternalWorker.State{id: ^id}, InternalWorker.state(pid))

      _ ->
        false
    end)
  end

  @doc """
  Returns the list of currently managed children.
  """
  @spec children(module(), module()) :: [State.t()]
  def children(name \\ __MODULE__, worker) do
    {:via, PartitionSupervisor, {name, worker}}
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_name, pid, :worker, [InternalWorker]} -> [InternalWorker.state(pid)]
      _ -> []
    end)
  end
end
