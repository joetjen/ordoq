# Examples

## Named deduplicated work

```elixir
Ordoq.enqueue(SearchJobs, :reindex, [tenant_id],
  name: {:tenant_reindex, tenant_id},
  priority: 20
)
```

A second live job with the same name returns `:duplicate_name`. The name becomes
available again only after success, terminal failure, timeout, or cancellation.

## Delayed bounded retry

```elixir
Ordoq.enqueue(WebhookJobs, :deliver, [webhook],
  delay_ms: 1_000,
  ttr_ms: 10_000,
  max_attempts: 3,
  retry_base_ms: 500
)
```

The callback must be idempotent because a timeout or connection failure cannot
establish whether a remote side effect occurred.

## Maintenance lock

```elixir
{:ok, _id} =
  Ordoq.enqueue(ReportJobs, :generate, [report_id],
    name: {:report, report_id},
    delay_ms: 5_000
  )

:ok = Ordoq.lock({:report, report_id})
:ok = Ordoq.unlock({:report, report_id})
```

The lock is local and works only while the named job remains queued. It is not a
distributed lock and cannot coordinate separate service instances.

## Complete bounded batch

This example combines naming, priority, delay, timeout extension, bounded
retry, and finite-batch completion:

```elixir
defmodule RebuildJob do
  def run(touch, recipient, account_id) do
    :ok = touch.(5_000)
    send(recipient, {:rebuilt, account_id})
  end
end

{:ok, _id} =
  Ordoq.enqueue(RebuildJob, :run, [self(), 42],
    name: {:account_rebuild, 42},
    priority: 5,
    delay_ms: 100,
    ttr_ms: 1_000,
    max_attempts: 3,
    retry_base_ms: 250
  )

:ok = Ordoq.await_idle(10_000)
```

`await_idle/1` keeps admission open while waiting. For application shutdown,
use `drain/1` instead and accept that queued in-memory work is discarded.
