package lindale

import "core:fmt"
import "core:mem"
import "core:math"
import "core:slice"
import "core:math/rand"
import vm "core:mem/virtual"

RectDrawGroup :: struct {
	instancePool: []RectInstance,
	numRects: int,
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
	bytes, err := vm.arena_alloc(&ctx.arena, 1000 * size_of(RectInstance), 8)
	assert(err == .None)
	drawGroup.numRects = 0
	drawGroup.instancePool = slice.from_ptr((^RectInstance)(&bytes[0]), 1000 * size_of(RectInstance))
}

draw_push_rect :: proc(drawGroup: ^RectDrawGroup, rect: SimpleUIRect) {
	assert(drawGroup.numRects + 1 <= len(drawGroup.instancePool))
	instance : RectInstance
	instance.pos1 = {rect.x, rect.y}
	instance.pos2 = {rect.x + rect.width, rect.y + rect.height}
	instance.colors = {rect.color, rect.color, rect.color, rect.color}
	instance.cornerRad = {20, 20, 20, 20}
	drawGroup.instancePool[drawGroup.numRects] = instance
	drawGroup.numRects += 1
}

draw_clear :: proc(drawGroup: ^RectDrawGroup) {
	drawGroup.numRects = 0
}

draw_generate_random_rects :: proc(drawGroup: ^RectDrawGroup) {
	NUM_RECTS :: 400
	draw_clear(drawGroup)
	alph :: 255
	// colors := []ColorU8{{255, 0, 0, alph}, {0, 255, 0, alph}, {0, 0, 255, alph}}
	colors := []ColorU8{{255, 255, 255, alph}}
	for i in 0 ..< NUM_RECTS {
		rect := SimpleUIRect{rand.float32() * f32(WINDOW_WIDTH), rand.float32() * f32(WINDOW_HEIGHT),
			rand.float32() * 300 + 10, rand.float32() * 300 + 10, rand.choice(colors)}
		draw_push_rect(drawGroup, rect)
	}
}

draw_one_rect :: proc(drawGroup: ^RectDrawGroup) {
	draw_clear(drawGroup)
	rect := SimpleUIRect{200, 200,
			100, 100, {0, 255, 0, 255}}
	draw_push_rect(drawGroup, rect)
}

draw_get_rects :: proc(drawGroup: ^RectDrawGroup) -> []RectInstance {
	return drawGroup.instancePool[:drawGroup.numRects]
}