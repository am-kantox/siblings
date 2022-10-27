defmodule Siblings.Finitomata.NoWarning6 do
  @moduledoc false

  @fsm """
  idle --> |process| processed
  processed --> |process| processed
  processed --> |process| finished
  """

  use Finitomata, fsm: @fsm, impl_for: :on_transition

  @impl Finitomata
  def on_transition(state, event, _, payload)
      when state in ~w|processed|a and event in ~w|process|a,
      do: {:ok, :processed, payload}
end
