defmodule Ordoq.Telemetry.Context do
  @moduledoc """
  The contract for propagating process context from enqueue to execution.

  Ordoq runs a job in a different process from the one that enqueued it, so
  anything held in process state — logger metadata, a trace span — does not
  follow it. An implementation captures that state in the enqueueing process
  and restores it around execution.

  Kept as a behaviour so Ordoq depends on no particular tracing library. See
  `Ordoq.Telemetry.LoggerContext` for the default.
  """

  @typedoc """
  A captured process context.

  Its shape belongs to the implementation that captured it; Ordoq only carries
  it from `c:capture/0` to `c:with/2`.
  """
  @type t :: term()

  @doc "Captures the calling process's context."
  @callback capture() :: t()

  @doc "Runs `function` with a captured context applied, restoring what was there."
  @callback with(context :: t(), function :: (-> result)) :: result when result: var
end
