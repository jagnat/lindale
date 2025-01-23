package lindale

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:math/rand"
import vm "core:mem/virtual"

RectDrawGroup :: struct {
	arena: mem.Arena,
	numRects: u32,
}

SimpleUIRect :: struct {
	x, y, width, height: f32,
	color: ColorU8,
}

DrawContext :: struct {
	arena: vm.Arena,
}

@(private="file")
ctx: DrawContext

draw_init :: proc() {
	err := vm.arena_init_growing(&ctx.arena)
	assert(err == .None)
	fmt.println("Size of rect instance:", size_of(RectInstance))
}

draw_init_rect_group :: proc(drawGroup: ^RectDrawGroup) {
	bytes, err := vm.arena_alloc(&ctx.arena, 8192, 8)
	assert(err == .None)
	mem.arena_init(&drawGroup.arena, bytes)
	drawGroup.numRects = 0
}

draw_push_rect :: proc(drawGroup: ^RectDrawGroup, rect: SimpleUIRect) {
	assert(drawGroup.arena.offset + size_of(RectInstance) < len(drawGroup.arena.data))
	instanceRaw, err := mem.arena_alloc(&drawGroup.arena, size_of(RectInstance))
	assert(err == .None)
	instance := cast(^RectInstance)instanceRaw
	instance.pos1 = {rect.x, rect.y}
	instance.pos2 = {rect.x + rect.width, rect.y + rect.height}
	instance.colors = {rect.color, rect.color, rect.color, rect.color}
	drawGroup.numRects += 1
}

draw_clear :: proc(drawGroup: ^RectDrawGroup) {
	mem.arena_free_all(&drawGroup.arena)
	drawGroup.numRects = 0
}

draw_group_get_memory :: proc(drawGroup: ^RectDrawGroup) -> (ptr: rawptr, bytes: u32) {
	return raw_data(drawGroup.arena.data), u32(drawGroup.arena.offset)
}

draw_generate_random_rects :: proc(drawGroup: ^RectDrawGroup) {
	NUM_RECTS :: 20
	colors := []ColorU8{{0, 0, 0, 0}, {0, 0, 0, 0}}
	for i in 0 ..< NUM_RECTS {
		rect := SimpleUIRect{rand.float32() * f32(WINDOW_WIDTH), rand.float32() * f32(WINDOW_HEIGHT),
			rand.float32() * 300, rand.float32() * 300, rand.choice(colors)}
		draw_push_rect(drawGroup, rect)
	}
}