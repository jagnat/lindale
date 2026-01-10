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
Builds and runs a standalone SDL3 window for testing rendering without loading the VST3 plugin.

### Windows

Use the `.bat` equivalents:
- `build_plugin.bat`
- `build_hotload_plugin.bat`
- `build_test_host.bat`

### Setup

1. Symlink `out/Lindale.vst3` into your system VST3 folder:
   - **Mac:** `~/Library/Audio/Plug-Ins/VST3`
   - **Windows:** `C:\Program Files\Common Files\VST3`

2. Optionally symlink `out/hot` into the SDL3 preferences folder for hot-reload development:
   - **Mac:** `~/Library/Application Support/user/Lindale`
   - **Windows:** `%APPDATA%\user\Lindale`

## Style Guidelines

- Always indent code with tabs, not spaces.
- Remember that this is Odin. Not C, not Golang.
- Prioritize putting more code into existing files over creating new files.
- Do not over-comment code files. Keep comments terse and simple. Absolutely no use of big spacer comments. Comments should have minimal punctuation.

## Architecture

### Hot-Reload System

The hot-reload architecture is the central design pattern. It separates the codebase into:

1. **Static VST3 Layer** (`src/vst_layer.odin`): The entry point that implements VST3 interfaces. This stays loaded in the DAW and cannot be modified without restarting.

2. **Hot-Reloadable Plugin Code** (`src/lindale/`): The actual audio processing, UI, and drawing logic. When `HOT_DLL=true`, this compiles to a separate dynamic library that can be reloaded.

The hot-reload system (`src/hotloader.odin`) works by:
- Watching `out/hot/LindaleHot.dylib` for modifications
- When changed, copying it to a numbered version (e.g., `LindaleHot001.dylib`)
- Unloading the old DLL and loading the new one
- Using atomic operations to swap the function pointers in `PluginApi`

**Key files:**
- `src/hotloader.odin`: Hot-reload thread and DLL management
- `src/lindale/plugin.odin`: Core plugin state and `PluginApi` structure with `do_analysis`, `draw`, and `process_audio` procedures

### Plugin Architecture

The plugin is split into two VST3 components:

1. **LindaleProcessor** (`vst_layer.odin:84-508`): Audio processing component
   - Implements `IComponent` and `IAudioProcessor` interfaces
   - Runs on the audio thread
   - Manages parameter changes and audio buffer routing
   - Owns the `AudioProcessorContext`

2. **LindaleController** (`vst_layer.odin:510-770`): UI/controller component
   - Implements `IEditController` and `IEditController2` interfaces
   - Runs on the UI thread
   - Manages parameter state and the plugin view
   - Owns the `LindaleView` for rendering

3. **LindaleView** (`vst_layer.odin:772-1030`): Platform view implementation
   - Implements `IPlugView` interface
   - Creates platform-specific child windows using `platform_specific/view_platform_*.odin`
   - Runs a timer to drive the render loop at 30ms intervals

### Plugin State

The `Plugin` struct (`src/lindale/plugin.odin:14-34`) contains:
- `audioProcessor`: Audio processing state (owned by Processor)
- `render`, `draw`, `ui`: Rendering contexts (owned by Controller)
- `viewBounds`: Window dimensions
- `mouse`: Mouse input state

**Thread Safety Note:** The current architecture has a non-threadsafe hack (`gross_global_glob`) for transferring audio analysis data from the audio thread to the UI thread. This is acknowledged as temporary.

### Parameter System

Parameters are defined in `src/lindale/parameters.odin`:
- `ParamID` enum: Defines all parameters (Gain, Mix, Freq)
- `ParamTable`: Static table with metadata (name, range, units, defaults)
- `ParamState`: Runtime normalized parameter values (0-1)
- Parameter units support: Decibel, Hertz, Percentage, Normalized
- Automatic conversion between normalized and plain values

The VST3 layer converts between VST3 parameter changes and the plugin's internal parameter system.

