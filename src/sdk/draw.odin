package sdk

import "core:fmt"
import "core:math"
import "core:slice"
import "core:math/rand"
import "core:math/linalg"

DRAW_CHUNK_COUNT :: 128

RectDrawChunk :: struct {
	next: ^RectDrawChunk,
	instance_count: u32,
	instance_pool: [DRAW_CHUNK_COUNT]DrawInstance,
}

RectDrawBatchParams :: struct {
	scissor: RectI32,
	texture: TextureHandle,
	single_channel_texture: bool,
}

RectDrawBatch :: struct {
	chunk_first: ^RectDrawChunk,
	chunk_last:  ^RectDrawChunk,
	total_instance_count: u32,
	params: RectDrawBatchParams,
	next: ^RectDrawBatch,
}

RectDrawBatchIterator :: struct {
	current_chunk: ^RectDrawChunk,
	batch: ^RectDrawBatch,
}

SimpleUIRect :: struct {
	x, y, width, height: f32,
	u, v, uw, vh: f32,
	color: ColorU8,
	corner_rad: f32,
	border_color: ColorU8,
	border_width: f32,
}

DrawContext :: struct {
	plugin: ^PluginController,
	initialized: bool,
	font_state: FontState,
	batches_first: ^RectDrawBatch,
	batches_last: ^RectDrawBatch,
	total_instance_count: u32,
	clear_color: ColorF32,
}

draw_set_clear_color_f32 :: proc(ctx: ^DrawContext, color: ColorF32) {
	ctx.clear_color = color
}

draw_set_clear_color_u8 :: proc(ctx: ^DrawContext, color: ColorU8) {
	ctx.clear_color = color_f32_from_color_u8(color)
}

draw_set_clear_color :: proc {draw_set_clear_color_f32, draw_set_clear_color_u8}

draw_default_params :: proc(ctx: ^DrawContext) -> RectDrawBatchParams {
	return RectDrawBatchParams{
		scissor = {0, 0, 0, 0},
		texture = ctx.plugin.host.font_atlas,
		single_channel_texture = true,
	}
}

draw_get_current_batch :: proc(ctx: ^DrawContext) -> ^RectDrawBatch {
	if ctx.batches_last == nil {
		draw_create_new_batch(ctx, draw_default_params(ctx))
	}
	return ctx.batches_last
}

draw_create_new_batch :: proc(ctx: ^DrawContext, params: RectDrawBatchParams) -> ^RectDrawBatch {
	new_batch := new(RectDrawBatch, allocator = context.temp_allocator)
	new_batch.params = params
	if ctx.batches_last != nil {
		ctx.batches_last.next = new_batch
	}
	ctx.batches_last = new_batch
	if ctx.batches_first == nil {
		ctx.batches_first = ctx.batches_last
	}
	return new_batch
}

draw_add_instance_to_batch :: proc(ctx: ^DrawContext, batch: ^RectDrawBatch, instance: DrawInstance) {
	last_chunk := batch.chunk_last
	if last_chunk == nil || last_chunk.instance_count + 1 >= len(last_chunk.instance_pool) {
		new_chunk := new(RectDrawChunk, allocator = context.temp_allocator)
		if last_chunk != nil do last_chunk.next = new_chunk
		batch.chunk_last = new_chunk
		if batch.chunk_first == nil do batch.chunk_first = new_chunk
		last_chunk = new_chunk
	}
	last_chunk.instance_pool[last_chunk.instance_count] = instance
	last_chunk.instance_count += 1
	batch.total_instance_count += 1
	ctx.total_instance_count += 1
}

draw_set_texture :: proc(ctx: ^DrawContext, texture: TextureHandle, single_channel := false) {
	cur_batch := draw_get_current_batch(ctx)

	if cur_batch.params.texture == texture || cur_batch.total_instance_count == 0 {
		cur_batch.params.texture = texture
		cur_batch.params.single_channel_texture = single_channel
		return
	}

	params := cur_batch.params
	params.texture = texture
	params.single_channel_texture = single_channel

	draw_create_new_batch(ctx, params)
}

draw_set_scissor :: proc(ctx: ^DrawContext, scissor: RectI32) {
	cur_batch := draw_get_current_batch(ctx)

	if cur_batch.params.scissor == scissor || cur_batch.total_instance_count == 0 {
		cur_batch.params.scissor = scissor
		return
	}

	params := cur_batch.params
	params.scissor = scissor

	draw_create_new_batch(ctx, params)
}

draw_remove_scissor :: proc(ctx: ^DrawContext) {
	draw_set_scissor(ctx, RectI32{0, 0, 0, 0})
}

