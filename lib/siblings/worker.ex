defmodule Siblings.Worker do
  @moduledoc """
  The worker for the single sibling process.
  """

  use Boundary

  @typedoc "Identifier of the worker process"
  @type id :: any()

  @typedoc "Payload associated with the worker"
  @type payload :: Finitomata.State.payload()

  # @typedoc "Expected response from the `DymanicManager` implementation"
  # @type response ::
  #         :halt
  #         | {:replace, payload()}
  #         | {:replace, id(), payload()}
  #         | {{:timeout, integer()}, payload()}
  #         | {:ok, any()}
  #         | any()

  @doc """
  The callback to be implemented in each and every worker.

  It will be called internally continiously by the internal worker process,
  transitioning the underlying FSM according to the return value.
  """
  @callback perform(state :: Finitomata.Transition.state(), id :: id(), payload :: payload()) ::
              {:transition, Finitomata.Transition.event(), Finitomata.event_payload()} | :noop

  @doc """
  The `Finitomata` FSM implementation module.

  It will be used internally to carry the state of FSM.
  """
  @callback fsm :: module()

  @doc """
  The function to re-initialize FSM after crash.
  """
  @callback reinit(pid()) :: :ok

  @optional_callbacks reinit: 1
end
