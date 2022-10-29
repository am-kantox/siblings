# Siblings    [![Kantox ❤ OSS](https://img.shields.io/badge/❤-kantox_oss-informational.svg)](https://kantox.com/)  [![Test](https://github.com/am-kantox/siblings/workflows/Test/badge.svg)](https://github.com/am-kantox/siblings/actions?query=workflow%3ATest)  [![Dialyzer](https://github.com/am-kantox/siblings/workflows/Dialyzer/badge.svg)](https://github.com/am-kantox/siblings/actions?query=workflow%3ADialyzer)

**The partitioned dynamic supervision of FSM-backed workers.**

## Usage

`Siblings` is a library to painlessly manage many uniform processes,
all having the lifecycle _and_ the _FSM_ behind.

Consider the service, that polls the market rates from several
diffferent sources, allowing semi-automated trading based
on predefined conditions. For each bid, the process is to be spawn,
polling the external resources. Once the bid condition is met,
the bid gets traded.

With `Siblings`, one should implement `c:Siblings.Worker.perform/3`
callback, doing actual work and returning either `:ok` if no action
should be taken, or `{:transition, event, payload}` to initiate the
_FSM_ transition. When the _FSM_ get exhausted (reaches its end state,)
both the performing process _and_ the _FSM_ itself do shut down.

_FSM_ instances leverage [`Finitomata`](https://hexdocs.pm/finitomata)
library, which should be used alone if no recurrent `perform` should be
accomplished _or_ if the instances are not uniform.

Typical code for the `Siblings.Worker` implementation would be as follows

```elixir
defmodule MyApp.Worker do
  @fsm """
  born --> |reject| rejected
  born --> |bid| traded
  """

  use Finitomata, @fsm

  def on_transition(:born, :reject, _nil, payload) do
    perform_rejection(payload)
    {:ok, :rejected, payload}
  end

  def on_transition(:born, :bid, _nil, payload) do
    perform_bidding(payload)
    {:ok, :traded, payload}
  end

  @behaviour Siblings.Worker

  @impl Siblings.Worker
  def perform(state, id, payload)

  def perform(:born, id, payload) do
    cond do
      time_to_bid?() -> {:transition, :bid, nil}
      stale?() -> {:transition, :reject, nil}
      true -> :noop
    end
  end

  def perform(:rejected, id, _payload) do
    Logger.info("The bid #{id} was rejected")
    {:transition, :__end__, nil}
  end

  def perform(:traded, id, _payload) do
    Logger.info("The bid #{id} was traded")
    {:transition, :__end__, nil}
  end
end
```

Now it can be used as shown below

```elixir
{:ok, pid} = Siblings.start_link()
Siblings.start_child(MyApp.Worker, "Bid1", %{}, interval: 1_000)
Siblings.start_child(MyApp.Worker, "Bid2", %{}, interval: 1_000)
...
```

The above would spawn two processes, checking the conditions once
per a second (`interval`,) and manipulating the underlying _FSM_ to
walk through the bids’ lifecycles.

Worker’s interval might be reset with
`GenServer.cast(pid, {:reset, interval})` and the message might be casted
to it with `GenServer.call(pid, {:message, message})`. For the latter
to work, the optional callback `on_call/2` must be implemented.

_Sidenote:_ Normally, `Siblings` supervisor would be put into
the supervision tree of the target application.

## Installation

```elixir
def deps do
  [
    {:siblings, "~> 0.1"}
  ]
end
```

## Changelog

* `0.10.2` — accept `(any() -> :ok)` as `die_with_children` option as a callback
* `0.10.0` — `die_with_children: boolean()` option 
* `0.8.2` — updated with last `finitomata` compiler
* `0.7.0` — `Siblings.state/{0,1,2,3}` + update to `Finitoma 0.7`
* `0.5.1` — allow `{:reschedule, non_neg_integer()}` return from `perform/3`
* `0.5.0` — use _FSM_ for the `Sibling.Lookup`
* `0.4.3` — accept `hibernate?:` boolean parameter in call to `Siblings.start_child/4` to hibernate children
* `0.4.2` — accept `workers:` in call to `Siblings.child_spec/1` to statically initialize `Siblings`
* `0.4.1` — [BUG] many named `Siblings` instances
* `0.4.0` — `Siblings.{multi_call/2, multi_transition/3}`
* `0.3.3` — `Siblings.{state/1, payload/2}`
* `0.3.2` — `Siblings.{call/3, reset/3, transition/4}`
* `0.3.1` — retrieve childrens as both `map` and `list`
* `0.3.0` — `GenServer.cast(pid, {:reset, interval})` and `GenServer.call(pid, {:message, message})`
* `0.2.0` — Fast `Worker` lookup
* `0.1.0` — Initial MVP

## [Documentation](https://hexdocs.pm/siblings)