// Push a simple colored rectangle
draw_push_rect :: proc(ctx: ^DrawContext, rect: SimpleUIRect) {
	cur_batch := draw_get_current_batch(ctx)

	instance : DrawInstance
	instance.pos0 = {rect.x, rect.y}
	instance.pos1 = {rect.x + rect.width, rect.y + rect.height}
	instance.uv0 = {rect.u, rect.v}
	instance.uv1 = {rect.u + rect.uw, rect.v + rect.vh}
	instance.color = rect.color
	instance.shape_param = rect.corner_rad
	instance.no_texture = 1
	instance.border_color = rect.border_color
	instance.border_width = rect.border_width
	draw_add_instance_to_batch(ctx, cur_batch, instance)
}

draw_push_instance :: proc(ctx: ^DrawContext, rect: DrawInstance) {
	cur_batch := draw_get_current_batch(ctx)
	draw_add_instance_to_batch(ctx, cur_batch, rect)
}

draw_push_pill :: proc(ctx: ^DrawContext, p0, p1: Vec2f, thickness: f32, color: ColorU8, border_width: f32 = 0, border_color: ColorU8 = {}) {
	r := thickness * 0.5 + 1.0
	instance := DrawInstance{
		pos0       = {min(p0.x, p1.x) - r, min(p0.y, p1.y) - r},
		pos1       = {max(p0.x, p1.x) + r, max(p0.y, p1.y) + r},
		uv0        = p0,
		uv1        = p1,
		color      = color,
		border_color = border_color,
		border_width = border_width,
		shape_param = thickness,
		no_texture  = 1,
		mode       = ShaderMode.Pill,
	}
	cur_batch := draw_get_current_batch(ctx)
	draw_add_instance_to_batch(ctx, cur_batch, instance)
}

draw_push_arc :: proc(ctx: ^DrawContext, center: Vec2f, radius: f32, start_angle, end_angle: f32, thickness: f32, color: ColorU8, border_width: f32 = 0, border_color: ColorU8 = {}) {
	margin := radius + thickness * 0.5 + 1.0
	instance := DrawInstance{
		pos0        = {center.x - margin, center.y - margin},
		pos1        = {center.x + margin, center.y + margin},
		uv0         = center,
		uv1         = {start_angle, end_angle},
		color       = color,
		border_color = border_color,
		border_width = border_width,
		shape_param  = thickness,
		no_texture   = 1,
		mode        = ShaderMode.Arc,
		extra0      = radius,
	}
	cur_batch := draw_get_current_batch(ctx)
	draw_add_instance_to_batch(ctx, cur_batch, instance)
}

draw_clear :: proc(ctx: ^DrawContext) {
	ctx.batches_first = nil
	ctx.batches_last = nil
	ctx.total_instance_count = 0

	size := ctx.plugin.host.platform.get_size(ctx.plugin.host.renderer)
	font_set_scale(&ctx.font_state, size.scale_factor)
}

draw_submit :: proc(ctx: ^DrawContext) {
	p := ctx.plugin.host.platform
	r := ctx.plugin.host.renderer

	if !p.begin_frame(r) do return

	if font_is_texture_dirty(&ctx.font_state) {
		p.upload_texture(r, ctx.plugin.host.font_atlas, font_get_atlas(&ctx.font_state))
		font_reset_dirty_flag(&ctx.font_state)
	}

	if ctx.batches_first != nil {
		instances := make([]DrawInstance, ctx.total_instance_count, context.temp_allocator)
		idx: u32 = 0
		for batch := ctx.batches_first; batch != nil; batch = batch.next {
			for chunk := batch.chunk_first; chunk != nil; chunk = chunk.next {
				copy(instances[idx:], chunk.instance_pool[:chunk.instance_count])
				idx += chunk.instance_count
			}
		}
		p.upload_instances(r, instances)
	}

	p.begin_pass(r, ctx.clear_color)

	offset: u32 = 0
	for batch := ctx.batches_first; batch != nil; batch = batch.next {
		p.draw(r, DrawCommand{
			instance_offset = offset,
			instance_count = batch.total_instance_count,
			texture = batch.params.texture,
			single_channel_texture = batch.params.single_channel_texture,
			scissor = batch.params.scissor,
		})
		offset += batch.total_instance_count
	}

	p.end_pass(r)
	p.end_frame(r)
}

draw_generate_random_rects :: proc(ctx: ^DrawContext) {
	NUM_RECTS :: 40
	draw_clear(ctx)
	ALPH :: 100
	colors := []ColorU8{{255, 255, 255, ALPH}}
	w, h := f32(ctx.plugin.view_bounds.w), f32(ctx.plugin.view_bounds.h)
	for i in 0 ..< NUM_RECTS {
		rect := SimpleUIRect{rand.float32() * w, rand.float32() * h,
			rand.float32() * 300 + 10, rand.float32() * 300 + 10,
			0, 0, 0, 0, // UVs
			 rand.choice(colors), 20, {}, 0}
		draw_push_rect(ctx, rect)
	}
}

