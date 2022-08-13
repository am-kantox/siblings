defmodule Siblings.Lookup do
  @moduledoc false

  use Agent

  use Boundary, deps: [Siblings]

  alias Siblings.{InternalWorker, Worker}

  @fsm """
  idle --> |initialize| ready
  ready --> |start_child| ready
  ready --> |delete_child| ready
  ready --> |terminate| terminated
  """

  use Finitomata, @fsm

  @impl Finitomata
  def on_transition(:idle, :initialize, payload, state) do
    children = Siblings.children(:id_pids, state[:siblings], :never)

    workers =
      payload
      |> Map.get(:start, [])
      |> Enum.reduce(children, fn payload, acc ->
        # [AM] Doc + Log on failures
        case on_transition(:ready, :start_child, payload, acc) do
          {:ok, :ready, acc} -> acc
          _ -> acc
        end
      end)

    {:ok, :ready, Map.put(state, :workers, workers)}
  end

  @impl Finitomata
  def on_transition(:ready, :delete_child, %{id: id}, %{workers: workers} = state) do
    if Map.has_key?(workers, id),
      do: {:ok, :ready, %{state | workers: Map.delete(workers, id)}},
      else: :noop
  end

  @impl Finitomata
  def on_transition(:ready, :start_child, payload, %{workers: workers} = state) do
    if Map.has_key?(workers, payload.id) and Process.alive?(Map.get(workers, payload.id)) do
      :noop
    else
      {:ok, pid} = start_child(state.siblings, payload)
      {:ok, :ready, %{state | workers: Map.put(workers, payload.id, pid)}}
    end
  end

  @spec all(module()) :: %{Worker.id() => pid()}
  def all(name \\ Siblings.default_fqn()) do
    name
    |> Siblings.lookup_fqn()
    |> GenServer.call(:state)
    |> case do
      %Finitomata.State{payload: %{workers: workers}} -> workers
      _ -> %{}
    end
  end

  @spec get(module(), Worker.id()) :: pid()
  def get(name \\ Siblings.default_fqn(), id, default \\ nil) do
    name |> all() |> Map.get(id, default)
  end

  @spec put(module(), Siblings.worker()) :: :ok
  def put(name \\ Siblings.default_fqn(), worker) do
    name
    |> Siblings.lookup_fqn()
    |> GenServer.cast({:start_child, worker})
  end

  @spec del(module(), Worker.id()) :: :ok
  def del(name \\ Siblings.default_fqn(), id) do
    name |> Siblings.lookup_fqn() |> GenServer.cast({:delete_child, %{id: id}})
  end

  @spec start_child(module(), Siblings.worker()) :: DynamicSupervisor.on_start_child()
  defp start_child(name, %{module: worker, id: id} = worker_spec) do
    payload = Map.get(worker_spec, :payload, %{})
    opts = Map.get(worker_spec, :options, [])
    {shutdown, opts} = Keyword.pop(opts, :shutdown, 5_000)
    opts = Keyword.put(opts, :lookup, Siblings.lookup(name))

    spec = %{
      id: Enum.join([worker, id], ":"),
      start: {InternalWorker, :start_link, [worker, id, payload, opts]},
      restart: :transient,
      shutdown: shutdown
    }

    DynamicSupervisor.start_child({:via, PartitionSupervisor, {name, {worker, id}}}, spec)
  end

  # @spec lookup_fqn(pid() | module()) :: module()
  # def lookup_fqn(name_or_pid \\ Siblings.default_fqn())
  # def lookup_fqn(pid) when is_pid(pid), do: pid
  # def lookup_fqn(name), do: Module.concat(name, Lookup)
end
