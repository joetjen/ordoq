defmodule Ordoq do
  @moduledoc """
  Runs bounded, local, in-memory background jobs.

  Jobs are lost when the owning BEAM instance stops. Retries provide at-least-once
  execution only; callbacks that perform external side effects must be idempotent.
  The dependency starts Ordoq automatically through its OTP application.

  A callback receives a timeout-extension function before its declared arguments:

      def deliver(touch, recipient) do
        :ok = touch.(nil)
        send(recipient, :delivered)
      end
  """

  alias Ordoq.{Config, Error, Queue, Stats}

  @typedoc "A monotonically increasing identifier local to one Ordoq process lifetime."
  @type job_id :: pos_integer()

  @typedoc "A unique optional job name."
  @type job_name :: atom() | tuple()

  @typedoc "A job identifier or its unique name."
  @type job_reference :: job_id() | job_name()

  @typedoc "A callback's bounded timeout-extension function."
  @type touch :: (pos_integer() | nil -> :ok | {:error, Error.t()})

  ##
  ## Public API
  ##

  # Public functions

  @doc "Enqueues a validated callback and returns its local job identifier."

  @spec enqueue(module(), atom(), list(), keyword()) :: {:ok, job_id()} | {:error, Error.t()}
  def enqueue(module, function, args \\ [], options \\ []) do
    context = Ordoq.Telemetry.capture_context()

    GenServer.call(
      Queue,
      {:enqueue, module, function, args, options, context},
      admission_timeout_ms()
    )
  end

  @doc "Cancels a queued or running job by identifier or unique name."
  @spec cancel(job_reference()) :: :ok | {:error, Error.t()}
  def cancel(reference), do: GenServer.call(Queue, {:cancel, reference}, admission_timeout_ms())

  @doc """
  Waits until every queued, delayed, and running job reaches a terminal state.

  Admission remains open while waiting. This is intended for finite batch
  applications that must not exit before their accepted in-memory work and
  retries complete. It returns an error if any accepted job exhausts its
  retries or is cancelled.
  """
  @spec await_idle(pos_integer()) :: :ok | {:error, Error.t()}
  def await_idle(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(Queue, {:await_idle, timeout_ms}, :infinity)
  end

  @doc "Idempotently prevents a queued named job from starting."
  @spec lock(job_name()) :: :ok | {:error, Error.t()}
  def lock(name), do: GenServer.call(Queue, {:lock, name}, admission_timeout_ms())

  @doc "Idempotently makes a locked named job eligible for scheduling again."
  @spec unlock(job_name()) :: :ok | {:error, Error.t()}
  def unlock(name), do: GenServer.call(Queue, {:unlock, name}, admission_timeout_ms())

  @doc "Returns a bounded count-only snapshot of local queue utilization."
  @spec stats() :: Stats.t()
  def stats, do: GenServer.call(Queue, :stats, admission_timeout_ms())

  @doc """
  Stops new admission and waits up to `timeout_ms` for active jobs to finish.

  Queued and delayed jobs are not started after draining begins. Because Ordoq
  is intentionally in-memory, those jobs are discarded when the owning
  application subsequently stops.
  """
  @spec drain(pos_integer()) :: :ok | {:error, Error.t()}
  def drain(timeout_ms \\ shutdown_timeout_ms()) when is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(Queue, {:drain, timeout_ms}, :infinity)
  end

  ##
  ## Private Functions
  ##

  # Internal helpers

  # Reads the locally owned admission timeout through the validated Config boundary.
  @spec admission_timeout_ms() :: pos_integer()
  defp admission_timeout_ms do
    case Config.load() do
      {:ok, config} -> Config.admission_timeout_ms(config)
      {:error, error} -> raise error
    end
  end

  # Reads the locally owned shutdown timeout through the validated Config boundary.
  @spec shutdown_timeout_ms() :: pos_integer()
  defp shutdown_timeout_ms do
    case Config.load() do
      {:ok, config} -> Config.shutdown_timeout_ms(config)
      {:error, error} -> raise error
    end
  end
end
