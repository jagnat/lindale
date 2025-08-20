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
	texture: ^Texture2D,
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
	fontTexture: Texture2D,
	clearColor: ColorF32,
}

draw_init :: proc(ctx: ^DrawContext) {
	if ctx.initialized do return

	err := vm.arena_init_growing(&ctx.arena)
	assert(err == .None)
	ctx.alloc = vm.arena_allocator(&ctx.arena)
	ctx.clearColor = {0, 0, 0, 1}

	ctx.fontTexture = render_create_texture(ctx.plugin.render, 1, .R8_UNORM, FONT_ATLAS_SIZE, FONT_ATLAS_SIZE)
	ctx.fontTexture.data = ctx.fontState.fontContext.textureData
	
	font_init(&ctx.fontState)
	ctx.initialized = true
}

draw_set_clear_color :: proc(ctx: ^DrawContext, color: ColorF32) {
	ctx.clearColor = color
}

draw_default_params :: proc(ctx: ^DrawContext) -> RectDrawBatchParams {
	return RectDrawBatchParams{
		scissor = {0, 0, 0, 0},
		texture = &ctx.fontTexture,
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

draw_set_texture :: proc(ctx: ^DrawContext, texture: ^Texture2D) {
	curBatch := draw_get_current_batch(ctx)

	if curBatch.params.texture == texture || curBatch.totalInstanceCount == 0 {
		curBatch.params.texture = texture
		return
	}

	params := curBatch.params
	params.texture = texture

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
	if ctx.batchesFirst == nil do return // nothing to do

	ready := render_frame_begin(ctx.plugin.render)
	if !ready do return

	// Upload textures
	render_upload_texture(ctx.plugin.render, &ctx.fontTexture, ctx.fontState.fontContext.textureData)

	// Upload instances
	uploadCtx := render_begin_instance_upload(ctx.plugin.render, u32(ctx.totalInstanceCount))
	curBatch := ctx.batchesFirst
	fill := uploadCtx.instanceFill
	idx: u32 = 0
	for curBatch != nil {
		curChunk := curBatch.chunkFirst
		for curChunk != nil {
			copy(fill[idx:idx+curChunk.instanceCount], curChunk.instancePool[:curChunk.instanceCount])
			idx += curChunk.instanceCount
			curChunk = curChunk.next
		}
		curBatch = curBatch.next
	}
	assert(idx == ctx.totalInstanceCount)
	render_end_instance_upload(ctx.plugin.render, uploadCtx)

	// Draw
	render_begin_pass(ctx.plugin.render, ctx.clearColor)

	curBatch = ctx.batchesFirst
	batchOffs: u32 = 0
	for curBatch != nil {
		// set scissor, texture, uniforms
		render_set_scissor(ctx.plugin.render, curBatch.params.scissor)
		render_bind_texture(ctx.plugin.render, &ctx.fontTexture)

		render_draw_rects(ctx.plugin.render, batchOffs, curBatch.totalInstanceCount)
		batchOffs += curBatch.totalInstanceCount
		curBatch = curBatch.next
	}

	render_end_pass(ctx.plugin.render)

	render_frame_end(ctx.plugin.render)
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
			 rand.choice(colors), 20}
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
			rand.choice(colors), 0}
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
			rand.choice(colors), rad}
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
			rand.choice(colors), 0}
		draw_push_rect(ctx, rect)
	}
}

draw_one_rect :: proc(ctx: ^DrawContext) {
	draw_clear(ctx)
	rect := SimpleUIRect{200, 200,
			100, 100, 
			0, 0, 0, 0,
			{0, 255, 0, 255}, 0}
	draw_push_rect(ctx, rect)
}

draw_text :: proc(ctx: ^DrawContext, text: string, x, y: f32, color: ColorU8 = {255, 255, 255, 255}) {
	strLen := len(text)
	buf := make([dynamic]RectInstance, strLen, allocator = context.temp_allocator)

	counts := font_get_text_quads(&ctx.fontState, text, x, y, buf[:])

	draw_set_texture(ctx, &ctx.fontTexture)

	for &rect in buf {
		rect.color = color
		draw_push_instance(ctx, rect)
	}

	if font_is_texture_dirty(&ctx.fontState) {
		ctx.fontTexture.uploaded = false
		font_reset_dirty_flag(&ctx.fontState)
	}
}

draw_measure_text :: proc(ctx: ^DrawContext, text: string) -> Vec2f {
	rect := font_measure_bounds(&ctx.fontState, text, 0, 0)
	return {rect.w, rect.h}
}