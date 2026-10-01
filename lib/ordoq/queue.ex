defmodule Ordoq.Queue do
  @moduledoc false

  use GenServer

  alias Ordoq.Queue.Tree, as: GBTree
  alias Ordoq.Queue.Timer
  alias Ordoq.Telemetry.Context
  alias Ordoq.{Config, Error, Job, Stats, Telemetry}

  @type state :: map()
  @type running :: %{job: Job.t(), task: Task.t(), timer_ref: term(), timeout_token: reference()}

  ##
  ## Public API
  ##

  # Public functions

  @doc "Starts the single local queue with validated immutable configuration."

  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  ##
  ## Callback Implementations
  ##

  # Behaviour callbacks

  @impl true
  @spec init(Config.t()) :: {:ok, state()} | {:stop, Error.t()}
  def init(config) do
    with {:ok, gate_open?} <- subscribe_gate(Config.health_gate(config)) do
      {:ok, initial_state(config, gate_open?)}
    end
  end

  @impl true
  @spec handle_call(term(), GenServer.from(), state()) :: {:reply, term(), state()} | {:noreply, state()}
  def handle_call({:enqueue, module, function, args, options, context}, _from, state) do
    case prepare_job(state, module, function, args, options, context) do
      {:ok, job} -> accept_job(state, job)
      {:error, result, error} -> reject_job(state, result, error)
    end
  end

  def handle_call({:cancel, reference}, _from, state) do
    with {:ok, id} <- resolve_reference(state, reference),
         {:ok, job} <- fetch_job(state, id) do
      state = cancel_job(state, job)
      emit_control(:cancel, :ok)
      {:reply, :ok, state |> dispatch() |> finish_drain_waiters()}
    else
      {:error, error} -> control_error(state, :cancel, error)
    end
  end

  def handle_call({:lock, name}, _from, state) do
    with {:ok, id} <- resolve_name(state, name),
         {:ok, job} <- fetch_job(state, id),
         {:ok, updated} <- lock_job(state, job) do
      emit_control(:lock, :ok)
      {:reply, :ok, schedule_wake(updated)}
    else
      {:error, error} -> control_error(state, :lock, error)
    end
  end

  def handle_call({:unlock, name}, _from, state) do
    with {:ok, id} <- resolve_name(state, name),
         {:ok, job} <- fetch_job(state, id),
         {:ok, updated} <- unlock_job(state, job) do
      emit_control(:unlock, :ok)
      {:reply, :ok, dispatch(updated)}
    else
      {:error, error} -> control_error(state, :unlock, error)
    end
  end

  def handle_call({:touch, id, attempt, ttr_ms}, _from, state) do
    case touch_job(state, id, attempt, ttr_ms) do
      {:ok, updated} ->
        emit_control(:touch, :ok)
        {:reply, :ok, updated}

      {:error, error} ->
        control_error(state, :touch, error)
    end
  end

  def handle_call(:stats, _from, state), do: {:reply, stats(state), state}

  def handle_call({:await_idle, timeout_ms}, from, state) do
    if map_size(state.jobs) == 0 do
      {result, state} = take_idle_result(state)
      {:reply, result, state}
    else
      {:noreply, add_idle_waiter(state, from, timeout_ms)}
    end
  end

  def handle_call({:drain, timeout_ms}, from, state) do
    state = %{state | draining?: true, gate_open?: false}

    if map_size(state.running) == 0 do
      {:reply, :ok, state}
    else
      {:noreply, add_drain_waiter(state, from, timeout_ms)}
    end
  end

  @impl true
  @spec handle_info(term(), state()) :: {:noreply, state()}
  def handle_info(:dispatch, state), do: {:noreply, dispatch(state)}

  def handle_info({:wake, token}, %{timer_token: token} = state) do
    state = %{state | timer_ref: nil}
    {:noreply, state |> promote_due() |> dispatch()}
  end

  def handle_info({:wake, _stale_token}, state), do: {:noreply, state}

  def handle_info({:task_timeout, id, attempt, token}, state) do
    case Map.get(state.running, id) do
      %{job: %{attempt: ^attempt}, timeout_token: ^token} = running ->
        stop_task(running.task)
        state = complete_attempt(state, running, :timeout)
        {:noreply, state |> dispatch() |> finish_drain_waiters()}

      _missing_or_stale ->
        {:noreply, state}
    end
  end

  def handle_info({ref, {:ok, _result}}, state) when is_reference(ref) do
    case Map.get(state.refs, ref) do
      nil -> {:noreply, state}
      id -> {:noreply, finish_success(state, id)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.get(state.refs, ref) do
      nil -> {:noreply, state}
      id -> {:noreply, finish_failure(state, id, reason)}
    end
  end

  def handle_info({:drain_timeout, token}, state) do
    {:noreply, expire_drain_waiter(state, token)}
  end

  def handle_info({:idle_timeout, token}, state) do
    {:noreply, expire_idle_waiter(state, token)}
  end

  def handle_info({:ordoq_gate, gate, :open}, %{gate: gate, draining?: true} = state),
    do: {:noreply, state}

  def handle_info({:ordoq_gate, gate, :open}, %{gate: gate} = state) do
    {:noreply, state |> Map.put(:gate_open?, true) |> dispatch()}
  end

  def handle_info({:ordoq_gate, gate, :closed, _reason}, %{gate: gate} = state) do
    {:noreply, %{state | gate_open?: false}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  @spec terminate(term(), state()) :: :ok
  def terminate(_reason, state) do
    unsubscribe_gate(state.gate)
    Enum.each(state.running, fn {_id, running} -> stop_task(running.task) end)
    :ok
  end

  ##
  ## Private Functions
  ##

  # Internal helpers

  # Constructs the complete bounded queue state after gate subscription.
  @spec initial_state(Config.t(), boolean()) :: state()
  defp initial_state(config, gate_open?) do
    %{
      config: config,
      delayed: GBTree.new(),
      drain_waiters: %{},
      idle_failures: 0,
      idle_waiters: %{},
      draining?: false,
      gate: Config.health_gate(config),
      gate_open?: gate_open?,
      jobs: %{},
      names: %{},
      next_id: 1,
      ready: GBTree.new(),
      refs: %{},
      running: %{},
      timer_ref: nil,
      timer_token: 0
    }
  end

  # Validates a candidate before checking bounded queue admission and uniqueness.
  @spec prepare_job(state(), module(), atom(), list(), keyword(), Context.t()) ::
          {:ok, Job.t()} | {:error, atom(), Error.t()}
  defp prepare_job(state, module, function, args, options, context) do
    with :ok <- ensure_admission(state),
         {:ok, job} <-
           Job.new(
             state.next_id,
             module,
             function,
             args,
             options,
             context,
             state.config,
             now_ms()
           ),
         :ok <- ensure_unique_name(state, job.name),
         :ok <- ensure_capacity(state) do
      {:ok, job}
    else
      {:error, %Error{code: :shutting_down} = error} -> {:error, :shutting_down, error}
      {:error, %Error{code: :duplicate_name} = error} -> {:error, :duplicate, error}
      {:error, %Error{code: :overloaded} = error} -> {:error, :overloaded, error}
      {:error, error} -> {:error, :invalid, error}
    end
  end

  # Rejects new jobs while the configured health gate is closed.
  @spec ensure_admission(state()) :: :ok | {:error, Error.t()}
  defp ensure_admission(%{gate_open?: true}), do: :ok
  defp ensure_admission(%{gate_open?: false}), do: {:error, Error.shutting_down()}

  # Adds an accepted job to the correct ordered collection and triggers dispatch.
  @spec accept_job(state(), Job.t()) :: {:reply, {:ok, pos_integer()}, state()}
  defp accept_job(state, job) do
    state =
      state
      |> put_job(job)
      |> put_name(job)
      |> Map.put(:next_id, job.id + 1)
      |> emit_utilization()

    _ignored = Telemetry.job_enqueue(1, %{result: :accepted})
    {:reply, {:ok, job.id}, dispatch(state)}
  end

  # Emits a bounded rejection and leaves queue state untouched.
  @spec reject_job(state(), atom(), Error.t()) :: {:reply, {:error, Error.t()}, state()}
  defp reject_job(state, result, error) do
    _ignored = Telemetry.job_enqueue(1, %{result: result})
    {:reply, {:error, error}, state}
  end

  # Returns a control failure with finite telemetry metadata.
  @spec control_error(state(), atom(), Error.t()) :: {:reply, {:error, Error.t()}, state()}
  defp control_error(state, operation, error) do
    emit_control(operation, :error)
    {:reply, {:error, error}, state}
  end

  # Rejects a name retained by any queued or running job.
  @spec ensure_unique_name(state(), Job.name()) :: :ok | {:error, Error.t()}
  defp ensure_unique_name(_state, nil), do: :ok

  defp ensure_unique_name(state, name) do
    if Map.has_key?(state.names, name),
      do: {:error, Error.duplicate_name(%{name: name})},
      else: :ok
  end

  # Enforces queue capacity independently from the configured worker allowance.
  @spec ensure_capacity(state()) :: :ok | {:error, Error.t()}
  defp ensure_capacity(state) do
    if queued_count(state) < Config.max_queued(state.config),
      do: :ok,
      else: {:error, Error.overloaded(%{limit: Config.max_queued(state.config)})}
  end

  # Inserts a new or retried job into its ordered ready or delayed tree.
  @spec put_job(state(), Job.schedulable()) :: state()
  defp put_job(state, %{status: :ready} = job) do
    key = {job.priority, job.sequence}
    store_job(%{state | ready: GBTree.put(state.ready, key, job.id)}, %{job | queue_key: key})
  end

  defp put_job(state, %{status: :delayed} = job) do
    key = {job.ready_at_ms, job.sequence}
    store_job(%{state | delayed: GBTree.put(state.delayed, key, job.id)}, %{job | queue_key: key})
  end

  # Stores a job as the authoritative local lifecycle record.
  @spec store_job(state(), Job.t()) :: state()
  defp store_job(state, job), do: %{state | jobs: Map.put(state.jobs, job.id, job)}

  # Reserves a non-nil name until terminal cleanup.
  @spec put_name(state(), Job.t()) :: state()
  defp put_name(state, %{name: nil}), do: state
  defp put_name(state, job), do: %{state | names: Map.put(state.names, job.name, job.id)}

  # Promotes every due delayed job before selecting runnable work.
  @spec promote_due(state()) :: state()
  defp promote_due(state) do
    now_ms = now_ms()

    case GBTree.smallest(state.delayed) do
      {:ok, {{ready_at_ms, _sequence} = key, id}} when ready_at_ms <= now_ms ->
        job = Map.fetch!(state.jobs, id)
        state = %{state | delayed: GBTree.delete(state.delayed, key)}
        promote_due(put_job(state, %{job | status: :ready, queue_key: nil}))

      _not_due ->
        state
    end
  end

  # Starts eligible jobs until worker capacity or the ready queue is exhausted.
  @spec dispatch(state()) :: state()
  defp dispatch(state) do
    state = promote_due(state)

    if state.gate_open? and map_size(state.running) < Config.max_in_flight(state.config) do
      dispatch_one(state)
    else
      state |> schedule_wake() |> emit_utilization()
    end
  end

  # Removes and starts the next priority/FIFO job when one is ready.
  @spec dispatch_one(state()) :: state()
  defp dispatch_one(state) do
    case GBTree.smallest(state.ready) do
      {:ok, {key, id}} ->
        job = Map.fetch!(state.jobs, id)
        state = %{state | ready: GBTree.delete(state.ready, key)}
        state |> start_job(%{job | status: :running, queue_key: nil}) |> dispatch()

      :empty ->
        state |> schedule_wake() |> emit_utilization()
    end
  end

  # Starts one monitored worker and installs its attempt-specific timeout.
  @spec start_job(state(), Job.t()) :: state()
  defp start_job(state, job) do
    queue = self()
    admission_timeout_ms = Config.admission_timeout_ms(state.config)

    task =
      Task.Supervisor.async_nolink(Ordoq.TaskSupervisor, fn ->
        execute_job(queue, job, admission_timeout_ms)
      end)

    token = make_ref()

    {:ok, timer_ref} =
      Timer.send_after(job.ttr_ms, queue, {:task_timeout, job.id, job.attempt, token})

    running = %{job: job, task: task, timer_ref: timer_ref, timeout_token: token}

    state
    |> store_job(job)
    |> Map.update!(:running, &Map.put(&1, job.id, running))
    |> Map.update!(:refs, &Map.put(&1, task.ref, job.id))
  end

  # Restores submitter trace context and runs the declared callback in a canonical span.
  @spec execute_job(pid(), Job.t(), pos_integer()) :: {:ok, term()}
  defp execute_job(queue, job, admission_timeout_ms) do
    Telemetry.with_context(job.context, fn ->
      instrument_job(queue, job, admission_timeout_ms)
    end)
  end

  # Instruments one callback attempt without exposing its arguments or result as metadata.
  @spec instrument_job(pid(), Job.t(), pos_integer()) :: {:ok, term()}
  defp instrument_job(queue, job, admission_timeout_ms) do
    Telemetry.job_execute(%{attempt: job.attempt}, fn ->
      invoke_job(queue, job, admission_timeout_ms)
    end)
  end

  # Invokes the declared callback and returns only the finite terminal span category.
  @spec invoke_job(pid(), Job.t(), pos_integer()) :: {{:ok, term()}, %{result: :ok}}
  defp invoke_job(queue, job, admission_timeout_ms) do
    touch = fn ttr_ms -> touch(queue, job, ttr_ms, admission_timeout_ms) end
    result = apply(job.module, job.function, [touch | job.args])
    {{:ok, result}, %{result: :ok}}
  end

  # Subscribes to the configured optional health gate through its public API.
  @spec subscribe_gate(nil | atom()) :: {:ok, boolean()} | {:error, Error.t()}
  defp subscribe_gate(nil), do: {:ok, true}

  defp subscribe_gate(gate) do
    module = Ordoq.Gate.implementation()

    if module != nil and Code.ensure_loaded?(module) and
         function_exported?(module, :subscribe, 1) do
      case module.subscribe(gate) do
        {:ok, :open} -> {:ok, true}
        {:ok, :closed} -> {:ok, false}
        {:error, _error} -> dependency_unavailable()
      end
    else
      dependency_unavailable()
    end
  end

  # Unsubscribes from a configured optional health gate during orderly shutdown.
  @spec unsubscribe_gate(nil | atom()) :: :ok
  defp unsubscribe_gate(nil), do: :ok

  defp unsubscribe_gate(gate) do
    module = Ordoq.Gate.implementation()
    if module != nil and Code.ensure_loaded?(module), do: module.unsubscribe(gate)
    :ok
  end

  # Returns one stable error when the configured health dependency cannot serve the gate.
  @spec dependency_unavailable() :: {:error, Error.t()}
  defp dependency_unavailable,
    do: {:error, Error.dependency_unavailable(%{dependency: :gate})}

  # Applies the job default for nil and requests attempt-scoped timeout extension.
  @spec touch(pid(), Job.t(), pos_integer() | nil, pos_integer()) ::
          :ok | {:error, Error.t()}
  defp touch(queue, job, nil, timeout_ms),
    do: GenServer.call(queue, {:touch, job.id, job.attempt, job.ttr_ms}, timeout_ms)

  defp touch(queue, job, ttr_ms, timeout_ms),
    do: GenServer.call(queue, {:touch, job.id, job.attempt, ttr_ms}, timeout_ms)

  # Replaces one active attempt timer after validating the requested duration.
  @spec touch_job(state(), pos_integer(), pos_integer(), term()) :: {:ok, state()} | {:error, Error.t()}
  defp touch_job(state, id, attempt, ttr_ms) do
    with true <- is_integer(ttr_ms) and ttr_ms > 0,
         true <- ttr_ms <= Config.max_ttr_ms(state.config),
         %{job: %{attempt: ^attempt}} = running <- Map.get(state.running, id),
         :ok <- cancel_timer(running.timer_ref),
         token <- make_ref(),
         {:ok, timer_ref} <- Timer.send_after(ttr_ms, self(), {:task_timeout, id, attempt, token}) do
      updated = %{running | timer_ref: timer_ref, timeout_token: token}
      {:ok, put_in(state.running[id], updated)}
    else
      _invalid_or_stale -> {:error, Error.job_not_found(%{operation: :touch})}
    end
  end

  # Finalizes a successful worker result and immediately reuses released capacity.
  @spec finish_success(state(), pos_integer()) :: state()
  defp finish_success(state, id) do
    case Map.get(state.running, id) do
      nil ->
        state

      running ->
        state
        |> clear_running(running)
        |> terminal(running.job, :ok)
        |> dispatch()
        |> finish_drain_waiters()
    end
  end

  # Converts a monitored worker exit into a retry or terminal error.
  @spec finish_failure(state(), pos_integer(), term()) :: state()
  defp finish_failure(state, id, reason) do
    case Map.get(state.running, id) do
      nil ->
        state

      running ->
        state
        |> complete_attempt(running, failure_reason(reason))
        |> dispatch()
        |> finish_drain_waiters()
    end
  end

  # Registers a caller that must be answered when active work ends or its deadline expires.
  @spec add_drain_waiter(state(), GenServer.from(), pos_integer()) :: state()
  defp add_drain_waiter(state, from, timeout_ms) do
    token = make_ref()
    {:ok, timer_ref} = Timer.send_after(timeout_ms, self(), {:drain_timeout, token})
    put_in(state.drain_waiters[token], {from, timer_ref})
  end

  # Replies to one caller whose bounded drain deadline elapsed.
  @spec expire_drain_waiter(state(), reference()) :: state()
  defp expire_drain_waiter(state, token) do
    case Map.pop(state.drain_waiters, token) do
      {nil, _waiters} ->
        state

      {{from, _timer_ref}, waiters} ->
        GenServer.reply(from, {:error, Error.drain_timeout(%{scope: :running_jobs})})
        %{state | drain_waiters: waiters}
    end
  end

  # Completes every pending drain call once no callback remains active.
  @spec finish_drain_waiters(state()) :: state()
  defp finish_drain_waiters(%{running: running} = state) when map_size(running) > 0, do: state

  defp finish_drain_waiters(state) do
    Enum.each(state.drain_waiters, fn {_token, {from, timer_ref}} ->
      _ignored = cancel_timer(timer_ref)
      GenServer.reply(from, :ok)
    end)

    %{state | drain_waiters: %{}}
  end

  # Registers a caller waiting for every accepted job and retry to finish.
  @spec add_idle_waiter(state(), GenServer.from(), pos_integer()) :: state()
  defp add_idle_waiter(state, from, timeout_ms) do
    token = make_ref()
    {:ok, timer_ref} = Timer.send_after(timeout_ms, self(), {:idle_timeout, token})
    put_in(state.idle_waiters[token], {from, timer_ref})
  end

  # Replies to one idle waiter whose finite deadline elapsed.
  @spec expire_idle_waiter(state(), reference()) :: state()
  defp expire_idle_waiter(state, token) do
    case Map.pop(state.idle_waiters, token) do
      {nil, _waiters} ->
        state

      {{from, _timer_ref}, waiters} ->
        GenServer.reply(from, {:error, Error.await_idle_timeout(%{scope: :accepted_jobs})})
        %{state | idle_waiters: waiters}
    end
  end

  # Completes finite-batch waiters only after no accepted identity remains.
  @spec finish_idle_waiters(state()) :: state()
  defp finish_idle_waiters(%{jobs: jobs} = state) when map_size(jobs) > 0, do: state
  defp finish_idle_waiters(%{idle_waiters: waiters} = state) when map_size(waiters) == 0, do: state

  defp finish_idle_waiters(state) do
    {result, state} = take_idle_result(state)

    Enum.each(state.idle_waiters, fn {_token, {from, timer_ref}} ->
      _ignored = cancel_timer(timer_ref)
      GenServer.reply(from, result)
    end)

    %{state | idle_waiters: %{}}
  end

  # Returns the accumulated finite-batch result and starts a fresh result window.
  @spec take_idle_result(state()) :: {:ok | {:error, Error.t()}, state()}
  defp take_idle_result(%{idle_failures: 0} = state), do: {:ok, state}

  defp take_idle_result(state) do
    error = Error.await_idle_failed(%{failed_jobs: state.idle_failures})
    {{:error, error}, %{state | idle_failures: 0}}
  end

  # Clears an attempt and either retries it or records its terminal outcome.
  @spec complete_attempt(state(), running(), :error | :timeout) :: state()
  defp complete_attempt(state, running, reason) do
    state = clear_running(state, running)

    if running.job.attempt < running.job.max_attempts do
      retry(state, running.job, reason)
    else
      terminal(state, running.job, reason)
    end
  end

  # Removes monitor, timer, and in-flight indexes for exactly one attempt.
  @spec clear_running(state(), running()) :: state()
  defp clear_running(state, running) do
    _ignored = cancel_timer(running.timer_ref)
    _ignored = Process.demonitor(running.task.ref, [:flush])

    %{state | refs: Map.delete(state.refs, running.task.ref), running: Map.delete(state.running, running.job.id)}
  end

  # Schedules another attempt using bounded exponential backoff and deterministic jitter.
  @spec retry(state(), Job.t(), :error | :timeout) :: state()
  defp retry(state, job, reason) do
    attempt = job.attempt + 1
    delay_ms = retry_delay_ms(state.config, job, attempt)
    status = if delay_ms == 0, do: :ready, else: :delayed
    retried = %{job | attempt: attempt, ready_at_ms: now_ms() + delay_ms, status: status}
    _ignored = Telemetry.job_retry(1, %{reason: reason})
    state |> put_job(retried) |> schedule_wake() |> emit_utilization()
  end

  # Calculates a capped exponential delay plus stable bounded jitter.
  @spec retry_delay_ms(Config.t(), Job.t(), pos_integer()) :: non_neg_integer()
  defp retry_delay_ms(config, job, attempt) do
    exponent = max(attempt - 2, 0)
    base = capped_double(job.retry_base_ms, exponent, Config.max_retry_delay_ms(config))
    jitter_limit = min(Config.retry_jitter_ms(config), Config.max_retry_delay_ms(config) - base)
    jitter = if jitter_limit == 0, do: 0, else: rem(job.id * attempt * 37, jitter_limit + 1)
    base + jitter
  end

  # Doubles a delay without crossing its configured maximum.
  @spec capped_double(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp capped_double(value, 0, maximum), do: min(value, maximum)

  defp capped_double(value, count, maximum) do
    capped_double(min(value * 2, maximum), count - 1, maximum)
  end

  # Removes every retained identity and emits one finite terminal result.
  @spec terminal(state(), Job.t(), :cancelled | :error | :ok | :timeout) :: state()
  defp terminal(state, job, result) do
    _ignored = Telemetry.job_terminal(1, %{result: result})

    state
    |> Map.update!(:jobs, &Map.delete(&1, job.id))
    |> delete_name(job)
    |> record_idle_result(result)
    |> emit_utilization()
    |> finish_idle_waiters()
  end

  # Counts only terminal outcomes that exhausted retries or were cancelled.
  @spec record_idle_result(state(), :cancelled | :error | :ok | :timeout) :: state()
  defp record_idle_result(state, :ok), do: state
  defp record_idle_result(state, _failure), do: Map.update!(state, :idle_failures, &(&1 + 1))

  # Cancels a queued or running job before terminal cleanup.
  @spec cancel_job(state(), Job.t()) :: state()
  defp cancel_job(state, %{status: :running} = job) do
    running = Map.fetch!(state.running, job.id)
    stop_task(running.task)
    state |> clear_running(running) |> terminal(job, :cancelled)
  end

  defp cancel_job(state, job) do
    state |> remove_from_queue(job) |> terminal(job, :cancelled) |> schedule_wake()
  end

  # Moves an eligible queued job out of scheduling while preserving its ready time.
  @spec lock_job(state(), Job.t()) :: {:ok, state()} | {:error, Error.t()}
  defp lock_job(state, %{status: :locked}), do: {:ok, state}

  defp lock_job(state, %{status: status} = job) when status in [:ready, :delayed] do
    updated = %{job | status: :locked, queue_key: nil}
    {:ok, state |> remove_from_queue(job) |> store_job(updated) |> emit_utilization()}
  end

  defp lock_job(_state, _job), do: {:error, Error.job_not_found(%{operation: :lock})}

  # Restores a locked job to delayed or ready scheduling according to its original ready time.
  @spec unlock_job(state(), Job.t()) :: {:ok, state()} | {:error, Error.t()}
  defp unlock_job(state, %{status: :locked} = job) do
    status = if job.ready_at_ms <= now_ms(), do: :ready, else: :delayed
    {:ok, state |> put_job(%{job | status: status}) |> emit_utilization()}
  end

  defp unlock_job(state, %{status: status}) when status in [:ready, :delayed], do: {:ok, state}
  defp unlock_job(_state, _job), do: {:error, Error.job_not_found(%{operation: :unlock})}

  # Removes a queued job from its current ordered collection.
  @spec remove_from_queue(state(), Job.t()) :: state()
  defp remove_from_queue(state, %{status: :ready, queue_key: key}),
    do: %{state | ready: GBTree.delete(state.ready, key)}

  defp remove_from_queue(state, %{status: :delayed, queue_key: key}),
    do: %{state | delayed: GBTree.delete(state.delayed, key)}

  defp remove_from_queue(state, _job), do: state

  # Resolves an integer as an ID and all supported names through the name index.
  @spec resolve_reference(state(), term()) :: {:ok, pos_integer()} | {:error, Error.t()}
  defp resolve_reference(_state, reference) when is_integer(reference) and reference > 0,
    do: {:ok, reference}

  defp resolve_reference(state, reference), do: resolve_name(state, reference)

  # Resolves one retained job name without leaking the current name inventory.
  @spec resolve_name(state(), term()) :: {:ok, pos_integer()} | {:error, Error.t()}
  defp resolve_name(state, name) do
    case Map.fetch(state.names, name) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, Error.job_not_found()}
    end
  end

  # Fetches one live job by local identifier.
  @spec fetch_job(state(), pos_integer()) :: {:ok, Job.t()} | {:error, Error.t()}
  defp fetch_job(state, id) do
    case Map.fetch(state.jobs, id) do
      {:ok, job} -> {:ok, job}
      :error -> {:error, Error.job_not_found()}
    end
  end

  # Removes a terminal job's optional unique name.
  @spec delete_name(state(), Job.t()) :: state()
  defp delete_name(state, %{name: nil}), do: state
  defp delete_name(state, job), do: %{state | names: Map.delete(state.names, job.name)}

  # Replaces the single delayed-job wake timer with the earliest required wake.
  @spec schedule_wake(state()) :: state()
  defp schedule_wake(state) do
    _ignored = cancel_timer(state.timer_ref)
    token = state.timer_token + 1

    case GBTree.smallest(state.delayed) do
      {:ok, {{ready_at_ms, _sequence}, _id}} ->
        {:ok, timer_ref} = Timer.send_after(max(ready_at_ms - now_ms(), 0), self(), {:wake, token})
        %{state | timer_ref: timer_ref, timer_token: token}

      :empty ->
        %{state | timer_ref: nil, timer_token: token}
    end
  end

  # Cancels a live timer and treats already-fired or absent timers as clean state.
  @spec cancel_timer(term()) :: :ok
  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    _ignored = Timer.cancel(timer_ref)
    :ok
  end

  # Terminates one supervised worker without waiting beyond supervisor ownership.
  @spec stop_task(Task.t()) :: :ok
  defp stop_task(task) do
    _ignored = Task.Supervisor.terminate_child(Ordoq.TaskSupervisor, task.pid)
    :ok
  end

  # Maps all non-normal worker exits to the finite execution-error category.
  @spec failure_reason(term()) :: :error
  defp failure_reason(_reason), do: :error

  # Builds a count-only public snapshot without job payloads or identifiers.
  @spec stats(state()) :: Stats.t()
  defp stats(state) do
    %Stats{
      capacity: Config.max_queued(state.config),
      delayed: GBTree.size(state.delayed),
      in_flight: map_size(state.running),
      locked: Enum.count(state.jobs, fn {_id, job} -> job.status == :locked end),
      queued: queued_count(state)
    }
  end

  # Counts admitted jobs that are not currently executing.
  @spec queued_count(state()) :: non_neg_integer()
  defp queued_count(state), do: map_size(state.jobs) - map_size(state.running)

  # Emits the two bounded utilization gauges after relevant lifecycle changes.
  @spec emit_utilization(state()) :: state()
  defp emit_utilization(state) do
    _ignored = Telemetry.queue_depth(queued_count(state))
    _ignored = Telemetry.queue_in_flight(map_size(state.running))
    state
  end

  # Emits a finite job-control outcome without user-controlled identifiers.
  @spec emit_control(atom(), atom()) :: :ok
  defp emit_control(operation, result) do
    _ignored = Telemetry.job_control(1, %{operation: operation, result: result})
    :ok
  end

  # Returns a monotonic millisecond timestamp suitable only for local scheduling.
  @spec now_ms() :: integer()
  defp now_ms, do: System.monotonic_time(:millisecond)
end
