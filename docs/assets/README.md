# ObservLib Logo Assets

## Logo Design

The ObservLib logo combines Elixir's visual language with observability symbolism:

**Elixir Elements:**
- Iconic droplet/drop shape (from Elixir logo)
- Faceted gem-like appearance
- Purple gradient (#A074C4 → #6B46C1 → #4E2A84)
- Characteristic highlight

**Observability Elements:**
- Central eye (observation/monitoring)
- Telemetry signal waves radiating outward
- Data/metric points (telemetry data)
- Trace line through the center

## Files

- `logo.svg` - Primary vector logo (256×256px viewBox)
- `logo.png.txt` - Removed (replaced with actual logo)

## Usage

### In Documentation

The logo is automatically included in HexDocs via the `docs/0` configuration in `mix.exs`:

```elixir
logo: "docs/assets/logo.png"
```

For mdBook, the logo can be referenced in markdown:

```markdown
![ObservLib](../assets/logo.svg)
```

### Converting to PNG

To create PNG versions for various uses:

```bash
# Requires ImageMagick
convert logo.svg -resize 256x256 logo.png       # Full size
convert logo.svg -resize 128x128 logo-128.png   # Medium
convert logo.svg -resize 64x64 favicon.png      # Favicon
convert logo.svg -resize 32x32 logo-32.png      # Small icon
```

Or using Node.js/sharp:

```bash
npm install -g sharp-cli
sharp -i logo.svg -o logo.png --resize 256
```

### For Hex.pm Package

Place `logo.png` (256×256px) in the repository root and reference in `mix.exs`:

```elixir
def project do
  [
    # ...
    docs: [
      logo: "docs/assets/logo.png"
    ]
  ]
end
```

## Color Palette

Primary colors from the logo:

| Color | Hex | Usage |
|-------|-----|-------|
| Light Purple | `#A074C4` | Highlights, top gradient |
| Elixir Purple | `#6B46C1` | Primary brand color |
| Dark Purple | `#4E2A84` | Shadows, accents |
| Deep Purple | `#2D1B4E` | Eye iris |
| Darkest | `#0F0519` | Pupil |

## License

The ObservLib logo is part of the ObservLib project and is licensed under the MIT License.
