# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Ordoq is now an independent, MIT-licensed library.** It was extracted from a
  private workspace where it depended on five in-house libraries. Those
  dependencies are gone; the only runtime dependency is `:telemetry`.

- **BREAKING**: telemetry events lost their vendor prefix. `[:asco, :ordoq, …]`
  is now `[:ordoq, …]`, emitted through `:telemetry` directly rather than
  through a DSL.

- **BREAKING**: the health gate is configured rather than assumed. Ordoq no
  longer names a particular health-checking library; supply any module
  implementing the new `Ordoq.Gate` behaviour:

      config :ordoq, gate: MyApp.HealthGate

  Its transition messages are `{:ordoq_gate, gate, :open}` and
  `{:ordoq_gate, gate, :closed, reason}`, previously `{:asco_health_gate, …}`.

- **BREAKING**: context propagation from enqueue to execution is pluggable
  through the new `Ordoq.Telemetry.Context` behaviour. The default carries
  `Logger.metadata/0`, which needs no tracing library; configure another with
  `config :ordoq, context: MyApp.TraceContext`.

- `Ordoq.Error` is a plain exception rather than a generated one. It keeps the
  same `:code`, `:message` and `:details` fields and the same per-code
  constructors, so matching on `%Ordoq.Error{code: :overloaded}` is unchanged.

### Fixed

- Dialyzer passes again. Four specs named `Ordoq.Telemetry.Context.t/0`, which
  did not exist; it is now defined, and both callbacks use it. `:logger` is
  declared in `extra_applications`, since Ordoq logs through `Logger`, which
  also makes the release declare the dependency it relies on.

- A configured gate that is not a module now fails loudly instead of being
  reported as an unavailable dependency. The `is_atom/1` check in front of it
  could never fail for the declared type, and silently treating a
  misconfiguration as an outage hid the mistake.

## [Unreleased]

### Changed

- Completed the repository compliance pass with project-local Dialyzer state,
  deterministic setup, property and package-boundary verification, warning-free
  documentation, and exact scheduler lifecycle documentation.
- Removed obsolete library permanence configuration and the unused generic
  configuration helper.

- Moved `ARCHITECTURE.md` directly after `README.md` in ExDoc and expanded it with source-derived application-start and per-process call flows.

- Normalized the deterministic Mix helper, toolchain, console, CI, documentation headings, fixture metadata, and release exclusions to the shared library repository standard.
- Moved the standalone consumer verifier into the project-owned
  `test/fixtures/consumer_app` boundary.

- **BREAKING**: Replaced the unbounded `append/4` queue with bounded
  `enqueue/4`, cancellation, safe statistics, supervised concurrency,
  event-driven delays, and terminal cleanup.
- **BREAKING**: Renamed task options to explicit millisecond forms and removed
  the ineffective `max_locks` option and unsafe internal-state inspection.
- Defined Ordoq as a local, in-memory, non-durable runtime with explicit
  at-least-once retry semantics.
- Replaced legacy telemetry with canonical `[:asco, :ordoq, ...]` contracts and
  propagated captured trace context into worker attempts.

### Added

- Added pinned dependency-vulnerability, licence, secret-detection, SBOM, and
  provenance pipeline gates; the tooling remains development-only and outside
  published library contents.

- Added a developer-focused `ARCHITECTURE.md` and deterministic ExDoc inclusion.


- Added `Ordoq.await_idle/1` so finite batch applications can wait for queued,
  delayed, and running work without closing admission or discarding retries,
  while reporting exhausted or cancelled jobs to the caller.
- Added validated runtime configuration, bounded retries, idempotent queued-job
  locking, running-job cancellation, and a standalone consumer verification app.
- Added optional `asco_health_check` gate integration for bounded admission,
  paused dispatch, and graceful drain.
- Added bounded `Ordoq.drain/1` shutdown admission and active-attempt waiting
  with a structured timeout result.

### Fixed

- Capture trace context in the submitting process before crossing the queue
  GenServer boundary, so worker attempts receive the caller's W3C trace and
  `asco_trace_id` instead of the queue process's empty context.

## [1.0.1] - 2026-06-02

### Changed

- Updated the `asco_error` runtime dependency constraint from `~> 1.1.3` to `~> 1.1`.

## [1.0.0]

## [1.0.0] - 2026-02-25

### Changed

- **BREAKING**: Migrated telemetry module to ASCO.Telemetry DSL-based system.
  - `Ordoq.Telemetry.events/0` now auto-generated from `defduration` and `defcounter` macros
  - `Ordoq.Telemetry.metrics/0` exported for automatic Prometheus integration
  - Use `use ASCO.Telemetry` instead of manual `events/0` declarations
