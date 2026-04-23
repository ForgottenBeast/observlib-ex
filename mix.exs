defmodule ObservLib.MixProject do
  use Mix.Project

  def project do
    [
      app: :observlib,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Documentation
      name: "ObservLib",
      description: "OpenTelemetry observability library for Elixir",
      source_url: "https://github.com/yourorg/observlib",
      homepage_url: "https://observlib.dev",
      docs: docs(),
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ObservLib.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Runtime dependencies
      {:opentelemetry_api, "~> 1.2"},
      {:opentelemetry, "~> 1.3"},
      {:opentelemetry_exporter, "~> 1.6"},
      {:opentelemetry_telemetry, "~> 1.0"},
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.4"},

      # Dev/Test dependencies
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 0.6", only: :test}
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "docs/assets/logo.svg",
      extras: extras(),
      groups_for_extras: groups_for_extras(),
      groups_for_modules: groups_for_modules(),
      before_closing_body_tag: &before_closing_body_tag/1,
      assets: "docs/assets",
      formatters: ["html"],
      source_ref: "v#{@version}",
      api_reference: true
    ]
  end

  defp extras do
    [
      "README.md",
      "guides/getting-started.md",
      "guides/configuration.md",
      "guides/custom-instrumentation.md",
      "CHANGELOG.md": [title: "Changelog"],
      "LICENSE": [title: "License"]
    ]
  end

  defp groups_for_extras do
    [
      "Guides": ~r/guides\/.*/
    ]
  end

  defp groups_for_modules do
    [
      "Core API": [
        ObservLib,
        ObservLib.Application,
        ObservLib.Config
      ],
      "Traces": [
        ObservLib.Traces,
        ObservLib.Traces.Provider,
        ObservLib.Traces.Supervisor,
        ObservLib.Traces.PyroscopeProcessor,
        ObservLib.Traced
      ],
      "Metrics": [
        ObservLib.Metrics,
        ObservLib.Metrics.MeterProvider,
        ObservLib.Metrics.Supervisor,
        ObservLib.Metrics.PrometheusReader,
        ObservLib.Metrics.OtlpMetricsExporter
      ],
      "Logs": [
        ObservLib.Logs,
        ObservLib.Logs.Backend,
        ObservLib.Logs.Supervisor,
        ObservLib.Logs.OtlpLogsExporter
      ],
      "Telemetry": [
        ObservLib.Telemetry
      ],
      "Pyroscope": [
        ObservLib.Pyroscope.Client
      ]
    ]
  end

  defp before_closing_body_tag(:html) do
    """
    <script>
      // Add link to mdBook from HexDocs
      document.addEventListener('DOMContentLoaded', function() {
        const sidebar = document.querySelector('.sidebar');
        if (sidebar) {
          const bookLink = document.createElement('div');
          bookLink.className = 'sidebar-section';
          bookLink.innerHTML = '<h3><a href="/book/" target="_blank">📚 Usage Guide (mdBook)</a></h3>';
          sidebar.insertBefore(bookLink, sidebar.firstChild);
        }
      });
    </script>
    <style>
      .sidebar-section { padding: 1rem; border-bottom: 1px solid #ddd; }
      .sidebar-section a { color: #6b46c1; font-weight: bold; }
    </style>
    """
  end

  defp before_closing_body_tag(_), do: ""

  defp package do
    [
      name: "observlib",
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/yourorg/observlib",
        "Documentation" => "https://hexdocs.pm/observlib",
        "Usage Guide" => "https://observlib.dev/book/"
      },
      maintainers: ["Your Name"],
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end
end
