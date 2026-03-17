# StudioLight Integration for Rethinking Voxels

This is a patched version of Rethinking Voxels that includes support for **StudioLight** — a dynamic studio lighting system for Minecraft implemented as a Fabric mod.

## What is StudioLight?

StudioLight is a Minecraft Fabric mod that adds dynamic, user-controlled lighting through an in-game command system. It provides:

- **Point lights** — Omni-directional light with falloff
- **Spot lights** — Cone-shaped lights with hotspot and penumbra
- **Area lights** — Rectangular emissive panels with barn doors
- **Real-time control** — Adjust intensity, color, position, rotation via commands
- **Gizmo visualization** — See light positions and properties in-game
- **Shader integration** — Works with Iris-compatible shader packs (like this one)

## Integration Details

### How It Works

1. **StudioLight mod** (runs on client) manages light entities and communicates with shaders via SSBO (Shader Storage Buffer Object)
2. **Shader pack** (this one) reads the SSBO and evaluates studio lights in the deferred rendering pass
3. **Real-time updates** happen each frame without needing to reload shaders

### Modified Files

- `shaders/lib/lighting/studiolight.glsl` — SSBO struct definition + light evaluation functions
- `shaders/program/deferred1.glsl` — Integration hook after main lighting

### Shader Configuration

The integration is guarded by `#ifdef STUDIOLIGHT_SUPPORT` - if the mod isn't loaded, the code simply doesn't execute (zero overhead).

## Using StudioLight

### Installation

1. Install **Fabric Loader** and **Fabric API**
2. Install the **StudioLight** mod jar in `mods/` folder
3. Use this shader pack (rethinking-voxel-patched) with Iris Shaders

### Commands

All commands are client-side and require no permissions:

```
/studiolight spawn <type> [<pos>] [<name>]
  type: point | spot | area | emission
  → Creates a new light, optionally at position, with optional name

/studiolight select <id>
/studiolight deselect
  → Select/deselect a light for editing

/studiolight set <id> param <key> <value>
  → Set light parameters:
    intensity (0.0–1.0)
    color (hex RRGGBB, e.g. FF6B00)
    kelvin (1000–12000 K color temperature)
    radius / range / width / height (geometry)
    cone_angle / inner_angle / shape (spot-specific)
    barn_top / barn_bottom / barn_left / barn_right (area-specific)

/studiolight move <id> <pos>
  → Move a light to new position

/studiolight list
  → Show all lights

/studiolight clear
  → Remove all lights
```

### Example Workflow

```
# Create a key light (main lighting)
/studiolight spawn spot ~5 ~2 ~0 key_light

# Create a fill light (side lighting)
/studiolight spawn spot ~-5 ~2 ~0 fill_light

# Select the key light and adjust it
/studiolight select key_light
/studiolight set key_light param intensity 0.8
/studiolight set key_light param color FF9500  # Warm orange
/studiolight set key_light param cone_angle 30
```

## Technical Details

### Shader SSBO Layout

```glsl
struct SL_Light {
    vec4 positionAndType;    // xyz = camera-relative world pos · w = type (0=point, 1=spot, 2=area)
    vec4 colorAndIntensity;  // rgb = linear color · a = intensity [0,1]
    vec4 geometry0;          // type-specific: (radius/coneAngle/width, ...)
    vec4 geometry1;          // type-specific overflow
    vec4 direction;          // xyz = normalised direction · w = unused
}

layout(std430, binding = 7) readonly buffer SL_LightData {
    int      sl_count;       // Number of active lights
    int      _pad0, _pad1, _pad2;
    SL_Light sl_lights[256]; // Up to 256 concurrent lights
}
```

### Camera-Relative Coordinates

Positions are stored relative to the camera (not world coordinates) to maintain float precision at any world location.

### Light Evaluation

The shader evaluates each light in `sl_evaluate()`:

1. Computes attenuation (distance falloff)
2. Applies cone mask (for spot lights)
3. Evaluates barn door clipping (for area lights)
4. Multiplies by N·L (surface normal dot light direction)
5. Scales by light color and intensity
6. Adds contribution to final fragment color

## Compatibility

- **Minecraft versions**: 1.21.1, 1.21.4, 1.21.8, 1.21.11
- **Loader**: Fabric 0.18.4+
- **Shader pack basis**: Complementary Reimagined (rethinking-voxels fork)
- **Iris Shaders**: 1.8.8+

## Performance

- **Zero cost** when mod not loaded (guarded by `#ifdef`)
- **~0.5ms per light** on typical hardware (Nvidia RTX 2070 equivalent)
- Supports up to **256 concurrent lights** (configurable in mod)

## License

- **Rethinking Voxels shader pack**: Original license by rethinking-voxels author
- **StudioLight integration code**: Part of StudioLight mod (Fabric mod license)
- **Complementary base**: EminGT's Complementary Reimagined (custom license v1.6)

## Troubleshooting

**Lights not appearing in shader:**
- Ensure StudioLight mod is installed
- Check that `STUDIOLIGHT_SUPPORT` is defined (should be automatic if mod is loaded)
- Verify lights exist: `/studiolight list`

**Shader compilation errors:**
- Update Iris Shaders to 1.8.8+
- Check that the GPU supports OpenGL 4.3+ (SSBO required)

**Performance issues:**
- Reduce number of active lights
- Use point lights instead of area lights (simpler computation)
- Check monitor's G-Sync/FreeSync is enabled

## Development

To develop further:

1. See `studiolight.glsl` for light evaluation functions
2. See `deferred1.glsl` line ~500 for integration hook
3. Modify attenuation formulas in `sl_windowed_atten()`
4. Adjust hotspot/penumbra in `sl_spot_cone()`

---

**Version**: 1.0.0
**Last Updated**: 2026-03-17
**StudioLight Mod**: https://github.com/stdpi/studiolight
