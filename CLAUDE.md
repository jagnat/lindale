# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Lindalë is an audio plugin framework written in Odin, targeting VST3 on Mac and Windows. The project is built around a hot-reloading architecture that allows audio processing and UI code to be recompiled and reloaded on the fly without restarting the plugin or DAW.

## Build Commands

### Mac

**Build the full VST3 plugin (with hot-reload support):**
```bash
./build_plugin.command
```
This builds both:
- The hot-reloadable DLL: `out/hot/LindaleHot.dylib`
- The VST3 plugin bundle: `out/Lindale.vst3/`

**Build only the hot-reloadable plugin code:**
```bash
./build_hotload_plugin.command
```
Use this during development to quickly rebuild just the audio/UI logic that gets hot-reloaded.

**Build the standalone test host:**
```bash
./build_test_host.sh
```
Standalone test host (currently not functional after SDL renderer removal).

### Windows

Use the `.bat` equivalents:
- `build_plugin.bat`
- `build_hotload_plugin.bat`
- `build_test_host.bat`

### Setup

Symlink `out/Lindale.vst3` into your system VST3 folder:
- **Mac:** `~/Library/Audio/Plug-Ins/VST3`
- **Windows:** `C:\Program Files\Common Files\VST3`

## Style Guidelines

- Always indent code with tabs, not spaces.
- Remember that this is Odin. Not C, not Golang.
- Prioritize putting more code into existing files over creating new files.
- Do not apply vertical alignment anywhere except in vtable structs.

### Comments

- Never comment what the next line obviously does. No "Create X" before creating X, no "Release textures" before releasing textures.
- Remove comments that just restate variable/field names. If the field is `uniformBuffer`, don't comment "Uniform buffer".
- Keep only non-obvious clarifying info. Good: `// 1MB instance buffer` or `// physical pixels`. Bad: `// Create instance buffer (1MB)`.
- Section headers should be simple: `// Renderer lifecycle`. No decorated boxes or separator lines.
- Use `// TODO:` for incomplete work, not vague phrases like "if needed".
- Minimal punctuation. No periods at end of comments unless multiple sentences.

## Architecture

### Package Structure & Dependency Contracts

The codebase is organized into four packages with strict import rules that enforce the hot-reload boundary:

```
DAW (VST3 Host)
    │
    ▼
src/vst_host/  (package: platform)
    │  Static VST3 layer. Owns Plugin lifetime, hot-reload logic, VST3 interfaces.
    │  Imports: bridge, lindale, platform_specific, thirdparty/vst3
    │
    ├──► src/bridge/  (package: bridge)
    │      Shared types and vtables. The contract between static and hot-loaded code.
    │      Imports: only Odin core. No cross-package imports.
    │
    ├──► src/lindale/  (package: lindale)
    │      Hot-reloadable plugin code: audio, UI, drawing, parameters.
    │      Imports: bridge (as `b`), thirdparty/uFFT. Nothing else in src/.
    │
    └──► src/platform_specific/  (package: platform_specific)
           GPU renderers (Metal/DX11), timers, filesystem utils.
           Imports: bridge only.
```

**Key constraints:**
- `bridge/` is the dependency root — it imports nothing from src/, preventing circular imports
- `lindale/` only imports `bridge/`, never `vst_host/` or `platform_specific/` — this is what makes it safe to hot-reload as a standalone DLL
- `platform_specific/` only imports `bridge/`, keeping renderer implementations isolated
- `vst_host/` is the only package that imports across all others, acting as the composition root

### Hot-Reload System

The hot-reload architecture separates the codebase into:

1. **Static VST3 Layer** (`src/vst_host/vst_layer.odin`): The entry point that implements VST3 interfaces. This stays loaded in the DAW and cannot be modified without restarting.

2. **Hot-Reloadable Plugin Code** (`src/lindale/`): The actual audio processing, UI, and drawing logic. When `HOT_DLL=true`, this compiles to a separate dynamic library that can be reloaded.

The hot-reload system (`src/vst_host/hotloader.odin`) works by:
- Watching `out/hot/LindaleHot.dylib` for modifications
- When changed, copying it to a numbered version (e.g., `LindaleHot001.dylib`)
- Unloading the old DLL and loading the new one
- Using atomic operations to swap the function pointers in `PluginApi`

**Key files:**
- `src/vst_host/hotloader.odin`: Hot-reload thread and DLL management
- `src/lindale/plugin.odin`: Core plugin state and `PluginApi` structure with `draw`, `process_audio`, `view_attached`, `view_removed`, `view_resized`, and `query_parameter_layout` procedures

