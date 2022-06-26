defmodule Siblings do
  @moduledoc """
  The topmost supervisor, carrying all the workers.
  """

  use Supervisor
  use Boundary, exports: [Worker]

  alias Siblings.{InternalWorker, Worker}

  @doc """
  Starts the supervision subtree, holding the `PartitionSupervisor`.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    children = [
      # {Registry, keys: :unique, name: Registry.Siblings, partitions: System.schedulers_online()},
      {PartitionSupervisor, child_spec: DynamicSupervisor, name: name}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  @doc false
  @impl Supervisor
  def init(state), do: {:ok, state}

  @doc """
  Starts the supervised child under the `PartitionSupervisor`.
  """
  @spec start_child(module(), Worker.id(), Worker.payload(), InternalWorker.options()) ::
          DynamicSupervisor.on_start_child()
  def start_child(worker, id, payload, opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    {shutdown, opts} = Keyword.pop(opts, :shutdown, 5_000)

    spec = %{
      id: {worker, id},
      start: {Siblings.InternalWorker, :start_link, [worker, id, payload, opts]},
      restart: :transient,
      shutdown: shutdown
    }

    DynamicSupervisor.start_child({:via, PartitionSupervisor, {name, {worker, id}}}, spec)
  end
end
