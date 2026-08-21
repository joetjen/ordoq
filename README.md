# Overview

Ordoq is a bounded, local, in-memory priority queue for asynchronous Elixir
callbacks. Adding the dependency starts its queue and supervised worker pool
automatically.

## Responsibilities

- Own bounded local in-memory priority/FIFO callback admission and supervised execution.

## Non-responsibilities

- Claim durability, distributed coordination, or cross-instance job ownership.

Ordoq is intended for process-local background work. It is not durable, does
not coordinate multiple BEAM instances, and loses queued work when its owning
instance stops. Use RabbitMQ or another durable system when work must survive
instance replacement or cross service boundaries.

## Contract

- Admission is finite and returns `Ordoq.Error` with code `:overloaded` when the
  configured queued-job capacity is full.
- Ready jobs use lower numerical priorities first and FIFO order within one
  priority.
- Delayed jobs become eligible at their monotonic local deadline.
- Named jobs remain unique through their entire queued or running lifecycle.
- Only queued named jobs can be locked. Lock and unlock are idempotent while
  the job remains in the corresponding queued state.
- Running callbacks are owned by a bounded `Task.Supervisor`.
- An optional health gate can reject new admission and pause queued dispatch
  during dependency outages or graceful drain without terminating work already
  in flight.
- `Ordoq.drain/1` permanently closes local admission and waits within a bounded
  deadline for work already in flight.
- Timeouts, exits, successful results, cancellations, and late messages all
  release their capacity and identifiers.
- Retries are disabled by default. Enabling retries creates at-least-once
  execution, so external side effects must be idempotent.

## Installation

```elixir
def deps do
  [
    {:ordoq, "~> 2.0"}
  ]
end
```

Workspace development may use the repository's established local-path/Git-tag
dependency helper. Consumer fixtures, tests, documentation output, and
development tools are excluded from the released package.

## Basic use

Callbacks receive a timeout-extension function before their declared arguments:

```elixir
defmodule MailJob do
  def deliver(touch, recipient) do
    :ok = touch.(nil)
    send(recipient, :delivered)
  end
end

{:ok, job_id} = Ordoq.enqueue(MailJob, :deliver, [self()], priority: 5)
```

Passing `nil` to the touch function restarts the callback's configured
time-to-run. A positive millisecond value requests a different duration within
the configured maximum.

See [Usage](USAGE_GUIDE.md) for configuration and lifecycle details and
[Examples](EXAMPLES.md) for focused patterns.

## Name origin

Ordoq is a coined functional name for an ordered queue. It reflects the
library's responsibility for priority and FIFO ordering without implying a
durable or distributed job system.

## Telemetry

`Ordoq.Telemetry.events/0` publishes canonical declarations under
`[:ordoq, ...]`:

- `[:ordoq, :job, :enqueue]`
- `[:ordoq, :job, :execute, :start | :stop | :exception]`
- `[:ordoq, :job, :retry]`
- `[:ordoq, :job, :terminal]`
- `[:ordoq, :job, :control]`
- `[:ordoq, :queue, :depth]`
- `[:ordoq, :queue, :in_flight]`

Job names, identifiers, arguments, results, and exception text are never metric
tags. Ordoq does not start a metrics exporter or HTTP listener.
