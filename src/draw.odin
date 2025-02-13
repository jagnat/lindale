package lindale

import "core:fmt"
import "core:mem"
import "core:math"
import "core:slice"
import "core:math/rand"
import "core:math/linalg"
import vm "core:mem/virtual"

DRAW_CHUNK_COUNT :: 128

RectDrawChunk :: struct {
	next: ^RectDrawChunk,
	instanceCount: int,
	instancePool: [DRAW_CHUNK_COUNT]RectInstance,
}

RectDrawBatchParams :: struct {
	scissor: RectI32,
	transform: linalg.Matrix4x4f32,
	texture: rawptr,
}

RectDrawBatch :: struct {
	chunkFirst: ^RectDrawChunk,
	chunkLast:  ^RectDrawChunk,
	totalInstanceCount: int,
	params: RectDrawBatchParams,
	next: ^RectDrawBatch,
}

RectDrawBatchIterator :: struct {
	currentChunk: ^RectDrawChunk,
	batch: ^RectDrawBatch,
}

SimpleUIRect :: struct {
	x, y, width, height: f32,
	color: ColorU8,
	cornerRad: f32,
}

DrawContext :: struct {
	arena: vm.Arena,
	alloc: mem.Allocator,
	batchesFirst: ^RectDrawBatch,
	batchesLast: ^RectDrawBatch,
}

@(private="file")
ctx: DrawContext

draw_init :: proc() {
	err := vm.arena_init_growing(&ctx.arena)
	assert(err == .None)
	ctx.alloc = vm.arena_allocator(&ctx.arena)

	fmt.println("size of rect instance:", size_of(RectInstance))
}

draw_get_current_batch :: proc() -> ^RectDrawBatch {
	if ctx.batchesLast == nil {
		ctx.batchesLast = new(RectDrawBatch, allocator = ctx.alloc)
		if ctx.batchesFirst == nil do ctx.batchesFirst = ctx.batchesLast
	}
	return ctx.batchesLast
}

draw_put_instance :: proc(batch: ^RectDrawBatch, instance: RectInstance) {
	lastChunk := batch.chunkLast
	if lastChunk == nil || lastChunk.instanceCount + 1 >= len(lastChunk.instancePool) {
		newChunk := new(RectDrawChunk, allocator = ctx.alloc)
		if lastChunk != nil do lastChunk.next = newChunk
		batch.chunkLast = newChunk
		if batch.chunkFirst == nil do batch.chunkFirst = newChunk
		lastChunk = newChunk
	}
	lastChunk.instancePool[lastChunk.instanceCount] = instance
	lastChunk.instanceCount += 1
	batch.totalInstanceCount += 1
}

draw_push_rect :: proc(rect: SimpleUIRect) {
	curBatch := draw_get_current_batch()

	instance : RectInstance
	instance.pos1 = {rect.x, rect.y}
	instance.pos2 = {rect.x + rect.width, rect.y + rect.height}
	instance.colors = {rect.color, rect.color, rect.color, rect.color}
	instance.cornerRad = {rect.cornerRad, rect.cornerRad, rect.cornerRad, rect.cornerRad}
	draw_put_instance(curBatch, instance)
}

draw_upload :: proc() {
	render_upload_rect_draw_batch(draw_get_current_batch())
}

draw_clear :: proc() {
	ctx.batchesFirst = nil
	ctx.batchesLast = nil
	vm.arena_free_all(&ctx.arena)
}

draw_generate_random_rects :: proc() {
	NUM_RECTS :: 4000
	draw_clear()
	alph :: 1
	colors := []ColorU8{{255, 255, 255, alph}}
	for i in 0 ..< NUM_RECTS {
		rect := SimpleUIRect{rand.float32() * f32(WINDOW_WIDTH), rand.float32() * f32(WINDOW_HEIGHT),
			rand.float32() * 300 + 10, rand.float32() * 300 + 10, rand.choice(colors), 20}
		draw_push_rect(rect)
	}
}

draw_generate_random_spheres :: proc() {
	NUM_SPHERES::100
	draw_clear()
	alph :: 255
	colors := []ColorU8{{139, 139, 139, alph}}
	for i in 0 ..< NUM_SPHERES {
		// rad := rand.float32() * 40 + 10
		rad :: 7
		x := math.floor(rand.float32() * f32(WINDOW_WIDTH))
		y := math.floor(rand.float32() * f32(WINDOW_HEIGHT))
		rect := SimpleUIRect{x, y,
			2 * rad, 2 * rad, rand.choice(colors), rad}
		draw_push_rect(rect)
	}
}

draw_generate_random_subpixelrects :: proc() {
	NUM::100
	draw_clear()
	alph :: 255
	colors := []ColorU8{{139, 139, 139, alph}}
	for i in 0 ..< NUM {
		// rad := rand.float32() * 40 + 10
		rad :: 7
		x := math.floor(rand.float32() * f32(WINDOW_WIDTH))
		y := math.floor(rand.float32() * f32(WINDOW_HEIGHT))
		rect := SimpleUIRect{x, y,
			1.5, 4.5, rand.choice(colors), 0}
		draw_push_rect(rect)
	}
}

draw_one_rect :: proc() {
	draw_clear()
	rect := SimpleUIRect{200, 200,
			100, 100, {0, 255, 0, 255}, 0}
	draw_push_rect(rect)
}
