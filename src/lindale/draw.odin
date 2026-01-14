package lindale

import "core:fmt"
import "core:mem"
import "core:math"
import "core:slice"
import "core:math/rand"
import "core:math/linalg"
import vm "core:mem/virtual"

DRAW_CHUNK_COUNT :: 128

WINDOW_WIDTH, WINDOW_HEIGHT : i32 : 800, 600

RectDrawChunk :: struct {
	next: ^RectDrawChunk,
	instanceCount: u32,
	instancePool: [DRAW_CHUNK_COUNT]RectInstance,
}

RectDrawBatchParams :: struct {
	scissor: RectI32,
	texture: TextureHandle,
	singleChannelTexture: bool,
}

RectDrawBatch :: struct {
	chunkFirst: ^RectDrawChunk,
	chunkLast:  ^RectDrawChunk,
	totalInstanceCount: u32,
	params: RectDrawBatchParams,
	next: ^RectDrawBatch,
}

RectDrawBatchIterator :: struct {
	currentChunk: ^RectDrawChunk,
	batch: ^RectDrawBatch,
}

SimpleUIRect :: struct {
	x, y, width, height: f32,
	u, v, uw, vh: f32,
	color: ColorU8,
	cornerRad: f32,
	borderColor: ColorU8,
	borderWidth: f32,
}

DrawContext :: struct {
	plugin: ^Plugin,
	initialized: bool,
	fontState: FontState,
	arena: vm.Arena,
	alloc: mem.Allocator,
	batchesFirst: ^RectDrawBatch,
	batchesLast: ^RectDrawBatch,
	totalInstanceCount: u32,
	clearColor: ColorF32,
}

draw_init :: proc(ctx: ^DrawContext) {
	if ctx.initialized do return

	err := vm.arena_init_growing(&ctx.arena)
	assert(err == .None)
	ctx.alloc = vm.arena_allocator(&ctx.arena)
	ctx.clearColor = {0, 0, 0, 1}

	font_init(&ctx.fontState)
	ctx.initialized = true
}

draw_set_clear_color :: proc(ctx: ^DrawContext, color: ColorF32) {
	ctx.clearColor = color
}

draw_default_params :: proc(ctx: ^DrawContext) -> RectDrawBatchParams {
	return RectDrawBatchParams{
		scissor = {0, 0, 0, 0},
		texture = ctx.plugin.fontAtlas,
		singleChannelTexture = true,
	}
}

draw_get_current_batch :: proc(ctx: ^DrawContext) -> ^RectDrawBatch {
	if ctx.batchesLast == nil {
		draw_create_new_batch(ctx, draw_default_params(ctx))
	}
	return ctx.batchesLast
}

draw_create_new_batch :: proc(ctx: ^DrawContext, params: RectDrawBatchParams) -> ^RectDrawBatch {
	newBatch := new(RectDrawBatch, allocator = ctx.alloc)
	newBatch.params = params
	if ctx.batchesLast != nil {
		ctx.batchesLast.next = newBatch
	}
	ctx.batchesLast = newBatch
	if ctx.batchesFirst == nil {
		ctx.batchesFirst = ctx.batchesLast
	}
	return newBatch
}

draw_add_instance_to_batch :: proc(ctx: ^DrawContext, batch: ^RectDrawBatch, instance: RectInstance) {
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
	ctx.totalInstanceCount += 1
}

draw_set_texture :: proc(ctx: ^DrawContext, texture: TextureHandle, singleChannel := false) {
	curBatch := draw_get_current_batch(ctx)

	if curBatch.params.texture == texture || curBatch.totalInstanceCount == 0 {
		curBatch.params.texture = texture
		curBatch.params.singleChannelTexture = singleChannel
		return
	}

	params := curBatch.params
	params.texture = texture
	params.singleChannelTexture = singleChannel

	draw_create_new_batch(ctx, params)
}

draw_set_scissor :: proc(ctx: ^DrawContext, scissor: RectI32) {
	curBatch := draw_get_current_batch(ctx)

	if curBatch.params.scissor == scissor || curBatch.totalInstanceCount == 0 {
		curBatch.params.scissor = scissor
		return
	}

	params := curBatch.params
	params.scissor = scissor

	draw_create_new_batch(ctx, params)
}

draw_remove_scissor :: proc(ctx: ^DrawContext) {
	draw_set_scissor(ctx, RectI32{0, 0, 0, 0})
}

// Push a simple colored rectangle
draw_push_rect :: proc(ctx: ^DrawContext, rect: SimpleUIRect) {
	curBatch := draw_get_current_batch(ctx)

	instance : RectInstance
	instance.pos0 = {rect.x, rect.y}
	instance.pos1 = {rect.x + rect.width, rect.y + rect.height}
	instance.uv0 = {rect.u, rect.v}
	instance.uv1 = {rect.u + rect.uw, rect.v + rect.vh}
	instance.color = rect.color
	instance.cornerRad = rect.cornerRad
	instance.noTexture = 1
	instance.borderColor = rect.borderColor
	instance.borderWidth = rect.borderWidth
	draw_add_instance_to_batch(ctx, curBatch, instance)
}

draw_push_instance :: proc(ctx: ^DrawContext, rect: RectInstance) {
	curBatch := draw_get_current_batch(ctx)
	draw_add_instance_to_batch(ctx, curBatch, rect)
}

