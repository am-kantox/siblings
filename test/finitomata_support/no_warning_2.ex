defmodule Siblings.Finitomata.NoWarning2 do
  @moduledoc false

  @fsm """
  idle --> |process| processed
  processed --> |process| processed
  processed --> |process| finished
  """

  use Finitomata, fsm: @fsm, impl_for: :on_transition

  @impl Finitomata
  def on_transition(_, :process, _, payload), do: {:ok, :processed, payload}
end
