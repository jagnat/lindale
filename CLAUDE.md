# CLAUDE.md

## Project Overview

Lindalë is a VST3 audio plugin framework in Odin (Mac + Windows), built around hot-reloading audio and UI code without restarting the DAW.

## Build Commands

Use the `.bat` scripts on Windows, `.command` on Mac.

- `build_plugin.*` — full VST3 plugin + hot-reloadable DLL. Outputs `out/Lindale.vst3/` and `out/hot/LindaleHot.(dll|dylib)`.
- `build_hotload_plugin.*` — only the hot-reloadable code. Use this during dev.

Symlink `out/Lindale.vst3` into the system VST3 folder:
- **Mac:** `~/Library/Audio/Plug-Ins/VST3`
- **Windows:** `C:\Program Files\Common Files\VST3`

## Style

- Tabs, not spaces.
- This is Odin — not C, not Go.
- Prefer extending existing files over creating new ones.
- No space-padded vertical alignment anywhere — one space between tokens, even if surrounding code does otherwise. Vtable struct declarations are the only exception.
- Route virtually all allocations through `HostContext`'s allocators — don't fall back to the default. `persistent_allocator` survives hot-reloads (lives until component destruction), `session_allocator` is freed on hot-reload or view close, `frame_allocator` is cleared per frame (controller) or per process call (processor).

### Comments

- Don't narrate what the next line obviously does. No "Create X" before creating X.
- Don't restate identifiers. Field `uniformBuffer` doesn't need `// Uniform buffer`.
- Keep only non-obvious info: `// 1MB instance buffer`, `// physical pixels`.
- Section headers stay plain: `// Renderer lifecycle`. No boxes or separator lines.
- `// TODO:` for incomplete work — not hedges like "if needed".
- Minimal punctuation. No trailing periods unless multiple sentences.

## Architecture (summary)

Four packages enforce the hot-reload boundary:

- `src/bridge/` — shared types and vtables. Imports only Odin core. The dependency root.
- `src/lindale/` — hot-reloadable plugin code (audio, UI, draw, parameters). Imports `bridge` and `dsp` only. **Never** imports `vst_host` or `platform_specific` — that rule is what makes it safe to swap as a standalone DLL.
- `src/platform_specific/` — GPU renderers (Metal/DX11), timers, filesystem. Imports `bridge` only.
- `src/vst_host/` — static VST3 layer and composition root. The only package that imports across the others.

See `docs/architecture.md` for the hot-reload lifecycle, `HostContext` survival semantics, parameter/rendering/UI subsystems, and implementation notes.

## Working Principles

**Think before coding.** Don't assume and don't hide confusion. State your assumptions up front. When a request is ambiguous, surface the interpretations instead of silently picking one. If something is genuinely unclear, ask.

**Simplicity first.** Write the minimum code that solves the problem. No speculative abstractions, no unrequested features, no error handling for scenarios that can't happen. If the solution could be half the length, it should be.

**Surgical changes.** Touch only what the task requires. Don't reformat or refactor unrelated working code. Match the surrounding style. Only remove code your changes orphaned — leave pre-existing dead code alone unless asked.
