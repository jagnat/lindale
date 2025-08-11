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
	instanceCount: int,
	instancePool: [DRAW_CHUNK_COUNT]RectInstance,
}

RectDrawBatchParams :: struct {
	scissor: RectI32,
	transform: linalg.Matrix4x4f32,
	texture: ^Texture2D,
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
	u, v, uw, vh: f32,
	color: ColorU8,
	cornerRad: f32,
}

DrawContext :: struct {
	plugin: ^Plugin,
	arena: vm.Arena,
	alloc: mem.Allocator,
	batchesFirst: ^RectDrawBatch,
	batchesLast: ^RectDrawBatch,
	fontTexture: Texture2D,
	emptyTexture: Texture2D,
}

draw_init :: proc(ctx: ^DrawContext) {
	err := vm.arena_init_growing(&ctx.arena)
	assert(err == .None)
	ctx.alloc = vm.arena_allocator(&ctx.arena)

	ctx.fontTexture = render_create_texture(ctx.plugin.render, 1, .R8_UNORM, FONT_ATLAS_SIZE, FONT_ATLAS_SIZE)

	ctx.emptyTexture = render_create_texture(ctx.plugin.render, 4, .R8G8B8A8_UNORM, 1, 1)
	textureData := []byte{255, 255, 255, 255}
	render_upload_texture(ctx.plugin.render, ctx.emptyTexture, textureData)

	fmt.println("size of rect instance:", size_of(RectInstance))
}

draw_default_params :: proc(ctx: ^DrawContext) -> RectDrawBatchParams {
	return RectDrawBatchParams{
		scissor = {0, 0, 0, 0},
		transform = linalg.identity_matrix(linalg.Matrix4x4f32),
		texture = &ctx.emptyTexture,
	}
}

draw_get_current_batch :: proc(ctx: ^DrawContext) -> ^RectDrawBatch {
	if ctx.batchesLast == nil {
		ctx.batchesLast = new(RectDrawBatch, allocator = ctx.alloc)
		if ctx.batchesFirst == nil do ctx.batchesFirst = ctx.batchesLast
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
	if ctx.batchesFirst != nil {
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
}

// Push a simple colored rectangle
draw_push_rect :: proc(ctx: ^DrawContext, rect: SimpleUIRect) {
	curBatch := draw_get_current_batch(ctx)

	if curBatch.params.texture != &ctx.emptyTexture {
		params := draw_default_params(ctx)
		params.texture = &ctx.emptyTexture
		curBatch = draw_create_new_batch(ctx, params)
	}

	instance : RectInstance
	instance.pos0 = {rect.x, rect.y}
	instance.pos1 = {rect.x + rect.width, rect.y + rect.height}
	instance.uv0 = {rect.u, rect.v}
	instance.uv1 = {rect.u + rect.uw, rect.v + rect.vh}
	instance.color = rect.color
	instance.cornerRad = rect.cornerRad
	draw_add_instance_to_batch(ctx, curBatch, instance)
}

// Push an instance - can have a custom texture.
// If texture is null, assumes the texture is the empty texture.
draw_push_instance :: proc(ctx: ^DrawContext, rect: RectInstance, texture: ^Texture2D = nil /* don't switch texture if nil */) {
	texture := texture
	if texture == nil do texture = &ctx.emptyTexture
	curBatch := draw_get_current_batch(ctx)
	if curBatch.params.texture != texture {
		params := draw_default_params(ctx)
		params.texture = texture
		curBatch = draw_create_new_batch(ctx, params)
	}
	draw_add_instance_to_batch(ctx, curBatch, rect)
}

draw_upload :: proc(ctx: ^DrawContext) {
	render_upload_rect_draw_batch(ctx.plugin.render, draw_get_current_batch(ctx))
}

draw_clear :: proc(ctx: ^DrawContext) {
	ctx.batchesFirst = nil
	ctx.batchesLast = nil
	vm.arena_free_all(&ctx.arena)
}

draw_submit :: proc(ctx: ^DrawContext) {
	if ctx.batchesFirst == nil do return // nothing to do

	render_begin(ctx.plugin.render)
	// Upload batches first
	curBatch := ctx.batchesFirst
	for curBatch != nil {
		render_upload_rect_draw_batch(ctx.plugin.render, curBatch)
		render_draw_rects(ctx.plugin.render)
		curBatch = curBatch.next
	}
	render_end(ctx.plugin.render)
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

draw_text :: proc(ctx: ^DrawContext, text: string, x, y: f32) {
	strLen := len(text)
	buf := make([dynamic]RectInstance, strLen, allocator = context.temp_allocator)

	counts := font_get_text_quads(text, buf[:])
	// fmt.println("Got ", counts, " characters")

	for &rect in buf {
		rect.color = {255, 255, 255, 255}
		draw_push_instance(ctx, rect, &ctx.fontTexture)
	}

	// render_set_sampler_channels(ctx.plugin.render, {1, 0, 0, 0}, {1, 1, 1, 0})
	// render_upload_texture(ctx.plugin.render, ctx.fontTexture, font_get_atlas())

	// render_bind_texture(ctx.plugin.render, &ctx.fontTexture)
}