draw_clear :: proc(ctx: ^DrawContext) {
	ctx.batchesFirst = nil
	ctx.batchesLast = nil
	ctx.totalInstanceCount = 0
	vm.arena_free_all(&ctx.arena)
}

draw_submit :: proc(ctx: ^DrawContext) {
	if ctx.batchesFirst == nil do return

	p := ctx.plugin.platform
	r := ctx.plugin.renderer

	if !p.begin_frame(r) do return

	if font_is_texture_dirty(&ctx.fontState) {
		p.upload_texture(r, ctx.plugin.fontAtlas, font_get_atlas(&ctx.fontState))
		font_reset_dirty_flag(&ctx.fontState)
	}

	instances := make([]RectInstance, ctx.totalInstanceCount, context.temp_allocator)
	idx: u32 = 0
	for batch := ctx.batchesFirst; batch != nil; batch = batch.next {
		for chunk := batch.chunkFirst; chunk != nil; chunk = chunk.next {
			copy(instances[idx:], chunk.instancePool[:chunk.instanceCount])
			idx += chunk.instanceCount
		}
	}
	p.upload_instances(r, instances)

	p.begin_pass(r, ctx.clearColor)

	offset: u32 = 0
	for batch := ctx.batchesFirst; batch != nil; batch = batch.next {
		p.draw(r, DrawCommand{
			instanceOffset = offset,
			instanceCount = batch.totalInstanceCount,
			texture = batch.params.texture,
			singleChannelTexture = batch.params.singleChannelTexture,
			scissor = batch.params.scissor,
		})
		offset += batch.totalInstanceCount
	}

	p.end_pass(r)
	p.end_frame(r)
}

draw_generate_random_rects :: proc(ctx: ^DrawContext) {
	NUM_RECTS :: 40
	draw_clear(ctx)
	alph :: 100
	colors := []ColorU8{{255, 255, 255, alph}}
	for i in 0 ..< NUM_RECTS {
		rect := SimpleUIRect{rand.float32() * f32(WINDOW_WIDTH), rand.float32() * f32(WINDOW_HEIGHT),
			rand.float32() * 300 + 10, rand.float32() * 300 + 10,
			0, 0, 0, 0, // UVs
			 rand.choice(colors), 20, {}, 0}
		draw_push_rect(ctx, rect)
	}
}

draw_generate_random_textured_rects :: proc(ctx: ^DrawContext) {
	NUM_RECTS :: 40
	draw_clear(ctx)
	alph :: 255
	colors := []ColorU8{{255, 255, 255, alph}}
	for i in 0 ..< NUM_RECTS {
		u := rand.choice([]f32{0, 0.5});
		v := rand.choice([]f32{0, 0.5});
		rect := SimpleUIRect{rand.float32() * f32(WINDOW_WIDTH), rand.float32() * f32(WINDOW_HEIGHT),
			rand.float32() * 300 + 10, rand.float32() * 300 + 10,
			u, v, 0.5, 0.5, // UVs
			rand.choice(colors), 0, {}, 0}
		draw_push_rect(ctx, rect)
	}
}

draw_generate_random_spheres :: proc(ctx: ^DrawContext) {
	NUM_SPHERES::100
	draw_clear(ctx)
	alph :: 255
	colors := []ColorU8{{139, 139, 139, alph}}
	for i in 0 ..< NUM_SPHERES {
		// rad := rand.float32() * 40 + 10
		rad :: 7
		x := math.floor(rand.float32() * f32(WINDOW_WIDTH))
		y := math.floor(rand.float32() * f32(WINDOW_HEIGHT))
		rect := SimpleUIRect{x, y,
			2 * rad, 2 * rad,
			0, 0, 0, 0,
			rand.choice(colors), rad, {}, 0}
		draw_push_rect(ctx, rect)
	}
}

draw_generate_random_subpixelrects :: proc(ctx: ^DrawContext) {
	NUM::100
	draw_clear(ctx)
	alph :: 255
	colors := []ColorU8{{139, 139, 139, alph}}
	for i in 0 ..< NUM {
		rad :: 7
		x := math.floor(rand.float32() * f32(WINDOW_WIDTH))
		y := math.floor(rand.float32() * f32(WINDOW_HEIGHT))
		rect := SimpleUIRect{x, y,
			1.5, 4.5,
			0, 0, 0, 0,
			rand.choice(colors), 0, {}, 0}
		draw_push_rect(ctx, rect)
	}
}

draw_one_rect :: proc(ctx: ^DrawContext) {
	draw_clear(ctx)
	rect := SimpleUIRect{200, 200,
			100, 100, 
			0, 0, 0, 0,
			{0, 255, 0, 255}, 0, {}, 0}
	draw_push_rect(ctx, rect)
}

draw_text :: proc(ctx: ^DrawContext, text: string, x, y: f32, color: ColorU8 = {255, 255, 255, 255}) {
	strLen := len(text)
	buf := make([dynamic]RectInstance, strLen, allocator = context.temp_allocator)

	ascent, _, _ := font_get_vertical_metrics(&ctx.fontState)

	counts := font_get_text_quads(&ctx.fontState, text, x, y + ascent, buf[:])

	draw_set_texture(ctx, ctx.plugin.fontAtlas, true)

	for &rect in buf {
		rect.color = color
		draw_push_instance(ctx, rect)
	}
}

draw_measure_text :: proc(ctx: ^DrawContext, text: string) -> Vec2f {
	return font_measure_bounds(&ctx.fontState, text)
}