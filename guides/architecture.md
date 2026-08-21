# Architecture

`ordoq` is a runtime-capable **Library** that owns one bounded, node-local,
in-memory priority queue. It admits callback jobs, orders them, executes them in
a supervised task pool, enforces attempt deadlines, and optionally retries
failed attempts. It has no image or independent deployment.

## Responsibility and boundaries

Ordoq is deliberately not a durable or distributed job system. Every BEAM
instance that includes the dependency owns an independent queue, job namespace,
capacity allowance, and retry state. Queue-process failure or node replacement
loses all accepted work. Work that must survive those events belongs in
RabbitMQ or another durable source-owning system.

The OTP application is necessary because the library owns long-lived queue and
worker-supervisor processes. `Ordoq.Config` owns operational settings,
`Ordoq.Error` owns stable failures, and `Ordoq.Telemetry` owns the emitted event
contract. The optional health-check library owns health state; Ordoq only
subscribes to one configured gate.

## Code map

| Path | Purpose |
| --- | --- |
| `lib/ordoq.ex` | Public enqueue, control, statistics, wait, and drain API. |
| `lib/ordoq/application.ex` | Configuration validation and root supervision startup. |
| `lib/ordoq/config.ex` | Typed defaults, validation, and application-configuration access. |
| `lib/ordoq/job.ex` | Internal validated job value and enqueue-option normalization. |
| `lib/ordoq/queue.ex` | Complete queue state machine and worker lifecycle. |
| `lib/ordoq/stats.ex` | Payload-free public utilization snapshot. |
| `lib/ordoq/telemetry.ex` | Canonical `[:ordoq, ...]` events, emitted through `:telemetry`. |
| `test/ordoq/` | Deterministic unit, property, lifecycle, and package-boundary tests. |
| `test/fixtures/consumer_app/` | Test-only application proving normal dependency startup. |

## Runtime and startup

```text
Ordoq.Supervisor (:rest_for_one)
├── Ordoq.TaskSupervisor (Task.Supervisor, max_children: max_in_flight)
└── Ordoq.Queue (GenServer, shutdown: shutdown_timeout_ms)
```

The child order matters. If the task supervisor fails, `:rest_for_one` also
restarts the queue so it cannot retain task references owned by a replaced
supervisor. If only the queue fails, its tasks remain earlier siblings, but the
queue terminates every task it still knows during orderly termination. An
abnormal queue crash loses in-memory state; callers must not treat Ordoq as a
durability boundary.


## Application startup call flow

OTP starts the following application callbacks in dependency/release order. Each callback must return only after its root supervisor or bounded startup work succeeds:

1. OTP invokes **Ordoq.Application.start/2** in `libs/ordoq/lib/ordoq/application.ex`. It calls **Config.load/0** → **Supervisor.start_link/2** → **children/1** → **supervisor_options/0**.

The callback and its startup/shutdown helpers have this source-derived flow:

| Entry point or callback | Visibility | Direct call flow |
| --- | --- | --- |
| **start/2** | `def` | calls **Config.load/0** → **Supervisor.start_link/2** → **children/1** → **supervisor_options/0**; references **Config**, **Supervisor** |
| **children/1** | `defp` | calls **Supervisor.child_spec/2** → **Config.max_in_flight/1** → **Config.shutdown_timeout_ms/1**; references **Supervisor**, **Task.Supervisor**, **Ordoq.TaskSupervisor**, **Config**, **Queue** |
| **supervisor_options/0** | `defp` | performs no further named function call in its body; references **Ordoq.Supervisor** |

The project-owned runtime process set is **Ordoq.Queue**. Exact child order and option-dependent children are defined by the `start/2` and supervisor `init/1` flows below; dependency-owned processes remain documented by their owning libraries.

## Process call flows

### **Ordoq.Queue**

- **OTP abstraction:** `GenServer` implemented in `libs/ordoq/lib/ordoq/queue.ex`.
- **Owner and restart:** started from **Ordoq.Application**. Unless its child specification overrides this, OTP uses the abstraction's standard permanent-child restart behavior.
- **Registration and lookup:** the concrete `start_link` flow below is authoritative for a local name, Registry/via tuple, or caller-supplied name; no undocumented global lookup is assumed.
- **State and resources:** `init` and `handle_continue` rows show the functions used to construct state and acquire resources. External dependency processes are not re-owned by this module.
- **Failure and shutdown:** callback crashes are returned to the supervising owner. A listed `terminate` flow performs explicit cleanup; otherwise OTP and resource owners perform their standard teardown.

| Entry point or callback | Visibility | Direct call flow |
| --- | --- | --- |
| **start_link/1** | `def` | calls **GenServer.start_link/3**; references **GenServer** |
| **init/1** | `def` | calls **subscribe_gate/1** → **Config.health_gate/1** → **initial_state/2**; references **Config** |
| **handle_call/3** | `def` | calls **prepare_job/6** → **accept_job/2** → **reject_job/3** |
| **handle_info/2** | `def` | calls **dispatch/1** |
| **terminate/2** | `def` | calls **unsubscribe_gate/1** → **state.gate/0** → **Enum.each/2** → **state.running/0** → **stop_task/1** → **running.task/0**; references **Enum** |


## Communication and data flow

Public operations are local synchronous `GenServer.call/3` requests. Worker
completion and timers use local process messages. `Ordoq.Queue.Tree` and
`Ordoq.Queue.Timer` own Erlang interop; `Ordoq.Telemetry` owns context propagation
and event execution. No database, broker, filesystem, HTTP endpoint, or cache
is contacted by Ordoq itself. User callbacks may perform effects, but those
effects and their idempotency remain caller-owned.

## Configuration and operational behavior

`Ordoq.Config` is the only production module that reads application
configuration. It never reads environment files or OS variables. Hosts place
normalized settings in the Ordoq namespace from their own runtime boundary.
Changing settings requires restarting the application because the validated
struct is placed in queue state.

Change job input semantics in **Ordoq.Job**, scheduling and lifecycle semantics
in **Ordoq.Queue**, public types/contracts in `Ordoq`, and event schemas in
`Ordoq.Telemetry`. Add no second queue or distributed behavior without an
explicit architectural change.

## Failure, scaling, security, and observability

Capacity is bounded independently for queued and running jobs. Each replicated
service instance gets the full configured allowance; it is not a cluster-wide
quota. Retries are at-least-once, and timeout cannot prove an external side
effect did not happen, so effectful callbacks must be idempotent.

Errors and telemetry use finite categories. Job arguments, names, IDs, return
values, exceptions, and trace payloads are excluded from metric tags. The
library exposes events but starts no exporter or operational listener.

## Development guide

Start behavior changes at the public function in `Ordoq`, then follow the
matching `handle_call` or `handle_info` path through **Ordoq.Queue**. Read the
unit and property tests before changing ordering, capacity, timeout, retry, or
cleanup behavior. Run `mix setup`, `mix precommit`, production compilation,
ExDoc, and package inspection. The consumer fixture is deterministic; no
external integration system is required or automatically started.
