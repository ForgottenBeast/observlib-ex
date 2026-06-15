# Open Questions

## Phase 2: Telemetry Foundation - 2026-03-27

- [ ] Should `attach/2` be idempotent (silently succeed if already attached) or return `{:error, :already_attached}`? -- The `:telemetry.attach/4` function returns `{:error, :already_exists}` by default. The Logs module pattern treats duplicates as success. Need to decide which pattern to follow for consistency.

- [ ] Should `handle_event/4` create both a span AND record a metric (histogram for duration), or only create a span? -- Creating both would give fuller observability but may cause double-counting if `ObservLib.Metrics` is also recording the same event. Need to decide on deduplication strategy.

- [ ] What default telemetry event prefixes (if any) should be auto-attached during `setup/0`? -- Options: none (explicit opt-in only), common BEAM VM events via `:telemetry_poller`, or configurable list. The current plan defaults to empty list, requiring explicit configuration.

- [ ] Should the module support `:telemetry` start/stop event pair convention (e.g., `[:phoenix, :endpoint, :start]` / `[:phoenix, :endpoint, :stop]`) with automatic span lifecycle, or treat each event independently? -- The `:opentelemetry_telemetry` library handles this pattern natively. If we delegate to it, we get this for free. If we build our own handler, we need to decide.

## Phases 3-9 Implementation - 2026-03-27

### Phase 3: Traces

- [ ] Should Traces.Provider ETS table be `:public` (any process can read) or `:protected` (only owner reads)? -- `:public` enables fast reads from any process without GenServer bottleneck, but loses write control. Recommendation: `:public` for reads, writes go through GenServer cast for safety.

- [ ] What is the stale span cleanup threshold? -- Spans that are never ended will leak in ETS. Need a configurable max span age (e.g., 5 minutes). This is a safety net, not a normal code path.

### Phase 4: Metrics

- [ ] OtlpMetricsExporter currently attaches to `[:observlib, :metrics]` but `ObservLib.Metrics.counter/3` emits events like `[:http, :requests]` (from name normalization). These never match. -- Fix options: (A) change Metrics to also emit on a canonical prefix, (B) attach exporter to wildcard, (C) bypass telemetry entirely for ETS writes. Recommendation: (C) MeterProvider writes to ETS directly, telemetry events remain for user-space consumption only.

- [ ] Should PrometheusReader use `:gen_tcp` directly or add a Plug/Bandit dependency? -- `:gen_tcp` has no dependencies but requires manual HTTP parsing. Bandit is lightweight but adds a dependency. The project constraint says no new dependencies, so `:gen_tcp` is the answer unless relaxed.

- [ ] What Prometheus port should be the default? -- Common choices: 9090 (conflicts with Prometheus itself), 4000 (conflicts with Phoenix), 9568 (Prometheus Elixir convention). Recommendation: 9568.

### Phase 5: Logs

- [ ] Should Logs.Backend use the Logger backend behaviour (`Logger.Backend`) or the newer Erlang `:logger` handler pattern? -- Logger.Backend is deprecated in Elixir 1.15+ in favor of `:logger` handlers. Since the project targets `~> 1.14`, both are available. The existing code already uses `:logger.add_handler` in `ObservLib.Logs.attach_logger_handler/0`. Recommendation: use `:logger` handler for forward compatibility.

- [ ] Should the Logs.Backend forward ALL Logger output or only logs emitted through `ObservLib.Logs.*`? -- Forwarding all Logger output captures library logs (Ecto, Phoenix) which is valuable. But it can be very noisy. Recommendation: configurable filter, default to all logs at configured level.

### Phase 6: Traced Macro

- [ ] Should `@traced` support async functions (Task.async, GenServer calls)? -- Span context propagation across process boundaries requires explicit context passing. The macro could inject context into spawned processes, but this adds complexity. Recommendation: Phase 1 of the macro handles synchronous functions only; async support is a follow-up.

- [ ] How should `@traced` interact with multiple function clauses that have different patterns? -- Options: (A) wrap each clause individually, (B) generate a wrapper function that delegates. Option B is cleaner but changes the function's arity visibility. Recommendation: (A) wrap each clause.

### Phase 7: Pyroscope

- [ ] What stack sampling method to use? -- `:erlang.process_info(pid, :current_stacktrace)` is simple but only captures the calling process. For system-wide profiling, we need `:erlang.processes()` iteration which can be expensive. Recommendation: configurable process list, default to all processes but with a sample cap.

- [ ] What profiling data format does Pyroscope expect? -- Pyroscope's ingest API expects pprof format or collapsed stack format. Collapsed stack format (`function_a;function_b;function_c count\n`) is simpler to generate from Erlang stacktraces. Recommendation: collapsed stack format.

### Phase 8: Integration Tests

- [ ] Should integration tests require a running OTLP collector or use a mock? -- The plan uses a mock TCP server, which is self-contained. But testing against a real collector (via Docker in CI) catches real protocol issues. Recommendation: mock for local tests, optional Docker-based collector test via `@tag :integration`.

## Deep Security Audit - 2026-04-23

- [ ] Does the SSRF test at `url_validation_test.exs:130` (`http://169.254.169.254`) actually fail or pass? The URL has a valid scheme and host, so `validate_endpoint_url/1` should return `{:ok, url}`, but the test expects rejection. This needs to be run to confirm. -- Determines if existing SSRF coverage is overstated.
- [ ] Is `test/security/README.md` and `test/security/COVERAGE.md` referenced in SECURITY.md actually present? -- Determines if documentation references are broken.
- [ ] What is the actual count of security test cases? Threat model claims "89+" but this needs verification by running `mix test --only security --trace`. -- Determines if coverage claims are accurate.
- [ ] Are `finch` and `tls_certificate_check` transitive deps of `req`, or were they once explicit deps that got removed? The task context mentions them but `mix.exs` does not list them. -- Determines supply chain pinning posture.
- [ ] Should the Prometheus Basic Auth timing vulnerability (NEW-003) be rated High or Medium? Depends on whether users typically expose the Prometheus port to untrusted networks. -- Determines remediation priority.
- [ ] Is there a CI pipeline that runs `mix hex.audit` or `mix deps.audit`? If not, the dependency CVE check is a point-in-time snapshot. -- Determines if supply chain monitoring is continuous.
