defmodule Siblings.Test.Finitomata do
  @moduledoc false

  @fsm """
  idle --> |to_s1!| s1
  s1 --> |to_s2| s2
  s1 --> |to_s3| s3
  s2 --> |to_s1| s3
  s2 --> |ambiguous| s3
  s2 --> |ambiguous| s4
  s3 --> |determined| s3
  s3 --> |determined| s4
  s4 --> |determined| s4
  s4 --> |determined| s5
  """

  use Finitomata, fsm: @fsm, auto_terminate: true

  # def on_transition(:s2, :ambiguous, _event_payload, payload) do
  #   {:ok, :s4, payload}
  # end

  def on_transition(:s3, :determined, _event_payload, payload) do
    {:ok, :s4, payload}
  end

  def on_transition(:s4, _event, _event_payload, payload) do
    {:ok, :s4, payload}
  end
end
