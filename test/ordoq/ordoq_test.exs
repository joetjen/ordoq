defmodule OrdoqTest.Support do
  @moduledoc false

  @doc false
  @spec notify(Ordoq.touch(), pid(), term()) :: :ok
  def notify(_touch, recipient, message) do
    send(recipient, message)
    :ok
  end

  @doc false
  @spec block(Ordoq.touch(), pid(), term()) :: :ok
  def block(_touch, recipient, marker) do
    send(recipient, {:started, marker, self()})

    receive do
      :continue -> :ok
    end
  end

  @doc false
  @spec touch_and_block(Ordoq.touch(), pid()) :: :ok | {:error, Ordoq.Error.t()}
  def touch_and_block(touch, recipient) do
    send(recipient, {:started, self()})

    with :ok <- touch.(100) do
      receive do
        :continue -> :ok
      end
    end
  end

  @doc false
  @spec fail_once(Ordoq.touch(), pid(), pid()) :: :ok
  def fail_once(_touch, recipient, counter) do
    attempt = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)
    send(recipient, {:attempt, attempt})
    if attempt == 1, do: raise("retry me"), else: :ok
  end

  @doc false
  @spec fail(Ordoq.touch()) :: no_return()
  def fail(_touch), do: raise("always fails")

  @doc false
  @spec report_trace(Ordoq.touch(), pid()) :: :ok
  def report_trace(_touch, recipient) do
    send(recipient, {:trace_id, Keyword.get(Logger.metadata(), :trace_id)})
    :ok
  end
end

defmodule OrdoqTest.GateState do
  @moduledoc false

  use GenServer

  @doc false
  @spec start_link(:open | :closed) :: GenServer.on_start()
  def start_link(status), do: GenServer.start_link(__MODULE__, status, name: __MODULE__)

  @doc false
  @spec set(:open | :closed) :: :ok
  def set(status), do: GenServer.call(__MODULE__, {:set, status})

  @behaviour Ordoq.Gate

  @impl Ordoq.Gate
  @spec subscribe(atom()) :: {:ok, :open | :closed}
  def subscribe(gate), do: GenServer.call(__MODULE__, {:subscribe, gate, self()})

  @impl Ordoq.Gate
  @spec unsubscribe(atom()) :: :ok
  def unsubscribe(gate), do: GenServer.call(__MODULE__, {:unsubscribe, gate, self()})

  @impl true
  @spec init(:open | :closed) :: {:ok, map()}
  def init(status), do: {:ok, %{status: status, subscribers: MapSet.new()}}

  @impl true
  def handle_call({:subscribe, :work, subscriber}, _from, state) do
    {:reply, {:ok, state.status}, %{state | subscribers: MapSet.put(state.subscribers, subscriber)}}
  end

  def handle_call({:unsubscribe, :work, subscriber}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.delete(state.subscribers, subscriber)}}
  end

  def handle_call({:set, status}, _from, state) do
    Enum.each(state.subscribers, &notify(&1, status))
    _stats = GenServer.call(Ordoq.Queue, :stats)
    {:reply, :ok, %{state | status: status}}
  end

  # Publishes the same finite transition contract as the real health state owner.
  @spec notify(pid(), :open | :closed) :: :ok
  defp notify(subscriber, :open) do
    _message = send(subscriber, {:ordoq_gate, :work, :open})
    :ok
  end

  defp notify(subscriber, :closed) do
    _message = send(subscriber, {:ordoq_gate, :work, :closed, :test_transition})
    :ok
  end
end

