defmodule Siblings.Throttler do
  @moduledoc """
  The internal definition of the call to throttle.

  `Siblings.Throttler.call/3` is a blocking call similar to `GenServer.call/3`, but
    served by the underlying `GenStage` producer-consumer pair.

  Despite this implementation of throttling based on `GenStage` is provided
    mostly for internal needs, it is generic enough to use wherever. Use the childspec
    `{Siblings.Throttler, name: name, initial: [], max_demand: 3, interval: 1_000}`
    to start a throttling process and `Siblings.Throttler.call/3` to perform throttled
    synchronous calls from different processes.
  """

  @typedoc "The _in/out_ parameter for calls to `Siblings.Throttler.call/3`"
  @type t :: %{
          __struct__: Siblings.Throttler,
          from: GenServer.from(),
          fun: (keyword() -> any()),
          args: keyword(),
          result: any(),
          payload: any()
        }

  @typedoc "The simplified _in_ parameter for calls to `Siblings.Throttler.call/3`"
  @type throttlee :: t() | {(keyword() -> any()), [any()]}

  defstruct ~w|from fun args result payload|a

  use Supervisor

  require Logger

  alias Siblings.Throttler.{Consumer, Producer}

  @doc """
  Starts the throttler with the underlying producer-consumer stages.

  Accepted options are:

  - `name` the base name for the throttler to be used in calls to `call/3`
  - `initial` the initial load of requests (avoid using it unless really needed)
  - `max_demand`, `initial` the options to be passed directly to `GenStage`’s consumer
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, Siblings.default_fqn())
    opts = Keyword.put_new(opts, :name, name)
    Supervisor.start_link(__MODULE__, opts, name: Siblings.throttler_fqn(name))
  end

  @doc false
  @impl Supervisor
  def init(opts) do
    {initial, opts} = Keyword.pop(opts, :initial, [])
    {name, opts} = Keyword.pop!(opts, :name)

    children = [
      {Producer, initial},
      {Consumer, opts}
    ]

    flags = Supervisor.init(children, strategy: :one_for_one)

    Task.start_link(fn ->
      opts =
        opts
        |> Keyword.take(~w|max_demand interval|a)
        |> Keyword.put_new(:to, producer(name))

      name
      |> consumer()
      |> GenStage.sync_subscribe(opts)
    end)

    flags
  end

  @doc """
  Synchronously executes the function, using throttling based on `GenStage`.

  This function has a default timeout `:infinity` because of its nature
    (throttling is supposed to take a while,) but it might be passed as the third
    argument in a call to `call/3`.

  If a list of functions is given, executes all of them in parallel,
    collects the results, and then returns them to the caller.

  The function might be given as `t:Siblings.Throttler.t()` or
    in a simplified form as `{function_of_arity_1, arg}`.
  """
  def call(name \\ Siblings.default_fqn(), request, timeout \\ :infinity)

  def call(name, requests, timeout) when is_list(requests) do
    requests
    |> Enum.map(&Task.async(Siblings.Throttler, :call, [name, &1, timeout]))
    |> Task.await_many()
  end

  def call(name, request, timeout),
    do: GenStage.call(producer(name), {:add, request}, timeout)

  @doc false
  def debug(anything, opts \\ []) do
    anything
    |> inspect(opts)
    |> Logger.debug()
  end

  @doc false
  def producer(name \\ Siblings.default_fqn()), do: lookup(Producer, name)
  @doc false
  def consumer(name \\ Siblings.default_fqn()), do: lookup(Consumer, name)

  defp lookup(who, name) do
    name
    |> Siblings.throttler_fqn()
    |> Supervisor.which_children()
    |> Enum.find(&match?({_name, _pid, :worker, [^who]}, &1))
    |> case do
      {_, pid, _, _} when is_pid(pid) -> pid
      _ -> nil
    end
  end
end