### Plugin Architecture

The plugin is split into two VST3 components:

1. **LindaleProcessor** (`src/vst_host/vst_layer.odin`): Audio processing component
   - Implements `IComponent` and `IAudioProcessor` interfaces
   - Runs on the audio thread
   - Manages parameter changes and audio buffer routing
   - Owns `Plugin` instance with audio processing state

2. **LindaleController** (`src/vst_host/vst_layer.odin`): UI/controller component
   - Implements `IEditController` and `IEditController2` interfaces
   - Runs on the UI thread
   - Manages parameter state and the plugin view
   - Owns `Plugin` instance and `PlatformApi` vtable

3. **LindaleView** (`src/vst_host/vst_layer.odin`): Platform view implementation
   - Implements `IPlugView` interface
   - Creates platform-specific renderer in `lv_attached`
   - Runs a timer to drive the render loop at 30ms intervals
   - Timer calls `plugin_draw` which uses the platform vtable

### Plugin State

The `Plugin` struct (`src/lindale/plugin.odin`) is allocated by the static VST layer and survives hot-reloads. It holds a pointer to `PluginInstance` (defined in `src/bridge/platform_api.odin`), which carries the platform-provided state.

**PluginInstance (in bridge, survives hot-reload):**
- `params`: Pointer to `ParamValues`
- `platform`: Pointer to `PlatformApi` vtable
- `renderer`: Opaque `Renderer` handle
- `font_atlas`: Persistent `TextureHandle`

**Plugin fields (hot-loaded, reset on reload):**
- `draw`: Drawing context with batching system
- `ui`: UI widget state
- `audioProcessor`: Audio processing state

Hot-loaded fields are zeroed by static layer on DLL unload, then reallocated by `plugin_init` after new DLL loads. The `PluginInstance` pointer and its contents remain valid throughout.

### Bridge Package

`src/bridge/` defines the shared contract between static and hot-loaded code:

- `platform_api.odin`: `PlatformApi` vtable, `PluginInstance`, rendering types (`RectInstance`, `TextureHandle`, `DrawCommand`, `RendererSize`), input types (`MouseState`), math types (`Vec2f`, `Vec4f`, `ColorU8`)
- `host_api.odin`: `HostApi` vtable for parameter edit callbacks from plugin to host
- `parameters.odin`: `ParamDescriptor`, `ParamValues`, `ParamUnit`, conversion utilities (`param_to_normalized`, `normalized_to_param`, `param_format_value`)

### Parameter System

Parameters are split across two packages:

**Bridge layer** (`src/bridge/parameters.odin`): Shared types used by both static and hot-loaded code.
- `ParamDescriptor`: Metadata (name, range, units, defaults)
- `ParamValues`: Runtime normalized parameter values (0-1)
- `ParamUnit`: Decibel, Hertz, Percentage, Normalized
- Conversion utilities between normalized and plain values

**Plugin layer** (`src/lindale/parameters.odin`): Parameter definitions owned by hot-loaded code.
- `param_table`: Array of `ParamDescriptor` entries
- `PARAM_GAIN`, `PARAM_MIX`, `PARAM_FREQ`: Parameter index constants
- `param_index`: Map from `ParamDescriptor` to index

The VST3 layer converts between VST3 parameter changes and the plugin's internal parameter system.

### Audio Processing

Audio processing happens in `plugin_process_audio` (`src/lindale/plugin.odin`):
- Receives audio buffers as `AudioBufferGroup` with either f32 or f64 samples
- Parameter changes are provided with sample-accurate offsets
- Currently implements a simple square wave generator for demonstration

To modify audio processing behavior:
1. Edit `plugin_process_audio` in `src/lindale/plugin.odin`
2. Run `./build_hotload_plugin.command` to rebuild
3. The changes will hot-reload automatically while the plugin is running

### Rendering Architecture

SDF rounded rectangle renderer with instanced rendering. Supports borders, corner radii, and textures.

**Platform API Vtable** (`src/bridge/platform_api.odin`):
The `PlatformApi` struct contains all renderer function pointers. Static layer populates this vtable with platform-specific implementations and passes it to hot-loaded code via `PluginInstance`. This allows renderer calls from lindale without linking to platform-specific code.

**Draw System** (`src/lindale/draw.odin`):
High-level drawing API that batches rectangles and text into draw calls. `draw_submit` flattens batches and issues `DrawCommand`s via the platform vtable. Font rendering uses fontstash with a persistent texture atlas.