defmodule OrdoqTest do
  use ExUnit.Case, async: false

  alias Ordoq.Config
  alias OrdoqTest.{GateState, Support}

  @trace_id "4bf92f3577b34da6a3ce929d0e0e4736"
  @traceparent "00-#{@trace_id}-00f067aa0ba902b7-01"

  doctest Ordoq

  setup do
    restart_ordoq([])
    :ok
  end

  describe "configuration" do
    test "loads bounded defaults and exposes build environment" do
      assert {:ok, config} = Config.new([])
      assert Config.health_gate(config) == nil
      assert Config.max_queued(config) > 0
      assert Config.max_in_flight(config) > 0
      assert Config.mix_env() == :test
      assert Config.test?()
    end

    test "rejects unknown, malformed, and inconsistent values" do
      assert {:error, %{code: :invalid_config}} = Config.new(unknown: 1)
      assert {:error, %{code: :invalid_config}} = Config.new(max_queued: 0)
      assert {:error, %{code: :invalid_config}} = Config.new(health_gate: "work")

      assert {:error, %{code: :invalid_config}} =
               Config.new(min_priority: 20, default_priority: 10)
    end

    test "accepts one named optional health gate" do
      assert {:ok, config} = Config.new(health_gate: :work)
      assert Config.health_gate(config) == :work
    end
  end

  describe "admission and execution" do
    test "returns a job ID and executes the callback" do
      assert {:ok, id} = Ordoq.enqueue(Support, :notify, [self(), :executed])
      assert is_integer(id) and id > 0
      assert_receive :executed
      assert_eventually_empty()
    end

    test "rejects invalid callbacks and duplicate live names" do
      assert {:error, %{code: :invalid_job}} = Ordoq.enqueue(Support, :missing, [])

      assert {:ok, _id} =
               Ordoq.enqueue(Support, :notify, [self(), :later],
                 name: :unique,
                 delay_ms: 1_000
               )

      assert {:error, %{code: :duplicate_name}} =
               Ordoq.enqueue(Support, :notify, [self(), :duplicate], name: :unique)
    end

    test "enforces queue capacity independently from running work" do
      restart_ordoq(max_in_flight: 1, max_queued: 1)
      assert {:ok, running_id} = Ordoq.enqueue(Support, :block, [self(), :running])
      assert_receive {:started, :running, worker}

      assert {:ok, queued_id} =
               Ordoq.enqueue(Support, :notify, [self(), :queued], delay_ms: 1_000)

      assert {:error, %{code: :overloaded}} =
               Ordoq.enqueue(Support, :notify, [self(), :rejected])

      assert :ok = Ordoq.cancel(queued_id)
      send(worker, :continue)
      assert running_id != queued_id
    end

    test "never exceeds configured concurrent execution" do
      restart_ordoq(max_in_flight: 2, max_queued: 3)

      ids =
        Enum.map(1..3, fn marker ->
          {:ok, id} = Ordoq.enqueue(Support, :block, [self(), marker])
          id
        end)

      assert_receive {:started, first, first_worker}
      assert_receive {:started, second, second_worker}
      refute_receive {:started, _third, _worker}, 30
      assert first != second
      assert %Ordoq.Stats{in_flight: 2, queued: 1} = Ordoq.stats()

      Enum.each(ids, &Ordoq.cancel/1)
      send(first_worker, :continue)
      send(second_worker, :continue)
    end

    test "a closed health gate rejects admission and pauses queued dispatch" do
      _ignored = Application.stop(:ordoq)
      start_supervised!({GateState, :open})
      # The gate implementation is configured rather than hardcoded, so Ordoq
      # depends on no particular health-checking library.
      Application.put_env(:ordoq, :gate, GateState)
      on_exit(fn -> Application.delete_env(:ordoq, :gate) end)
      restart_ordoq(health_gate: :work, max_in_flight: 1)

      assert {:ok, _id} = Ordoq.enqueue(Support, :block, [self(), :running])
      assert_receive {:started, :running, worker}
      assert {:ok, _id} = Ordoq.enqueue(Support, :notify, [self(), :queued])

      assert :ok = GateState.set(:closed)
      send(worker, :continue)
      refute_receive :queued, 30

      assert {:error, %{code: :shutting_down}} =
               Ordoq.enqueue(Support, :notify, [self(), :rejected])

      assert :ok = GateState.set(:open)
      assert_receive :queued
      assert_eventually_empty()
    end
  end

  describe "scheduling and control" do
    test "await_idle waits for queued and running work without closing admission" do
      restart_ordoq(max_in_flight: 1)
      assert {:ok, _id} = Ordoq.enqueue(Support, :block, [self(), :running])
      assert_receive {:started, :running, worker}
      assert {:ok, _id} = Ordoq.enqueue(Support, :notify, [self(), :queued])

      waiter = Task.async(fn -> Ordoq.await_idle(200) end)
      refute Task.yield(waiter, 20)
      send(worker, :continue)

      assert_receive :queued
      assert Task.await(waiter) == :ok
      assert {:ok, _id} = Ordoq.enqueue(Support, :notify, [self(), :still_open])
      assert_receive :still_open
    end

    test "await_idle returns a structured timeout without closing admission" do
      assert {:ok, _id} = Ordoq.enqueue(Support, :block, [self(), :idle_timeout])
      assert_receive {:started, :idle_timeout, worker}

      assert {:error, %{code: :await_idle_timeout}} = Ordoq.await_idle(20)
      assert {:ok, _id} = Ordoq.enqueue(Support, :notify, [self(), :accepted])
      send(worker, :continue)
      assert_receive :accepted
    end

    test "await_idle reports exhausted jobs and resets the completed batch result" do
      assert {:ok, _id} = Ordoq.enqueue(Support, :fail, [], max_attempts: 1)
      assert {:error, %{code: :await_idle_failed, details: %{failed_jobs: 1}}} = Ordoq.await_idle(200)
      assert :ok = Ordoq.await_idle(200)
    end

    test "drain rejects new jobs and waits for active work" do
      assert {:ok, _id} = Ordoq.enqueue(Support, :block, [self(), :draining])
      assert_receive {:started, :draining, worker}

      drain = Task.async(fn -> Ordoq.drain(200) end)
      refute Task.yield(drain, 20)

      send(worker, :continue)
      assert Task.await(drain) == :ok
      assert {:error, %{code: :shutting_down}} = Ordoq.enqueue(Support, :notify, [self(), :rejected])
    end

    test "drain returns a structured timeout and leaves admission closed" do
      assert {:ok, _id} = Ordoq.enqueue(Support, :block, [self(), :timeout])
      assert_receive {:started, :timeout, worker}

      assert {:error, %{code: :drain_timeout}} = Ordoq.drain(20)
      assert {:error, %{code: :shutting_down}} = Ordoq.enqueue(Support, :notify, [self(), :rejected])
      send(worker, :continue)
    end

    test "orders ready jobs by priority and FIFO within a priority" do
      restart_ordoq(max_in_flight: 1)
      {:ok, blocker} = Ordoq.enqueue(Support, :block, [self(), :blocker])
      assert_receive {:started, :blocker, worker}

      {:ok, _} = Ordoq.enqueue(Support, :notify, [self(), :low], priority: 20)
      {:ok, _} = Ordoq.enqueue(Support, :notify, [self(), :first_high], priority: 1)
      {:ok, _} = Ordoq.enqueue(Support, :notify, [self(), :second_high], priority: 1)
      send(worker, :continue)

      assert_receive :first_high
      assert_receive :second_high
      assert_receive :low
      assert :ok = missing_after_terminal(blocker)
    end

    test "does not run a delayed job early" do
      {:ok, _id} = Ordoq.enqueue(Support, :notify, [self(), :delayed], delay_ms: 50)
      refute_receive :delayed, 20
      assert_receive :delayed, 200
    end

    test "locking and unlocking are idempotent for a queued named job" do
      restart_ordoq(max_in_flight: 1)
      {:ok, blocker_id} = Ordoq.enqueue(Support, :block, [self(), :blocker])
      assert_receive {:started, :blocker, blocker}

      {:ok, _id} =
        Ordoq.enqueue(Support, :notify, [self(), :unlocked], name: :locked, delay_ms: 40)

      assert :ok = Ordoq.lock(:locked)
      assert :ok = Ordoq.lock(:locked)
      refute_receive :unlocked, 70
      assert %Ordoq.Stats{locked: 1} = Ordoq.stats()
      assert :ok = Ordoq.unlock(:locked)
      assert :ok = Ordoq.unlock(:locked)
      assert :ok = Ordoq.cancel(blocker_id)
      send(blocker, :continue)
      assert_receive :unlocked
    end

    test "cancels queued and running jobs without retaining their names" do
      {:ok, queued_id} =
        Ordoq.enqueue(Support, :notify, [self(), :never], name: :queued, delay_ms: 1_000)

      assert :ok = Ordoq.cancel(queued_id)
      assert {:error, %{code: :job_not_found}} = Ordoq.cancel(queued_id)

      {:ok, running_id} = Ordoq.enqueue(Support, :block, [self(), :running], name: :running)
      assert_receive {:started, :running, _worker}
      assert :ok = Ordoq.cancel(:running)
      assert {:error, %{code: :job_not_found}} = Ordoq.cancel(running_id)
      refute_receive :never, 30
    end
  end

  describe "timeouts and retries" do
    test "a timeout releases capacity and cannot wedge the queue" do
      restart_ordoq(max_in_flight: 1, default_ttr_ms: 30)
      {:ok, _id} = Ordoq.enqueue(Support, :block, [self(), :timed_out], ttr_ms: 30)
      assert_receive {:started, :timed_out, _worker}
      {:ok, _id} = Ordoq.enqueue(Support, :notify, [self(), :after_timeout])
      assert_receive :after_timeout, 250
      assert_eventually_empty()
    end

    test "touch extends only the active attempt timeout" do
      restart_ordoq(default_ttr_ms: 30, max_ttr_ms: 200)
      {:ok, id} = Ordoq.enqueue(Support, :touch_and_block, [self()], ttr_ms: 30)
      assert_receive {:started, worker}
      refute_receive :unexpected, 50
      assert %Ordoq.Stats{in_flight: 1} = Ordoq.stats()
      send(worker, :continue)
      assert_eventually_empty()
      assert {:error, %{code: :job_not_found}} = Ordoq.cancel(id)
    end

    test "retries failures up to the declared maximum" do
      restart_ordoq(default_retry_base_ms: 0, retry_jitter_ms: 0)
      {:ok, counter} = start_supervised({Agent, fn -> 0 end})

      assert {:ok, _id} =
               Ordoq.enqueue(Support, :fail_once, [self(), counter],
                 max_attempts: 2,
                 retry_base_ms: 0
               )

      assert_receive {:attempt, 1}
      assert_receive {:attempt, 2}
      assert_eventually_empty()
    end
  end

  describe "observability" do
    test "publishes canonical finite telemetry and propagates trace context" do
      handler = {__MODULE__, make_ref()}
      test_pid = self()

      assert :ok =
               :telemetry.attach(
                 handler,
                 [:ordoq, :job, :terminal],
                 &__MODULE__.forward_event/4,
                 test_pid
               )

      on_exit(fn -> :telemetry.detach(handler) end)
      Logger.metadata(trace_id: @trace_id)

      assert {:ok, _id} = Ordoq.enqueue(Support, :report_trace, [self()])

      assert_receive {:trace_id, @trace_id}
      assert_receive {:event, [:ordoq, :job, :terminal], %{count: 1}, %{result: :ok}}
    end
  end

  @doc false
  @spec forward_event([atom(), ...], map(), map(), pid()) :: :ok
  def forward_event(event, measurements, metadata, recipient) do
    send(recipient, {:event, event, measurements, metadata})
    :ok
  end

  # Restarts the OTP application with isolated in-memory settings for one test.
  @spec restart_ordoq(keyword()) :: :ok
  defp restart_ordoq(settings) do
    _ignored = Application.stop(:ordoq)
    :ok = Application.put_env(:ordoq, Config, settings)
    {:ok, _applications} = Application.ensure_all_started(:ordoq)
    :ok
  end

  # Waits for terminal cleanup through bounded public state rather than internals.
  @spec assert_eventually_empty(non_neg_integer()) :: :ok
  defp assert_eventually_empty(attempts \\ 20)
  defp assert_eventually_empty(0), do: flunk("Ordoq did not become empty")

  defp assert_eventually_empty(attempts) do
    case Ordoq.stats() do
      %Ordoq.Stats{in_flight: 0, queued: 0} -> :ok
      _busy -> assert_eventually_empty_after_message(attempts)
    end
  end

  # Gives asynchronous terminal messages a bounded opportunity to reach the queue.
  @spec assert_eventually_empty_after_message(pos_integer()) :: :ok
  defp assert_eventually_empty_after_message(attempts) do
    receive do
      _message -> assert_eventually_empty(attempts - 1)
    after
      10 -> assert_eventually_empty(attempts - 1)
    end
  end

  # Confirms that a completed job no longer has a live cancellation target.
  @spec missing_after_terminal(pos_integer()) :: :ok
  defp missing_after_terminal(id) do
    assert {:error, %{code: :job_not_found}} = Ordoq.cancel(id)
    :ok
  end
end
