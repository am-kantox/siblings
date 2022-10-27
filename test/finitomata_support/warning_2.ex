defmodule Siblings.Finitomata.Warning2 do
  @moduledoc false

  @fsm """
  idle --> |process| processed
  processed --> |process| processed
  processed --> |process| finished
  """

  use Finitomata, fsm: @fsm, impl_for: :on_transition

  @impl Finitomata
  def on_transition(state, :process, _event_payload, payload) when state == :processed,
    do: {:ok, :processed, payload}
end