**Shared types** (`src/bridge/platform_api.odin`):
- `RectInstance`: 56-byte per-instance data (pos, uv, color, border, corner radius)
- `TextureHandle`: Opaque handle to GPU texture
- `DrawCommand`: Batch of instances with texture and scissor
- `RendererSize`: Logical size (points for UI), physical size (pixels), scale factor
- `PlatformApi`: Vtable with renderer function pointers

**Renderer interface** (`src/platform_specific/view_platform.odin`):
Documents the renderer procedures each platform must implement. See file for full list.

**Platform implementations**:
- `src/platform_specific/view_platform_darwin.odin`: Metal renderer for macOS
- `src/platform_specific/view_platform_windows.odin`: DirectX 11 renderer for Windows

**Shaders**: `src/shaders/shader.metal` and `src/shaders/shader.hlsl` - SDF rounded rect with border and texture support. Loaded at compile time via `#load()`.

UI code works in logical coordinates (points). The renderer handles DPI scaling internally.

### UI Layout System

The UI (`src/lindale/ui.odin`) uses a tree-based layout with three sizing modes, similar to Clay/Flexbox:

- **FIXED**: Explicit size. `{type = .FIXED, value = 200}`
- **FIT**: Shrink-wrap children (plus padding/gaps), clamped to [min, max]. `{type = .FIT, min = 100, max = 500}`
- **GROW**: Expand to fill parent's available space, clamped to [min, max]. `{type = .GROW, min = 100, max = 500}`

FIXED is equivalent to FIT where min == max. Size flows **up** for FIT (from children) and **down** for GROW (from parent). GROW children inside a FIT parent contribute their `min` to the FIT calculation.

Each `Component` has independent `sizingHoriz` and `sizingVert` (`AxisSizing`), a `direction` (HORIZONTAL/VERTICAL) for child layout, `child_gaps`, and per-axis `padding`.

**Sizing is multi-pass:**
1. Bottom-up: `ui_close_component` resolves FIXED and FIT sizes as components are closed
2. Top-down: `ui_size_grow_components` distributes remaining space to GROW children (both main-axis and cross-axis)
3. `ui_position_components` places children along the parent's layout direction

Panels (`ui_panel`) accept sizing overrides. Leaf widgets (buttons, sliders) set their own sizing in their constructors.

### Platform-Specific Code

- `src/bridge/`: Shared types and vtables between all packages (avoids circular imports)
- `src/platform_specific/view_platform.odin`: Renderer interface documentation
- `src/platform_specific/view_platform_darwin.odin`: macOS Metal implementation
- `src/platform_specific/view_platform_windows.odin`: Windows DirectX 11 implementation
- `src/platform_specific/timer*.odin`: High-resolution timer for render loop

## Development Workflow

1. **Initial setup:**
   ```bash
   ./build_plugin.command  # Build full VST3 plugin
   ```

2. **During development (iterating on audio/UI code):**
   ```bash
   ./build_hotload_plugin.command  # Quick rebuild of hot-reloadable code
   ```
   Changes automatically reload in the running plugin.

3. **Changes to VST3 layer require full rebuild:**
   ```bash
   ./build_plugin.command  # Rebuild entire plugin
   ```
   Must restart the DAW after this.

## Important Implementation Details

- **HOT_DLL Config:** When `HOT_DLL=true`, the plugin exports a `GetPluginApi()` function that returns function pointers for hot-reloadable code.
- **Platform API Initialization:** The static layer creates the renderer, populates `PlatformApi` vtable with function pointers, creates the font atlas texture, then calls `plugin_init`. See `src/vst_host/vst_layer.odin:lv_attached` for initialization flow.
- **Hot-Reload Lifecycle:** Static layer zeros `plugin.draw` and `plugin.ui` fields after DLL unload. After loading new DLL, calls `plugin_init` which reallocates these fields. `PluginInstance` (holding `platform`, `renderer`, `font_atlas`) remains valid throughout.
- **Container_of Pattern:** The VST3 layer uses a `container_of` pattern to convert from VST3 interface pointers back to the containing structs.
- **Reference Counting:** Each VST3 component manages its own reference count. When count reaches 0, the component is freed.
- **Context Management:** Each component stores its own Odin context with appropriate loggers for thread-safe logging.
- **Code Signing (Mac):** The build scripts use `codesign --force --sign -` for ad-hoc code signing required by macOS.

## Current Limitations & TODOs

- Wire up `on_hot_load` and `on_hot_unload` in PluginApi (declared but not exported via `GetPluginApi` or implemented)
- Support CLAP format in addition to VST3
