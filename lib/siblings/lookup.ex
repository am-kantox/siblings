defmodule Siblings.Lookup do
  @moduledoc """
  Lookup module to quick access children _and_ the _FSM_‌
    for the `Siblings` instance itself.

  This module is a part of `Siblings` supervision tree
    and should never be started manually. It exposes the interface

  """

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

  @doc false
  @impl Finitomata
  def on_transition(:idle, :initialize, payload, state) do
    children = Siblings.children(:id_pids, state[:siblings], :never)

    state =
      state
      |> Map.put_new(:workers, children)
      |> Map.put_new(:callbacks, Map.get(payload, :callbacks, []))

    state =
      payload
      |> Map.get(:workers, [])
      |> Enum.reduce(state, fn payload, acc ->
        # [AM] Doc + Log on failures
        case on_transition(:ready, :start_child, payload, acc) do
          {:ok, :ready, acc} -> acc
          _ -> acc
        end
      end)

    {:ok, :ready, state}
  end

  @doc false
  @impl Finitomata
  def on_transition(:ready, :start_child, payload, %{workers: workers} = state) do
    if Map.has_key?(workers, payload.id) and Process.alive?(Map.get(workers, payload.id)) do
      :noop
    else
      {:ok, pid} = start_child(state.siblings, payload)
      {:ok, :ready, %{state | workers: Map.put(workers, payload.id, pid)}}
    end
  end

  @doc false
  @impl Finitomata
  def on_transition(:ready, :delete_child, %{id: id}, %{workers: workers} = state) do
    if Map.has_key?(workers, id),
      do: {:ok, :ready, %{state | workers: Map.delete(workers, id)}},
      else: :noop
  end

  @impl Finitomata
  def on_failure(event, payload, %Finitomata.State{payload: %{callbacks: callbacks}}) do
    if is_function(callbacks[:on_failure], 2), do: callbacks[:on_failure].(event, payload)
    :ok
  end

  @impl Finitomata
  def on_enter(fsm_state, %Finitomata.State{payload: %{callbacks: callbacks}}) do
    if is_function(callbacks[:on_enter], 1), do: callbacks[:on_enter].(fsm_state)
    :ok
  end

  @impl Finitomata
  def on_exit(fsm_state, %Finitomata.State{payload: %{callbacks: callbacks}}) do
    if is_function(callbacks[:on_exit], 1), do: callbacks[:on_exit].(fsm_state)
    :ok
  end

  @impl Finitomata
  def on_terminate(%Finitomata.State{payload: %{callbacks: callbacks}}) do
    if is_function(callbacks[:on_terminate], 0), do: callbacks[:on_terminate].()
    :ok
  end

  @doc """
  Returns all the workers running under this `Siblings` instance as a map
    `%{Siblings.Worker.id() => pid()}`.

  This map might be really huge when there are many processes managed.
  """
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

  @doc """
  Returns the `pid` of the single dynamically supervised worker by its `id`.
  """
  @spec get(module(), Worker.id()) :: pid() | nil
  def get(name \\ Siblings.default_fqn(), id, default \\ nil) do
    name |> all() |> Map.get(id, default)
  end

  @doc """
  Initiates the `:start_child` transition with all the respective callbacks
    to add a new child to the supervised list.
  """
  @spec put(module(), Siblings.worker()) :: :ok
  def put(name \\ Siblings.default_fqn(), worker) do
    name
    |> Siblings.lookup_fqn()
    |> GenServer.cast({:start_child, worker})
  end

  @doc """
  Removes the reference for the naturally terminated child from the workers map
    through `:delete_child` transition with all the respective callbacks.
  """
  @spec del(module(), Worker.id()) :: :ok
  def del(name \\ Siblings.default_fqn(), id) do
    name |> Siblings.lookup_fqn() |> GenServer.cast({:delete_child, %{id: id}})
  end

  @doc false
  @spec start_child(module(), Siblings.worker()) :: DynamicSupervisor.on_start_child()
  def start_child(name, %{module: worker, id: id} = worker_spec) do
    payload = Map.get(worker_spec, :payload, %{})

    opts = Map.get(worker_spec, :options, [])
    {shutdown, opts} = Keyword.pop(opts, :shutdown, 5_000)

    opts =
      opts
      |> Keyword.put(:lookup, Siblings.lookup(name))
      |> Keyword.put(:internal_state, Siblings.internal_state(name))

    spec = %{
      id: Enum.join([worker, id], ":"),
      start: {InternalWorker, :start_link, [worker, id, payload, opts]},
      restart: :transient,
      shutdown: shutdown
    }

    DynamicSupervisor.start_child({:via, PartitionSupervisor, {name, {worker, id}}}, spec)
  end
end
