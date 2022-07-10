defmodule Siblings.Worker do
  @moduledoc """
  The worker for the single sibling process.
  """

  use Boundary

  alias Siblings.InternalWorker.State

  @typedoc "Identifier of the worker process"
  @type id :: any()

  @typedoc "Message to be sent to the worker process"
  @type message :: any()

  @typedoc "Value, returned from `on_call/2` callback"
  @type call_result :: any()

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
  If not implemented, this module itself will be considered an FSM implementation.
  """
  @callback fsm :: module()

  @doc """
  The function to re-initialize FSM after crash.
  """
  @callback on_init(pid()) :: :ok

  @doc """
  The handler for the routed message from
    `Siblings.InternalWorker.handle_call({:message, any()})`.
  """
  @callback on_call(message :: message(), State.t()) :: {result :: call_result(), State.t()}

  @optional_callbacks fsm: 0, on_init: 1, on_call: 2
end
