# ObservLib Documentation

This directory contains the source files for ObservLib's unified documentation system.

## Documentation Structure

ObservLib uses two complementary documentation systems:

### 1. HexDocs (API Reference)

**Location:** Generated from inline module documentation
**Output:** `doc/` directory
**URL:** https://hexdocs.pm/observlib

HexDocs provides detailed API reference documentation generated from `@moduledoc` and `@doc` attributes in the source code.

**Generate locally:**
```bash
mix docs
open doc/index.html
```

**Features:**
- Module, function, and type documentation
- Cross-references between modules
- Search functionality
- Includes guides from `guides/` directory

### 2. mdBook (Usage Guide)

**Location:** `docs/book/` directory
**Output:** `doc/book/` directory
**URL:** https://observlib.dev/book/

mdBook provides narrative documentation, tutorials, and usage guides.

**Generate locally:**
```bash
mdbook build
open doc/book/index.html
```

**Install mdBook:**
```bash
# macOS
brew install mdbook

# Cargo
cargo install mdbook

# Download binary
# https://github.com/rust-lang/mdBook/releases
```

**Features:**
- Getting started guides
- Conceptual overviews
- Integration examples
- Deployment guides
- Searchable content

## Directory Structure

```
docs/
├── README.md              # This file
├── book/                  # mdBook source files
│   ├── SUMMARY.md        # Table of contents
│   ├── introduction.md   # Landing page
│   ├── getting-started/  # Installation and quick start
│   ├── concepts/         # Architecture and concepts
│   ├── guides/           # Usage guides
│   ├── integrations/     # Framework integrations
│   ├── deployment/       # Production deployment
│   └── appendix/         # Reference material
└── assets/               # Images and static files
    └── logo.png          # ObservLib logo

guides/                   # Included in both HexDocs and mdBook
├── getting-started.md
├── configuration.md
└── custom-instrumentation.md

examples/                 # Runnable examples
├── basic_usage.exs
├── phoenix_integration.exs
└── ecto_integration.exs
```

## Building Documentation

### Complete Build (Both Systems)

```bash
make docs
```

This generates:
- `doc/` - HexDocs API reference
- `doc/book/` - mdBook usage guide

### HexDocs Only

```bash
mix docs
```

### mdBook Only

```bash
mdbook build
```

### Watch Mode (mdBook)

Auto-rebuild on file changes:

```bash
mdbook serve
# Opens http://localhost:3000
```

## Writing Documentation

### For HexDocs (API Reference)

Add documentation to modules:

```elixir
defmodule ObservLib.NewModule do
  @moduledoc """
  Brief description of what this module does.

  ## Examples

      iex> ObservLib.NewModule.function()
      :ok

  """

  @doc """
  Function documentation.

  ## Parameters

    * `param` - Description

  ## Returns

  Description of return value.
  """
  def function(param) do
    # ...
  end
end
```

### For mdBook (Usage Guide)

1. Create a new `.md` file in `docs/book/`
2. Add it to `docs/book/SUMMARY.md`
3. Write in Markdown with code examples

Example:

```markdown
# Chapter Title

Introduction paragraph.

## Section

Content with `inline code`.

```elixir
# Code block
ObservLib.traced("example", fn ->
  :ok
end)
\```

## Next Steps

Links to related content.
```

## Cross-Linking

### From HexDocs to mdBook

```elixir
@moduledoc """
For usage examples, see the [Usage Guide](https://observlib.dev/book/).
"""
```

### From mdBook to HexDocs

```markdown
For API details, see [ObservLib.Traces](https://hexdocs.pm/observlib/ObservLib.Traces.html).
```

## Documentation Guidelines

### Style Guide

- **Active voice**: "Use ObservLib.traced to..." not "ObservLib.traced can be used to..."
- **Code examples**: Include working code samples
- **Context**: Explain *why* not just *how*
- **Links**: Cross-reference related documentation
- **Completeness**: Include error cases and edge cases

### Code Examples

- Must be valid Elixir code
- Include necessary imports/aliases
- Show realistic use cases
- Include comments for clarity

### Testing Examples

Doctests in HexDocs are automatically tested:

```elixir
@doc """
## Examples

    iex> ObservLib.service_name()
    "my_service"

"""
```

Run with:
```bash
mix test --only doctest
```

## Publishing

### HexDocs

Published automatically when releasing to Hex:

```bash
mix hex.publish
```

### mdBook

Deploy to GitHub Pages, Netlify, or similar:

```bash
mdbook build
# Upload doc/book/ to hosting
```

## Contributing

When adding features:

1. ✅ Add module documentation (@moduledoc, @doc)
2. ✅ Add examples to doctests
3. ✅ Create/update mdBook guide if needed
4. ✅ Add to CHANGELOG.md
5. ✅ Cross-link between HexDocs and mdBook

## Maintenance

### Update Version Numbers

When releasing a new version, update:
- `mix.exs` - project version
- `CHANGELOG.md` - add release notes
- `book.toml` - if book version needs updating

### Generate Stubs

Generate stub pages for new mdBook chapters:

```bash
mix run scripts/generate_book_stubs.exs
```

## Help

- **HexDocs:** https://hexdocs.pm/ex_doc/
- **mdBook:** https://rust-lang.github.io/mdBook/
- **Markdown:** https://www.markdownguide.org/
