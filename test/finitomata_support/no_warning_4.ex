defmodule Siblings.Finitomata.NoWarning4 do
  @moduledoc false

  @fsm """
  idle --> |process| processed
  processed --> |process| processed
  processed --> |process| finished
  """

  use Finitomata, fsm: @fsm, impl_for: :on_transition

  @impl Finitomata
  def on_transition(state, :process, _, payload) when state == :processed,
    do: {:ok, :processed, payload}
end
