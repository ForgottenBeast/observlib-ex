# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-03-27

### Added

#### Core API
- Main `ObservLib` facade module with convenience functions
- `ObservLib.Application` with proper OTP supervision tree
- `ObservLib.Config` GenServer for runtime configuration management

#### Distributed Tracing
- `ObservLib.Traces` module for span creation and management
- `ObservLib.Traces.Provider` GenServer with ETS-backed span tracking
- `ObservLib.Traces.Supervisor` with one-for-one strategy
- `ObservLib.Traces.PyroscopeProcessor` for profile correlation
- Automatic parent-child span relationships
- Span attribute and event support
- Exception recording

#### Metrics Collection
- `ObservLib.Metrics` module for metric recording
- `ObservLib.Metrics.MeterProvider` with ETS-backed storage
- `ObservLib.Metrics.Supervisor` with rest-for-one strategy
- Counter, gauge, histogram, and up-down counter support
- `ObservLib.Metrics.PrometheusReader` with native TCP server (port 9568)
- `ObservLib.Metrics.OtlpMetricsExporter` for OTLP export
- Atomic counter operations via `:ets.update_counter/3`

#### Structured Logging
- `ObservLib.Logs` module for structured logging
- `ObservLib.Logs.Backend` Erlang `:logger` handler integration
- `ObservLib.Logs.Supervisor` with one-for-one strategy
- `ObservLib.Logs.OtlpLogsExporter` for OTLP export
- Automatic trace context injection (trace_id, span_id)
- Log level support (debug, info, warn, error)
- Context management with `with_context/2`

#### Telemetry Integration
- `ObservLib.Telemetry` module for Erlang `:telemetry` bridge
- Automatic event handler attachment
- Phoenix and Ecto instrumentation support
- Custom handler function support
- Duration extraction from telemetry measurements

#### Compile-time Instrumentation
- `ObservLib.Traced` macro for zero-overhead instrumentation
- `@traced` attribute for automatic span creation
- AST manipulation with `@on_definition` and `@before_compile`
- Configurable span attributes per function
- Support for guard clauses and multi-clause functions

#### Continuous Profiling
- `ObservLib.Pyroscope.Client` GenServer
- Periodic profile sampling and upload
- Span-profile correlation
- Configurable sampling interval

#### Documentation
- Comprehensive guides (Getting Started, Configuration, Custom Instrumentation)
- API documentation with ExDoc
- Runnable examples (Basic Usage, Phoenix, Ecto, Custom Metrics)
- mdBook-based usage guide
- Complete README with architecture diagram

#### Testing
- 25 test suites with comprehensive coverage
- Integration tests with mock OTLP server
- End-to-end pipeline tests
- Prometheus endpoint tests
- OTLP export compliance tests

### Technical Details

- **ETS Tables**: All cross-process data stored in ETS (not process dictionary)
- **Supervision**: Proper OTP supervision trees with fault isolation
- **Performance**: <1μs overhead for counter operations, ~10μs for span creation
- **Concurrency**: Lock-free reads, atomic counter updates
- **Error Handling**: Graceful degradation, no crashes on export failures
- **OpenTelemetry**: Full OTLP/HTTP compliance for traces, metrics, and logs

### Dependencies

#### Runtime
- `opentelemetry_api ~> 1.2`
- `opentelemetry ~> 1.3`
- `opentelemetry_exporter ~> 1.6`
- `opentelemetry_telemetry ~> 1.0`
- `telemetry ~> 1.2`
- `telemetry_metrics ~> 0.6`
- `telemetry_poller ~> 1.0`
- `jason ~> 1.4`
- `req ~> 0.4`

#### Development/Test
- `ex_doc ~> 0.30`
- `dialyxir ~> 1.4`
- `credo ~> 1.7`
- `stream_data ~> 0.6`

[Unreleased]: https://github.com/yourorg/observlib/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/yourorg/observlib/releases/tag/v0.1.0
