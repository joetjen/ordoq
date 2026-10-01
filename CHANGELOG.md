# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-10-01

### Fixed

- The README links the usage and examples guides at their `guides/` paths;
  they pointed at `USAGE_GUIDE.md` and `EXAMPLES.md`, which no longer exist.
- `mix hex.publish` runs in the `docs` environment, where `ex_doc` is
  available, instead of failing because the `docs` task is missing in `dev`.
- The README names `Ordoq.Telemetry` and all seven events instead of
  `Ordoq.Telemetry.events/0`, which no longer exists, and three of them.

## [0.1.0] - 2026-10-01

The first public release. Ordoq was extracted from a private workspace, where
it went through unpublished versions 0.1.0 to 1.0.1 (see
[Before the public release](#before-the-public-release)); "breaking" below is
relative to the last of them.

### Changed

- **Ordoq is an independent, MIT-licensed library.** Its private predecessor
  depended on five in-house libraries; the only runtime dependency now is
  `:telemetry`.
- **BREAKING**: a bounded `enqueue/4` replaces the unbounded `append/4`, with
  cancellation, safe statistics, supervised concurrency, event-driven delays
  and terminal cleanup.
- **BREAKING**: task options are named in explicit millisecond forms; the
  ineffective `max_locks` option and unsafe internal-state inspection are gone.
- **BREAKING**: telemetry events are `[:ordoq, …]`, emitted through
  `:telemetry` directly.
- **BREAKING**: the health gate is configured rather than assumed. Supply any
  module implementing the `Ordoq.Gate` behaviour:

      config :ordoq, gate: MyApp.HealthGate

  Its transition messages are `{:ordoq_gate, gate, :open}` and
  `{:ordoq_gate, gate, :closed, reason}`.
- **BREAKING**: context propagation from enqueue to execution is pluggable
  through the `Ordoq.Telemetry.Context` behaviour. The default carries
  `Logger.metadata/0`, which needs no tracing library; configure another with
  `config :ordoq, context: MyApp.TraceContext`.
- Ordoq is defined as a local, in-memory, non-durable runtime with explicit
  at-least-once retry semantics.
- `Ordoq.Error` is a plain exception with `:code`, `:message` and `:details`
  and per-code constructors, so matching on `%Ordoq.Error{code: :overloaded}`
  works as before.

### Added

- `Ordoq.await_idle/1`, so finite batch applications can wait for queued,
  delayed and running work without closing admission or discarding retries,
  with exhausted or cancelled jobs reported to the caller.
- `Ordoq.drain/1`: bounded shutdown that closes admission and waits for active
  attempts, with a structured timeout result.
- Validated runtime configuration, bounded retries, idempotent queued-job
  locking and running-job cancellation.
- `ARCHITECTURE.md`, included in the generated documentation after the README.
- Dependency-vulnerability, licence, secret-detection, SBOM and provenance
  checks in CI; development-only and not part of the published package.

### Fixed

- The submitting process's context is captured before crossing the queue's
  GenServer boundary, so a job runs with the caller's context rather than the
  queue process's empty one.
- A configured gate that is not a module fails loudly instead of being reported
  as an unavailable dependency.
- Dialyzer passes: `t:Ordoq.Telemetry.Context.t/0` is defined, and `:logger` is
  declared in `extra_applications`.

## Before the public release

Unpublished versions from the private workspace, kept for their history. None
of them was released to Hex; their numbers predate the public 0.1.0.

### 1.0.1 (private) - 2026-06-02

#### Changed

- Updated the `asco_error` runtime dependency constraint from `~> 1.1.3` to `~> 1.1`.

### 1.0.0 (private) - 2026-02-25

#### Changed

- **BREAKING**: Migrated telemetry module to ASCO.Telemetry DSL-based system.
  - `Ordoq.Telemetry.events/0` now auto-generated from `defduration` and `defcounter` macros
  - `Ordoq.Telemetry.metrics/0` exported for automatic Prometheus integration
  - Use `use ASCO.Telemetry` instead of manual `events/0` declarations
- Switched queue telemetry emissions to DSL-generated emitters.

### 0.2.3 (private)

#### Changed

- **BREAKING**: Updated telemetry events structure for task operations to follow consistent pattern
- Refactored telemetry events for appending, locking, unlocking, and timeout operations

### 0.2.2 (private) - 2026-02-12

#### Added

- Added `queue_name` option to task options for better task identification and organization

#### Changed

- Enhanced MixHelper documentation for improved clarity on dependency management functions

### 0.2.1 (private) - 2026-01-15

#### Changed

- Updated `asco_error` dependency from 0.1.0 to 0.2.0
- Updated `asco_erl` dependency from 0.1.0 to 0.1.1
- Updated `asco_telemetry` dependency from 0.1.0 to 0.2.1
- Updated `asco_utils` dependency from 0.1.0 to 0.1.1

### 0.2.0 (private) - 2026-01-15

#### Added

- Added `[:ordoq, :queue, :depth, :value]` last_value metric for queue depth monitoring
- Added telemetry documentation to README.md and USAGE_GUIDE.md

#### Changed

- **BREAKING**: Updated telemetry events from 4-5 atom to consistent 4-atom naming pattern `[:ordoq, :queue, :operation, :metric_type]`
- **BREAKING**: Converted span events to distribution metrics with explicit buckets (10-10000ms)
- **BREAKING**: Replaced `[:ordoq, :queue, :task, :execute, :start/:stop]` with `[:ordoq, :queue, :task_execute, :duration]`
- **BREAKING**: Replaced `[:ordoq, :queue, :task, :timeout]` with `[:ordoq, :queue, :task_timeout, :count]`
- **BREAKING**: Added categorical aggregation tags: `queue_name`, `status`

### 0.1.0 (private) - 2025-01-23

#### Added

##### Core Queue System

- GenServer-based priority queue for asynchronous background task processing
- `Ordoq.append/4` - Add tasks to the queue with configurable options
- `Ordoq.lock/1` - Prevent named tasks from executing
- `Ordoq.unlock/1` - Allow locked tasks to execute again
- Priority-based task scheduling with configurable priority levels (lower = higher priority)
- Delayed task execution with configurable delay times

##### Timeout Management

- Configurable TTR (time-to-run) for task execution timeouts
- Touch function mechanism for extending task timeouts during long-running operations
- Automatic task cleanup on timeout expiration
- Default 60-second timeout with customizable per-task TTR

##### Task Configuration

- Named tasks with support for atoms and tuples as identifiers
- Priority levels (default: 10, critical: 1, high: 5, normal: 10, low: 20)
- Delay scheduling for deferred execution
- Max locks limit to control unlock frequency
- Support for passing arbitrary arguments to task functions

##### Task Locking System

- Lock/unlock mechanism to temporarily prevent task execution
- Named task identification for precise lock control
- Max locks configuration to limit unlock attempts
- Lock state persistence during task lifecycle

##### Telemetry Instrumentation

- `[:ordoq, :task, :start]` - Task execution started
- `[:ordoq, :task, :stop]` - Task execution completed
- `[:ordoq, :task, :exception]` - Task execution failed
- `[:ordoq, :timeout]` - Task timeout occurred
- `[:ordoq, :locked]` - Task execution prevented by lock
- `[:ordoq, :touched]` - Task timeout extended
- `[:ordoq, :queue, :append]` - Task added to queue
- Comprehensive metadata for all telemetry events
- Integration with `:telemetry` for monitoring and observability

##### Error Handling

- `Ordoq.Error` exception module with detailed error information
- Structured error handling for task execution failures
- Timeout error reporting with task context
- Lock violation error tracking

##### Documentation

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

##### Testing

- Comprehensive test suite for queue operations
- Task execution and timeout testing
- Lock/unlock behavior verification
- Priority scheduling validation
- Telemetry event verification

##### CI/CD

- GitLab CI configuration for automated testing
- Documentation generation and deployment
- Code quality checks with Credo
- Type checking with Dialyzer