- Switched queue telemetry emissions to DSL-generated emitters.

## [0.2.3]

### Changed

- **BREAKING**: Updated telemetry events structure for task operations to follow consistent pattern
- Refactored telemetry events for appending, locking, unlocking, and timeout operations

## [0.2.2] - 2026-02-12

### Added

- Added `queue_name` option to task options for better task identification and organization

### Changed

- Enhanced MixHelper documentation for improved clarity on dependency management functions

## [0.2.1] - 2026-01-15

### Changed

- Updated `asco_error` dependency from 0.1.0 to 0.2.0
- Updated `asco_erl` dependency from 0.1.0 to 0.1.1
- Updated `asco_telemetry` dependency from 0.1.0 to 0.2.1
- Updated `asco_utils` dependency from 0.1.0 to 0.1.1

## [0.2.0] - 2026-01-15

### Added

- Added `[:ordoq, :queue, :depth, :value]` last_value metric for queue depth monitoring
- Added telemetry documentation to README.md and USAGE_GUIDE.md

### Changed

- **BREAKING**: Updated telemetry events from 4-5 atom to consistent 4-atom naming pattern `[:ordoq, :queue, :operation, :metric_type]`
- **BREAKING**: Converted span events to distribution metrics with explicit buckets (10-10000ms)
- **BREAKING**: Replaced `[:ordoq, :queue, :task, :execute, :start/:stop]` with `[:ordoq, :queue, :task_execute, :duration]`
- **BREAKING**: Replaced `[:ordoq, :queue, :task, :timeout]` with `[:ordoq, :queue, :task_timeout, :count]`
- **BREAKING**: Added categorical aggregation tags: `queue_name`, `status`

## [0.1.0] - 2025-01-23

### Added

#### Core Queue System

- GenServer-based priority queue for asynchronous background task processing
- `Ordoq.append/4` - Add tasks to the queue with configurable options
- `Ordoq.lock/1` - Prevent named tasks from executing
- `Ordoq.unlock/1` - Allow locked tasks to execute again
- Priority-based task scheduling with configurable priority levels (lower = higher priority)
- Delayed task execution with configurable delay times

#### Timeout Management

- Configurable TTR (time-to-run) for task execution timeouts
- Touch function mechanism for extending task timeouts during long-running operations
- Automatic task cleanup on timeout expiration
- Default 60-second timeout with customizable per-task TTR

#### Task Configuration

- Named tasks with support for atoms and tuples as identifiers
- Priority levels (default: 10, critical: 1, high: 5, normal: 10, low: 20)
- Delay scheduling for deferred execution
- Max locks limit to control unlock frequency
- Support for passing arbitrary arguments to task functions

#### Task Locking System

- Lock/unlock mechanism to temporarily prevent task execution
- Named task identification for precise lock control
- Max locks configuration to limit unlock attempts
- Lock state persistence during task lifecycle

#### Telemetry Instrumentation

- `[:ordoq, :task, :start]` - Task execution started
- `[:ordoq, :task, :stop]` - Task execution completed
- `[:ordoq, :task, :exception]` - Task execution failed
- `[:ordoq, :timeout]` - Task timeout occurred
- `[:ordoq, :locked]` - Task execution prevented by lock
- `[:ordoq, :touched]` - Task timeout extended
- `[:ordoq, :queue, :append]` - Task added to queue
- Comprehensive metadata for all telemetry events
- Integration with `:telemetry` for monitoring and observability

#### Error Handling

- `Ordoq.Error` exception module with detailed error information
- Structured error handling for task execution failures
- Timeout error reporting with task context
- Lock violation error tracking

#### Documentation

- Comprehensive README with overview and installation
- QUICKSTART.md - Get started guide with basic usage patterns
- USAGE_GUIDE.md - Complete API reference and core concepts (865 lines)
- EXAMPLES.md - Real-world examples including:
  - Email processing system with priorities
  - Report generation with progress tracking
  - Data synchronization patterns
  - Image processing pipeline
  - Scheduled jobs implementation
  - Retry mechanisms
  - Rate limiting strategies
  - Maintenance mode handling
- AGENTS.md - Development workflow and conventions

#### Testing

- Comprehensive test suite for queue operations
- Task execution and timeout testing
- Lock/unlock behavior verification
- Priority scheduling validation
- Telemetry event verification

#### CI/CD

- GitLab CI configuration for automated testing
- Documentation generation and deployment
- Code quality checks with Credo
- Type checking with Dialyzer
