# Installation

## Requirements

- Elixir 1.14 or later
- Erlang/OTP 25 or later

## Add Dependency

Add `observlib` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:observlib, "~> 0.1.0"}
  ]
end
```

## Fetch Dependencies

```bash
mix deps.get
```

ObservLib will start automatically with your application as it's configured as a standard OTP application.

## Verify Installation

Check that ObservLib is available:

```elixir
iex> ObservLib.service_name()
nil  # Returns nil until configured
```

## Optional: Development Tools

For the best development experience, also add:

```elixir
def deps do
  [
    {:observlib, "~> 0.1.0"},

    # Optional: Better logging
    {:logger_json, "~> 5.1", only: [:dev, :prod]},

    # Optional: Local OTLP testing
    {:req, "~> 0.4", only: :test}
  ]
end
```

## Next Steps

Continue to [Quick Start](quick-start.md) to configure ObservLib for your application.
