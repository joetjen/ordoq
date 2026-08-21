defmodule Ordoq.Telemetry do
  @moduledoc """
  Ordoq's canonical, reporter-independent telemetry events.

  Every event is emitted through `:telemetry`, so any reporter can consume them
  without Ordoq knowing which. Names follow `[:ordoq, subject, operation]`.

  ## Events

  | Event | Kind | Measurement | Metadata |
  | --- | --- | --- | --- |
  | `[:ordoq, :job, :enqueue]` | counter | `:count` | `:result` — `:accepted`, `:duplicate`, `:invalid`, `:overloaded`, `:shutting_down` |
  | `[:ordoq, :job, :execute, :start\\|:stop\\|:exception]` | span | `:duration` (native) | `:attempt`, and `:result` on stop |
  | `[:ordoq, :job, :retry]` | counter | `:count` | `:reason` — `:error`, `:timeout` |
  | `[:ordoq, :job, :terminal]` | counter | `:count` | `:result` — `:cancelled`, `:error`, `:ok`, `:timeout` |
  | `[:ordoq, :job, :control]` | counter | `:count` | `:operation`, `:result` |
  | `[:ordoq, :queue, :depth]` | last value | `:value` | — |
  | `[:ordoq, :queue, :in_flight]` | last value | `:value` | — |

  ## Context propagation

  A job is enqueued in one process and executed in another, so anything the
  caller's process carries — a trace span, request identifiers — is not
  automatically present during execution. `capture_context/0` and
  `with_context/2` bridge that gap, and are deliberately pluggable: Ordoq does
  not depend on any particular tracing library.

  The default captures `Logger.metadata/0`, which is useful on its own and
  costs nothing. Supply your own to propagate something else:

      config :ordoq, context: MyApp.TraceContext

  The module must export `capture/0` and `with/2`. See
  `Ordoq.Telemetry.LoggerContext` for the default implementation.
  """

  @app :ordoq

  @typedoc "Opaque context captured in one process and restored in another."
  @type context :: term()

  ##
  ## Public API
  ##

  # Counters

  @doc "Records job enqueue attempts by result."
  @spec job_enqueue(non_neg_integer(), map()) :: :ok
  def job_enqueue(count, metadata \\ %{}), do: count(:job, :enqueue, count, metadata)

  @doc "Records job retries scheduled after execution failures."
  @spec job_retry(non_neg_integer(), map()) :: :ok
  def job_retry(count, metadata \\ %{}), do: count(:job, :retry, count, metadata)

  @doc "Records terminal job outcomes."
  @spec job_terminal(non_neg_integer(), map()) :: :ok
  def job_terminal(count, metadata \\ %{}), do: count(:job, :terminal, count, metadata)

  @doc "Records job control operations."
  @spec job_control(non_neg_integer(), map()) :: :ok
  def job_control(count, metadata \\ %{}), do: count(:job, :control, count, metadata)

  # Last values

  @doc "Reports jobs admitted but not currently executing."
  @spec queue_depth(non_neg_integer()) :: :ok
  def queue_depth(value), do: last_value(:queue, :depth, value)

  @doc "Reports jobs currently executing."
  @spec queue_in_flight(non_neg_integer()) :: :ok
  def queue_in_flight(value), do: last_value(:queue, :in_flight, value)

  # Spans

  @doc """
  Measures one job execution, emitting `:start`, `:stop` and `:exception`.

  An exception is re-raised with its original stacktrace after the
  `:exception` event is emitted.

  Returns whatever `function` returns as its first element. `function` must
  return `{result, extra_metadata}`: the result is passed back to the caller and
  the extra metadata is merged into the `:stop` event, which is how the outcome
  reaches reporters without the job's arguments or return value going with it.
  """
  @spec job_execute(map(), (-> {result, map()})) :: result when result: term()
  def job_execute(metadata \\ %{}, function) when is_function(function, 0) do
    :telemetry.span([@app, :job, :execute], metadata, function)
  end

  # Context propagation

  @doc "Captures the current process's context for later restoration."
  @spec capture_context() :: context()
  def capture_context, do: context_module().capture()

  @doc "Runs `function` with a previously captured context applied."
  @spec with_context(context(), (-> result)) :: result when result: term()
  def with_context(context, function) when is_function(function, 0),
    do: context_module().with(context, function)

  ##
  ## Private Functions
  ##

  # Emission

  # Emits one counter event under this library's own namespace.
  @spec count(atom(), atom(), non_neg_integer(), map()) :: :ok
  defp count(subject, operation, value, metadata),
    do: :telemetry.execute([@app, subject, operation], %{count: value}, metadata)

  # Emits one last-value event under this library's own namespace.
  @spec last_value(atom(), atom(), non_neg_integer()) :: :ok
  defp last_value(subject, operation, value),
    do: :telemetry.execute([@app, subject, operation], %{value: value}, %{})

  # Resolves the configured context implementation, defaulting to Logger metadata.
  @spec context_module() :: module()
  defp context_module,
    do: Application.get_env(@app, :context, Ordoq.Telemetry.LoggerContext)
end