draw_generate_random_textured_rects :: proc(ctx: ^DrawContext) {
	NUM_RECTS :: 40
	draw_clear(ctx)
	ALPH :: 255
	colors := []ColorU8{{255, 255, 255, ALPH}}
	w, h := f32(ctx.plugin.view_bounds.w), f32(ctx.plugin.view_bounds.h)
	for i in 0 ..< NUM_RECTS {
		u := rand.choice([]f32{0, 0.5});
		v := rand.choice([]f32{0, 0.5});
		rect := SimpleUIRect{rand.float32() * w, rand.float32() * h,
			rand.float32() * 300 + 10, rand.float32() * 300 + 10,
			u, v, 0.5, 0.5, // UVs
			rand.choice(colors), 0, {}, 0}
		draw_push_rect(ctx, rect)
	}
}

draw_generate_random_spheres :: proc(ctx: ^DrawContext) {
	NUM_SPHERES::100
	draw_clear(ctx)
	ALPH :: 255
	colors := []ColorU8{{139, 139, 139, ALPH}}
	w, h := f32(ctx.plugin.view_bounds.w), f32(ctx.plugin.view_bounds.h)
	for i in 0 ..< NUM_SPHERES {
		// RAD := rand.float32() * 40 + 10
		RAD :: 7
		x := math.floor(rand.float32() * w)
		y := math.floor(rand.float32() * h)
		rect := SimpleUIRect{x, y,
			2 * RAD, 2 * RAD,
			0, 0, 0, 0,
			rand.choice(colors), RAD, {}, 0}
		draw_push_rect(ctx, rect)
	}
}

draw_generate_random_subpixelrects :: proc(ctx: ^DrawContext) {
	NUM::100
	draw_clear(ctx)
	ALPH :: 255
	colors := []ColorU8{{139, 139, 139, ALPH}}
	w, h := f32(ctx.plugin.view_bounds.w), f32(ctx.plugin.view_bounds.h)
	for i in 0 ..< NUM {
		RAD :: 7
		x := math.floor(rand.float32() * w)
		y := math.floor(rand.float32() * h)
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

draw_text :: proc(ctx: ^DrawContext, text: string, x, y: f32, color: ColorU8 = {255, 255, 255, 255}, size: f32 = FONT_SIZE_DEFAULT) {
	str_len := len(text)
	buf := make([dynamic]DrawInstance, str_len, allocator = context.temp_allocator)

	ascent, _, _ := font_get_vertical_metrics(&ctx.font_state, size)

	counts := font_get_text_quads(&ctx.font_state, text, x, y + ascent, size, buf[:])

	draw_set_texture(ctx, ctx.plugin.host.font_atlas, true)

	for &rect in buf {
		rect.color = color
		draw_push_instance(ctx, rect)
	}
}

draw_measure_text :: proc(ctx: ^DrawContext, text: string, size: f32 = FONT_SIZE_DEFAULT) -> Vec2f {
	return font_measure_bounds(&ctx.font_state, text, size)
}

draw_polyline :: proc(ctx: ^DrawContext, endpts: []Vec2f, color: ColorU8 = {255, 255, 255, 255}, thickness: f32 = 1, border_width: f32 = 0, border_color: ColorU8 = {}) {
	if len(endpts) < 2 do return
	start_pt := endpts[0]
	for end_pt in endpts[1:] {
		draw_push_pill(ctx, start_pt, end_pt, thickness, color, border_width, border_color)
		start_pt = end_pt
	}
}

draw_filled_rect :: proc(ctx: ^DrawContext, x, y, w, h: f32, color: ColorU8, corner_rad: f32 = 0) {
	draw_push_rect(ctx, SimpleUIRect{x = x, y = y, width = w, height = h, color = color, corner_rad = corner_rad})
}

draw_bordered_rect :: proc(ctx: ^DrawContext, x, y, w, h: f32, fill: ColorU8, border: ColorU8, border_width: f32, corner_rad: f32 = 0) {
	draw_push_rect(ctx, SimpleUIRect{x = x, y = y, width = w, height = h, color = fill, corner_rad = corner_rad, border_color = border, border_width = border_width})
}

draw_circle :: proc(ctx: ^DrawContext, cx, cy, radius: f32, color: ColorU8) {
	draw_push_rect(ctx, SimpleUIRect{x = cx - radius, y = cy - radius, width = radius * 2, height = radius * 2, color = color, corner_rad = radius})
}
