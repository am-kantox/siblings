defmodule Siblings.Finitomata.NoWarning1 do
  @moduledoc false

  @fsm """
  idle --> |process| processed
  processed --> |process| processed
  processed --> |process| finished
  """

  use Finitomata, fsm: @fsm, impl_for: :on_transition

  @impl Finitomata
  def on_transition(:processed, :process, _, payload), do: {:ok, :processed, payload}
end
