package dsp

import "core:math"

// Transport-driven musical scheduling. Plugin-agnostic: feed it the block's
// beat window and it tells you which grid/euclidean onsets land inside, with
// sample-accurate offsets. Two grids with unrelated periods drift against each
// other and the bar for free, which is most of what makes polyrhythm feel alive.

// Per-block timing window. Refresh before querying grid/euclid each block.
SchedCtx :: struct {
	b0: f64, // beat position at block start
	bps: f64, // beats per sample
	n: int, // samples in this block
}

// A scheduled onset inside the current block.
SchedHit :: struct {
	offset: int, // sample within the block
	step: int, // global subdivision index, monotonic across the timeline
}

// Onsets every `period` beats, offset by `phase`, that fall in this block.
// Allocated from context.temp_allocator (the per-block frame allocator).
grid :: proc(ctx: SchedCtx, period: f32, phase: f32 = 0) -> []SchedHit {
	if period <= 0 || ctx.bps <= 0 do return nil
	b1 := ctx.b0 + f64(ctx.n) * ctx.bps
	p := f64(period)
	hits := make([dynamic]SchedHit, 0, 8, context.temp_allocator)
	k := int(math.ceil((ctx.b0 - f64(phase)) / p))
	for {
		beat := f64(phase) + f64(k) * p
		if beat >= b1 do break
		off := clamp(int((beat - ctx.b0) / ctx.bps), 0, ctx.n - 1)
		append(&hits, SchedHit{offset = off, step = k})
		k += 1
	}
	return hits[:]
}

// Whether global step `step` is an onset in a `hits`-in-`steps` euclidean pattern.
euclid_onset :: proc(step, hits, steps: int) -> bool {
	if hits <= 0 || steps <= 0 do return false
	i := step %% steps
	return (i * hits) %% steps < hits
}

// Euclidean rhythm: `hits` onsets spread over `steps`, each step `step_len` beats.
euclid :: proc(ctx: SchedCtx, hits, steps: int, step_len: f32, phase: f32 = 0) -> []SchedHit {
	base := grid(ctx, step_len, phase)
	if hits <= 0 || steps <= 0 do return nil
	out := make([dynamic]SchedHit, 0, len(base), context.temp_allocator)
	for h in base {
		if euclid_onset(h.step, hits, steps) do append(&out, h)
	}
	return out[:]
}

// Scales as scale-degree -> semitone offset. Pass the slice to scale_note.
@(rodata) SCALE_MINOR := [?]int{0, 2, 3, 5, 7, 8, 10}
@(rodata) SCALE_MAJOR := [?]int{0, 2, 4, 5, 7, 9, 11}
@(rodata) SCALE_PENTA := [?]int{0, 3, 5, 7, 10}

// MIDI note for a scale degree relative to `root` (negative degrees walk down).
scale_note :: proc(root: f32, degree: int, scale: []int) -> f32 {
	n := len(scale)
	if n == 0 do return root
	oct := int(math.floor(f32(degree) / f32(n)))
	idx := degree %% n
	return root + f32(oct * 12 + scale[idx])
}
