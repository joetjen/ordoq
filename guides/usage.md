# Usage

## Enqueueing jobs

```elixir
{:ok, id} =
  Ordoq.enqueue(MyJobs, :rebuild, [account_id],
    name: {:account_rebuild, account_id},
    priority: 10,
    delay_ms: 500,
    ttr_ms: 30_000,
    max_attempts: 3,
    retry_base_ms: 250
  )
```

Supported options are:

| Option | Meaning | Default |
| --- | --- | --- |
| `:name` | Unique atom or tuple retained until terminal cleanup | `nil` |
| `:priority` | Lower values run first | `10` |
| `:delay_ms` | Initial eligibility delay | `0` |
| `:ttr_ms` | Maximum duration of one attempt | `60_000` |
| `:max_attempts` | Total attempts, including the first | `1` |
| `:retry_base_ms` | Initial exponential retry delay | `250` |

Every value is validated against `Ordoq.Config`. Invalid definitions return an
error with code `:invalid_job`; they never enter the queue.

## Callback contract

Ordoq calls `module.function(touch, ...args)`. The callback may call
`touch.(nil)` to restart its configured attempt timeout or `touch.(milliseconds)`
to request another validated duration. A touch applies only to the currently
running attempt, so late callbacks cannot alter a retry.

Returned values are consumed and discarded. Applications that require a result
must deliver it through an explicit application-owned boundary. Do not use
Ordoq as a result store.

## Control operations

```elixir
:ok = Ordoq.lock(:nightly_export)
:ok = Ordoq.unlock(:nightly_export)
:ok = Ordoq.cancel(job_id)
%Ordoq.Stats{} = Ordoq.stats()
```

Locking applies only to queued named jobs; it does not suspend a running
callback. Cancellation terminates running work or removes queued work. The
statistics snapshot exposes counts and capacity only, never callback payloads
or internal process structures.

## Runtime configuration

Stable instance-wide settings belong to Ordoq's application namespace:

```elixir
config :ordoq, Ordoq.Config,
  max_queued: 2_000,
  max_in_flight: 8,
  default_ttr_ms: 60_000,
  max_ttr_ms: 3_600_000,
  max_attempts: 5,
  default_retry_base_ms: 250,
  max_retry_delay_ms: 30_000,
  retry_jitter_ms: 250,
  shutdown_timeout_ms: 5_000,
  health_gate: :background_work
```

All settings are optional and use source-owned safe defaults. Configuration is
validated before the queue or worker supervisor starts. Changes require an
application restart.

`max_queued` counts admitted jobs not currently executing. `max_in_flight` is a
separate worker limit. This lets active work release one admission slot without
allowing worker concurrency to grow.

`health_gate` is optional and requires the consuming application to include and
configure a gate implementing `Ordoq.Gate`. A closed gate rejects new jobs with error code
`:shutting_down`, retains queued jobs without dispatching them, and lets active
callbacks finish. Reopening the gate resumes dispatch. This behavior makes the
same admission boundary usable for dependency health and graceful drain.

## Graceful shutdown

Call `Ordoq.drain/1` from the host application's shutdown orchestration after
closing its health admission gates:

```elixir
:ok = Ordoq.drain(5_000)
```

Drain permanently rejects new jobs, prevents queued and delayed jobs from
starting, and waits only for attempts already running. It returns
`{:error, %Ordoq.Error{code: :drain_timeout}}` if the deadline expires and
leaves admission closed. The host's overall termination grace period must
exceed this timeout. Queued jobs do not survive the subsequent application
stop because Ordoq is deliberately in-memory.

## Failure and retry semantics

An exception, exit, or timeout is retried only when `max_attempts` permits it.
Retries use bounded exponential backoff and bounded deterministic jitter.
Timeout termination cannot prove that an external side effect did not occur.
Any retried callback that touches an external system must therefore be
idempotent or use an application-owned deduplication mechanism.

No queue state is replicated or persisted. Pod replacement, application stop,
and unrecoverable queue-process failure discard local jobs.
