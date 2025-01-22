package lindale

import "core:mem"
import "core:slice"
import vm "core:mem/virtual"

RectDrawGroup :: struct {
	arena: mem.Arena,
	numRects: u32,
	numVertices: u32,
}

UIRect :: struct {
	x, y, width, height: f32,
	cornerRadii: [4]f32,
	cornerColors: [4]ColorU8,
}

DrawContext :: struct {
	arena: vm.Arena,
}

@(private="file")
ctx: DrawContext

draw_init :: proc() {
	err := vm.arena_init_growing(&ctx.arena)
	assert(err == .None)
}

draw_init_rect_group :: proc(drawGroup: ^RectDrawGroup) {
	bytes, err := vm.arena_alloc(&ctx.arena, 8192, 32)
	assert(err == .None)
	mem.arena_init(&drawGroup.arena, bytes)
	drawGroup.numRects = 0
	drawGroup.numVertices = 0
}

// draw_push_rect :: proc(drawGroup: ^RectDrawGroup, rect: UIRect) {
// 	assert(drawGroup.arena.offset + 6 * size_of(UIRectVertex) < len(drawGroup.arena.data))
// 	vertRaw, err := mem.arena_alloc(&drawGroup.arena, 6 * size_of(UIRectVertex), 0)
// 	assert(err == .None)
// 	vertices := slice.from_ptr(cast(^UIRectVertex)vertRaw, 6)

// 	vertices[0] = UIRectVertex{}
// }