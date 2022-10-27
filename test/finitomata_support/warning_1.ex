defmodule Siblings.Finitomata.Warning1 do
  @moduledoc false

  @fsm """
  idle --> |process| processed
  processed --> |process| processed
  processed --> |process| finished
  """

  use Finitomata, fsm: @fsm, impl_for: :on_transition
end
