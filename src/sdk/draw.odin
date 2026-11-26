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

// Border is inset, never grows the shape
Style :: struct {
	fill: ColorU8,
	border: ColorU8,
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

draw_set_scissor :: proc(ctx: ^DrawContext, rect: RectF32) {
	s := ctx.plugin.host.platform.get_size(ctx.plugin.host.renderer).scale_factor
	x0 := i32(math.round(rect.x * s))
	y0 := i32(math.round(rect.y * s))
	x1 := i32(math.round((rect.x + rect.w) * s))
	y1 := i32(math.round((rect.y + rect.h) * s))
	scissor := RectI32{x0, y0, x1 - x0, y1 - y0}

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
	draw_set_scissor(ctx, RectF32{0, 0, 0, 0})
}

draw_rect :: proc(ctx: ^DrawContext, rect: RectF32, style: Style, corner_rad: f32 = 0) {
	draw_instance(ctx, DrawInstance{
		pos0 = {rect.x, rect.y},
		pos1 = {rect.x + rect.w, rect.y + rect.h},
		color = style.fill,
		border_color = style.border,
		border_width = style.border_width,
		shape_param = corner_rad,
		no_texture = 1,
		mode = ShaderMode.Rect,
	})
}

draw_circle :: proc(ctx: ^DrawContext, center: Vec2f, radius: f32, style: Style) {
	draw_rect(ctx, {center.x - radius, center.y - radius, radius * 2, radius * 2}, style, radius)
}

// PIll from p0 to p1
draw_line :: proc(ctx: ^DrawContext, p0, p1: Vec2f, thickness: f32, style: Style) {
	r := thickness * 0.5 + 1.0
	draw_instance(ctx, DrawInstance{
		pos0 = {min(p0.x, p1.x) - r, min(p0.y, p1.y) - r},
		pos1 = {max(p0.x, p1.x) + r, max(p0.y, p1.y) + r},
		uv0 = p0,
		uv1 = p1,
		color = style.fill,
		border_color = style.border,
		border_width = style.border_width,
		shape_param = thickness,
		no_texture = 1,
		mode = ShaderMode.Pill,
	})
}

draw_polyline :: proc(ctx: ^DrawContext, pts: []Vec2f, thickness: f32, style: Style) {
	if len(pts) < 2 do return
	for i in 1 ..< len(pts) {
		draw_line(ctx, pts[i - 1], pts[i], thickness, style)
	}
}

// Angles in radians, 0 = east, increasing clockwise
draw_arc :: proc(ctx: ^DrawContext, center: Vec2f, radius: f32, start_angle, end_angle: f32, thickness: f32, style: Style) {
	margin := radius + thickness * 0.5 + 1.0
	draw_instance(ctx, DrawInstance{
		pos0 = {center.x - margin, center.y - margin},
		pos1 = {center.x + margin, center.y + margin},
		uv0 = center,
		uv1 = {start_angle, end_angle},
		color = style.fill,
		border_color = style.border,
		border_width = style.border_width,
		shape_param = thickness,
		no_texture = 1,
		mode = ShaderMode.Arc,
		extra0 = radius,
	})
}

draw_instance :: proc(ctx: ^DrawContext, instance: DrawInstance) {
	draw_add_instance_to_batch(ctx, draw_get_current_batch(ctx), instance)
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

// pos is the top-left of the text box
draw_text :: proc(ctx: ^DrawContext, text: string, pos: Vec2f, color: ColorU8 = {255, 255, 255, 255}, size: f32 = FONT_SIZE_DEFAULT) {
	str_len := len(text)
	buf := make([dynamic]DrawInstance, str_len, allocator = context.temp_allocator)

	ascent, _, _ := font_get_vertical_metrics(&ctx.font_state, size)

	counts := font_get_text_quads(&ctx.font_state, text, pos.x, pos.y + ascent, size, buf[:])

	draw_set_texture(ctx, ctx.plugin.host.font_atlas, true)

	for &rect in buf {
		rect.color = color
		draw_instance(ctx, rect)
	}
}

draw_measure_text :: proc(ctx: ^DrawContext, text: string, size: f32 = FONT_SIZE_DEFAULT) -> Vec2f {
	return font_measure_bounds(&ctx.font_state, text, size)
}