### Audio Processing

Audio processing happens in `plugin_process_audio` (`src/lindale/plugin.odin:257-300`):
- Receives audio buffers as `AudioBufferGroup` with either f32 or f64 samples
- Parameter changes are provided with sample-accurate offsets
- Currently implements a simple square wave generator for demonstration

To modify audio processing behavior:
1. Edit `plugin_process_audio` in `src/lindale/plugin.odin`
2. Run `./build_hotload_plugin.command` to rebuild
3. The changes will hot-reload automatically while the plugin is running

### Rendering Architecture

SDF rounded rectangle renderer with instanced rendering. Supports borders, corner radii, and textures.

**Shared types** (`src/platform_api/platform_api.odin`):
- `RectInstance`: 56-byte per-instance data (pos, uv, color, border, corner radius)
- `TextureHandle`: Opaque handle to GPU texture
- `DrawCommand`: Specifies instance range, texture, and scissor for a draw call
- `RendererSize`: Logical size (points for UI), physical size (pixels), scale factor

**Renderer interface** (`src/platform_specific/view_platform.odin` documents the full interface):
- Lifecycle: `renderer_create`, `renderer_destroy`, `renderer_resize`, `renderer_get_size`
- Textures: `renderer_create_texture`, `renderer_destroy_texture`, `renderer_upload_texture`
- Rendering: `renderer_begin_frame`, `renderer_end_frame`, `renderer_upload_instances`, `renderer_begin_pass`, `renderer_end_pass`, `renderer_draw`

**Platform implementations**:
- `src/platform_specific/view_platform_darwin.odin`: Metal renderer for macOS
- DirectX 11 implementation planned for Windows

**Shader**: `src/shaders/shader.metal` - SDF rounded rect with border and texture support

UI code works in logical coordinates (points). The renderer handles DPI scaling internally.

### Platform-Specific Code

- `src/platform_api/`: Shared types between platform layer and lindale (avoids circular imports)
- `src/platform_specific/view_platform.odin`: Renderer interface documentation
- `src/platform_specific/view_platform_darwin.odin`: macOS Metal implementation
- `src/platform_specific/timer*.odin`: High-resolution timer for render loop

## Code Organization

```
src/
├── lindale/              # Hot-reloadable plugin code
│   ├── plugin.odin       # Core plugin logic and PluginApi
│   ├── audio_processor.odin  # Audio processing context
│   ├── parameters.odin   # Parameter definitions and conversions
│   ├── draw.odin         # Drawing primitive batching
│   └── ui.odin           # UI widgets
├── platform_api/         # Shared types (RectInstance, TextureHandle, etc.)
├── platform_specific/    # Platform renderers and OS integration
│   ├── view_platform.odin          # Renderer interface docs
│   ├── view_platform_darwin.odin   # Metal renderer (Mac)
│   └── timer*.odin                 # High-resolution timers
├── shaders/              # GPU shaders
│   └── shader.metal      # SDF rect shader
├── thirdparty/           # Third-party code (VST3 SDK, FFT, etc.)
├── test_host/            # Standalone test application
├── vst_layer.odin        # VST3 interface implementation
├── hotloader.odin        # Hot-reload system
└── logger*.odin          # Thread-safe logging
```

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
- **Container_of Pattern:** The VST3 layer uses a `container_of` pattern to convert from VST3 interface pointers back to the containing structs.
- **Reference Counting:** Each VST3 component manages its own reference count. When count reaches 0, the component is freed.
- **Context Management:** Each component stores its own Odin context with appropriate loggers for thread-safe logging.
- **Code Signing (Mac):** The build scripts use `codesign --force --sign -` for ad-hoc code signing required by macOS.

## Current Limitations & TODOs

- DirectX 11 renderer for Windows (Metal renderer complete for Mac)
- Add `onHotLoad` and `onHotUnload` handlers to plugin
- Replace audio-to-controller data transfer with proper transfer buffer
- Support CLAP format in addition to VST3
