package lindale

import "core:math"
import "core:testing"
import b "../bridge"

UITheme :: struct {
	bgColor: ColorU8,
	panelBgColor: ColorU8,

	buttonColor: ColorU8,
	buttonHoverColor: ColorU8,
	buttonActiveColor: ColorU8,

	sliderTrackColor: ColorU8,
	sliderColor: ColorU8,
	sliderHoverColor: ColorU8,
	sliderActiveColor: ColorU8,

	textColor: ColorU8,

	borderColor: ColorU8,
	
	padding: f32,
	itemSpacing: f32,
	cornerRadius: f32,
	borderWidth: f32,
}

// Todo: Part of theme
slider_width :: 20
slider_rail_width :: 4

DEFAULT_THEME : UITheme : {
	bgColor = {0x3c, 0x3f, 0x41, 0xff},
	panelBgColor = {0x3c, 0x3f, 0x41, 0xff},
	buttonColor = {0x4e, 0x50, 0x52, 0xff},
	buttonHoverColor = {0x55, 0x58, 0x5a, 0xff},
	buttonActiveColor = {0x5d, 0x5f, 0x62, 0xff},
	sliderTrackColor = {0x61, 0x66, 0x69, 0xff},
	sliderColor = {0x4c, 0x87, 0xc8, 0xff},
	sliderHoverColor = {0x60, 0x94, 0xce, 0xff},
	sliderActiveColor = {0x6b, 0x9c, 0xd2, 0xff},
	textColor = {0xff, 0xff, 0xff, 0xff},
	borderColor = {0x61, 0x63, 0x65, 0xff},

	padding = 10,
	itemSpacing = 10,
	cornerRadius = 10,
	borderWidth = 1.5,
}

LayoutDirection :: enum { VERTICAL, HORIZONTAL, }

AlignX :: enum { LEFT, CENTER, RIGHT, }
AlignY :: enum { TOP,   CENTER, BOTTOM, }
SizingType :: enum { FIXED, FIT, GROW }

AxisSizing :: struct {
	type: SizingType,
	value: f32, // for fixed size;
	min, max: f32, // for grow/fit
	padding: f32,
}

ComponentType :: enum {
	PANEL,
	LABEL,
	BUTTON,
	SLIDER_V,
}

PanelData :: struct {
	skipDraw: bool,
}

LabelData :: struct {
	text: string,
}

ButtonData :: struct {
	label: string,
	id: u32,
}

SliderFloatBinding :: struct {
	val: ^f32,
	min, max: f32,
}

SliderParamBinding :: struct {
	param_idx: ParamIndex,
}

SliderVData :: struct {
	label: string,
	id: u32,
	binding: union {
		SliderFloatBinding,
		SliderParamBinding,
	},
}

ComponentData :: union {
	PanelData,
	LabelData,
	ButtonData,
	SliderVData,
}

Component :: struct {
	type: ComponentType,
	sizingHoriz, sizingVert: AxisSizing,

	direction: LayoutDirection,
	child_gaps: f32,
	alignX: AlignX,
	alignY: AlignY,

	// w and h are calculated first, then finally x and y
	calcBounds: RectF32,
	cursor: Vec2f, // Used for positioning pass

	parent: ^Component,
	firstChild: ^Component,
	nextSibling: ^Component,

	data: ComponentData,
}

ComponentIterator :: struct {
	current: ^Component,
}

UI_MAX_COMPONENTS :: 512
UI_MAX_DEPTH :: 128

UIContext :: struct {
	// 'Arena'
	componentPool: [UI_MAX_COMPONENTS]Component,
	componentCount: int,

	root: ^Component,
	currentComponent: ^Component,

	// Hit testing
	hoveredId: u32,
	activeId: u32,
	lastClickedId: u32,
	mouse: MouseState,
	theme: UITheme,

	plugin: ^Plugin
}

@(deferred_in = ui_frame_end)
ui_frame_scoped :: proc(ctx: ^UIContext) -> bool {
	ui_frame_begin(ctx)
	return true
}

@(deferred_in = _ui_panel_close)
ui_panel :: proc(ctx: ^UIContext,
	dir: LayoutDirection = .HORIZONTAL,
	child_gaps: f32 = 10,
	padding: f32 = 10,
	sizingHoriz: AxisSizing = {type = .FIT},
	sizingVert: AxisSizing = {type = .FIT},
	skipDraw: bool = false) -> bool {
	comp := ui_open_component(ctx)
	comp.data = PanelData{skipDraw = skipDraw}
	comp.direction = dir
	comp.sizingHoriz = sizingHoriz
	comp.sizingHoriz.padding = padding
	comp.sizingVert = sizingVert
	comp.sizingVert.padding = padding
	comp.child_gaps = child_gaps
	return true
}
_ui_panel_close :: proc(ctx: ^UIContext,
	dir: LayoutDirection = .HORIZONTAL,
	child_gaps: f32 = 10,
	padding: f32 = 10,
	sizingHoriz: AxisSizing = {type = .FIT},
	sizingVert: AxisSizing = {type = .FIT},
	skipDraw: bool = false,) {
	ui_close_component(ctx)
}

ui_label :: proc(ctx: ^UIContext, text: string, alignX: AlignX = .LEFT) {
	comp := ui_open_component(ctx)
	comp.type = .LABEL
	comp.alignX = alignX
	textSize := draw_measure_text(ctx.plugin.draw, text)
	comp.sizingHoriz = {type = .FIXED, value = textSize.x}
	comp.sizingVert = {type = .FIXED, value = textSize.y}
	comp.data = LabelData{text = text}
	ui_close_component(ctx)
}

ui_button :: proc(ctx: ^UIContext, label: string) -> bool {
	id := string_hash_u32(label)
	clicked := ctx.lastClickedId == id
	if clicked do ctx.lastClickedId = 0

	comp := ui_open_component(ctx)
	comp.type = .BUTTON
	textSize := draw_measure_text(ctx.plugin.draw, label)
	ascent, descent, _ := font_get_vertical_metrics(&ctx.plugin.draw.fontState)
	comp.sizingHoriz = {type = .FIXED, value = textSize.x + ctx.theme.padding * 2}
	comp.sizingVert = {type = .FIXED, value = (ascent - descent) + ctx.theme.padding * 2}
	comp.data = ButtonData{label = label, id = id}
	ui_close_component(ctx)
	return clicked
}

ui_slider_v :: proc(ctx: ^UIContext, label: string, val: ^f32, min, max: f32, alignX: AlignX = .CENTER) {
	id := string_hash_u32(label)
	comp := ui_open_component(ctx)
	comp.type = .SLIDER_V
	comp.alignX = alignX
	comp.sizingHoriz = {type = .FIXED, value = slider_width}
	comp.sizingVert = {type = .GROW, value = 200, min = 200, max = 500}
	comp.data = SliderVData{label, id, SliderFloatBinding{val, min, max}}
	ui_close_component(ctx)
}

ui_slider_labeled :: proc(ctx: ^UIContext, label: string, val: ^f32, min, max: f32) {
	comp := ui_open_component(ctx)
	comp.data = PanelData{skipDraw = true}
	comp.direction = .VERTICAL
	comp.child_gaps = 5
	comp.sizingHoriz = {type = .FIT}
	comp.sizingVert = {type = .GROW}
	ui_slider_v(ctx, label, val, min, max, alignX = .CENTER)
	ui_label(ctx, label, alignX = .CENTER)
	ui_close_component(ctx)
}

ui_slider_param :: proc(ctx: ^UIContext, label: string, param_idx: ParamIndex, alignX: AlignX = .CENTER) {
	id := string_hash_u32(label)
	comp := ui_open_component(ctx)
	comp.type = .SLIDER_V
	comp.alignX = alignX
	comp.sizingHoriz = {type = .FIXED, value = slider_width}
	comp.sizingVert = {type = .GROW, value = 200, min = 200, max = 500}
	comp.data = SliderVData{label, id, SliderParamBinding{param_idx}}
	ui_close_component(ctx)
}

ui_slider_param_labeled :: proc(ctx: ^UIContext, label: string, param_idx: ParamIndex) {
	comp := ui_open_component(ctx)
	comp.data = PanelData{skipDraw = true}
	comp.direction = .VERTICAL
	comp.child_gaps = 5
	comp.sizingHoriz = {type = .FIT}
	comp.sizingVert = {type = .GROW}
	ui_slider_param(ctx, label, param_idx, alignX = .CENTER)
	ui_label(ctx, label, alignX = .CENTER)
	ui_close_component(ctx)
}

@(private="file")
ui_alloc_component :: proc(ctx: ^UIContext) -> ^Component {
	assert(ctx.componentCount + 1 <= UI_MAX_COMPONENTS)
	comp := &ctx.componentPool[ctx.componentCount]
	ctx.componentCount += 1
	comp^ = {}
	return comp
}

ui_add_child_component :: proc(parent, child: ^Component) {
	if parent.firstChild == nil {
		parent.firstChild = child
	} else {
		lastSib := parent.firstChild
		for lastSib.nextSibling != nil {
			lastSib = lastSib.nextSibling
		}
		lastSib.nextSibling = child
	}
	child.parent = parent
}

ui_open_component :: proc(ctx: ^UIContext) -> ^Component {
	comp := ui_alloc_component(ctx)
	parent := ctx.currentComponent
	ui_add_child_component(parent, comp)
	ctx.currentComponent = comp
	return comp
}

ui_close_component :: proc(ctx: ^UIContext) {
	currentComp := ctx.currentComponent
	#partial switch currentComp.sizingHoriz.type {
		case .FIXED: currentComp.calcBounds.w = currentComp.sizingHoriz.value
		case .FIT: ui_size_fit_on_axis(ctx, true)
	}
	#partial switch currentComp.sizingVert.type {
		case .FIXED: currentComp.calcBounds.h = currentComp.sizingVert.value
		case .FIT: ui_size_fit_on_axis(ctx, false)
	}
	ctx.currentComponent = currentComp.parent
}

ui_frame_begin :: proc(ctx: ^UIContext) {
	ctx.theme = DEFAULT_THEME
	ctx.mouse = ctx.plugin.mouse
	ctx.plugin.mouse.pressed = {}
	ctx.plugin.mouse.released = {}
	ctx.plugin.mouse.scrollDelta = {}
	ctx.hoveredId = 0
	ctx.componentCount = 0
	ctx.root = ui_alloc_component(ctx)
	ctx.root^ = Component{}
	size := ctx.plugin.host.platform.get_size(ctx.plugin.host.renderer)
	ctx.root.calcBounds = RectF32 {0, 0, f32(size.logicalWidth), f32(size.logicalHeight)}
	ctx.currentComponent = ctx.root
}

ui_frame_end :: proc(ctx: ^UIContext) {
	ui_size_grow_components(ctx)
	ui_position_components(ctx)
	ui_interact_components(ctx)
	ui_generate_draw_calls(ctx)
}

ui_interact_components :: proc(ctx: ^UIContext) {
	it := ui_iterate_pre_order(ctx)
	for c in ui_next_pre_order(&it) {
		if c == ctx.root do continue
		switch c.type {
			case .PANEL, .LABEL: break
			case .BUTTON: {
				d := c.data.(ButtonData) or_continue
				mouseOver := collide_vec2_rect(ctx.mouse.pos, c.calcBounds)
				if mouseOver do ctx.hoveredId = d.id
				if d.id == ctx.activeId {
					if .Left not_in ctx.mouse.down {
						if mouseOver do ctx.lastClickedId = d.id
						ctx.activeId = 0
					}
				} else if d.id == ctx.hoveredId && .Left in ctx.mouse.pressed {
					ctx.activeId = d.id
				}
			}
			case .SLIDER_V: {
				d := c.data.(SliderVData) or_continue
				mouseOver := collide_vec2_rect(ctx.mouse.pos, c.calcBounds)
				if mouseOver do ctx.hoveredId = d.id
				if d.id == ctx.activeId {
					thumbR := f32(slider_width) / 2
					trackRange := c.calcBounds.h - f32(slider_width)
					mouseP := clamp(ctx.mouse.pos.y, c.calcBounds.y + thumbR, c.calcBounds.y + c.calcBounds.h - thumbR)
					norm := clamp(1.0 - (mouseP - c.calcBounds.y - thumbR) / trackRange, 0, 1)

					switch v in d.binding {
						case SliderFloatBinding: {
							v.val^ = v.min + norm * (v.max - v.min)
						}
						case SliderParamBinding: {
							inst := ctx.plugin.host
							if inst != nil && inst.params != nil {
								desc := param_table[v.param_idx]
								inst.params.values[v.param_idx] = b.normalized_to_param(f64(norm), desc)
							}
							if inst != nil && inst.hostApi != nil && inst.hostApi.param_edit_change != nil {
								inst.hostApi.param_edit_change(inst.hostApi.ctx, i32(v.param_idx), f64(norm))
							}
						}
					}

					if .Left not_in ctx.mouse.down {
						if pb, ok := d.binding.(SliderParamBinding); ok {
							inst := ctx.plugin.host
							if inst != nil && inst.hostApi != nil && inst.hostApi.param_edit_end != nil {
								inst.hostApi.param_edit_end(inst.hostApi.ctx, i32(pb.param_idx))
							}
						}
						ctx.activeId = 0
					}
				} else if d.id == ctx.hoveredId && .Left in ctx.mouse.pressed {
					ctx.activeId = d.id
					if pb, ok := d.binding.(SliderParamBinding); ok {
						inst := ctx.plugin.host
						if inst != nil && inst.hostApi != nil && inst.hostApi.param_edit_start != nil {
							inst.hostApi.param_edit_start(inst.hostApi.ctx, i32(pb.param_idx))
						}
					}
				}
			}
		}
	}
}

ui_size_grow_components :: proc(ctx: ^UIContext) {
	it := ui_iterate_pre_order(ctx)

	for comp in ui_next_pre_order(&it) {
		ui_size_grow_on_axis(comp, true)
		ui_size_grow_on_axis(comp, false)
	}
}

ui_size_grow_on_axis :: proc(comp: ^Component, horiz: bool) {
	sizing_along_axis := (comp.direction == .HORIZONTAL) == horiz
	padding := comp.sizingHoriz.padding if horiz else comp.sizingVert.padding
	parent_size := comp.calcBounds.w if horiz else comp.calcBounds.h

	if sizing_along_axis {
		// Main axis - distribute remaining space among grow children
		used: f32
		grow_count: int
		child_count: int

		childIter := ui_iterate_children(comp)
		for c in ui_next_child(&childIter) {
			child_count += 1
			sizing := c.sizingHoriz if horiz else c.sizingVert
			if sizing.type == .GROW {
				grow_count += 1
			} else {
				used += c.calcBounds.w if horiz else c.calcBounds.h
			}
		}

		if grow_count == 0 do return

		if child_count > 1 {
			used += comp.child_gaps * f32(child_count - 1)
		}
		used += padding * 2

		grow_size := (parent_size - used) / f32(grow_count)

		childIter = ui_iterate_children(comp)
		for c in ui_next_child(&childIter) {
			sizing := &c.sizingHoriz if horiz else &c.sizingVert
			if sizing.type != .GROW do continue
			size := grow_size
			if sizing.min > 0 do size = math.max(size, sizing.min)
			if sizing.max > 0 do size = math.min(size, sizing.max)
			if horiz {
				c.calcBounds.w = size
			} else {
				c.calcBounds.h = size
			}
		}
	} else {
		// cross axis - grow children expand to fill parent minus padding
		max_size := parent_size - padding * 2

		childIter := ui_iterate_children(comp)
		for c in ui_next_child(&childIter) {
			sizing := &c.sizingHoriz if horiz else &c.sizingVert
			if sizing.type != .GROW do continue
			size := max_size
			if sizing.min > 0 do size = math.max(size, sizing.min)
			if sizing.max > 0 do size = math.min(size, sizing.max)
			if horiz {
				c.calcBounds.w = size
			} else {
				c.calcBounds.h = size
			}
		}
	}
}

ui_position_components :: proc(ctx: ^UIContext) {
	ctx.root.cursor = {ctx.root.sizingHoriz.padding, ctx.root.sizingVert.padding}
	it := ui_iterate_pre_order(ctx)

	for c in ui_next_pre_order(&it) {
		if c == ctx.root do continue
		parent := c.parent

		if parent.direction == .HORIZONTAL {
			c.calcBounds.x = parent.cursor.x
			content_h := parent.calcBounds.h - 2 * parent.sizingVert.padding
			switch c.alignY {
			case .TOP:    c.calcBounds.y = parent.calcBounds.y + parent.sizingVert.padding
			case .CENTER: c.calcBounds.y = parent.calcBounds.y + parent.sizingVert.padding + (content_h - c.calcBounds.h) * 0.5
			case .BOTTOM: c.calcBounds.y = parent.calcBounds.y + parent.sizingVert.padding + content_h - c.calcBounds.h
			}
			parent.cursor.x += c.calcBounds.w + parent.child_gaps
		} else {
			c.calcBounds.y = parent.cursor.y
			content_w := parent.calcBounds.w - 2 * parent.sizingHoriz.padding
			switch c.alignX {
			case .LEFT:   c.calcBounds.x = parent.calcBounds.x + parent.sizingHoriz.padding
			case .CENTER: c.calcBounds.x = parent.calcBounds.x + parent.sizingHoriz.padding + (content_w - c.calcBounds.w) * 0.5
			case .RIGHT:  c.calcBounds.x = parent.calcBounds.x + parent.sizingHoriz.padding + content_w - c.calcBounds.w
			}
			parent.cursor.y += c.calcBounds.h + parent.child_gaps
		}

		c.cursor = {c.calcBounds.x + c.sizingHoriz.padding, c.calcBounds.y + c.sizingVert.padding}
	}
}

ui_generate_draw_calls :: proc(ctx: ^UIContext) {
	it := ui_iterate_pre_order(ctx)

	for c in ui_next_pre_order(&it) {
		if c == ctx.root do continue // Skip root node
		switch c.type {
			case .PANEL: {
				d := c.data.(PanelData) or_continue
				if d.skipDraw do continue
				rect := SimpleUIRect{}
				rect.x = c.calcBounds.x
				rect.y = c.calcBounds.y
				rect.width = c.calcBounds.w
				rect.height = c.calcBounds.h
				rect.color = ctx.theme.panelBgColor
				rect.cornerRad = ctx.theme.cornerRadius
				rect.borderWidth = 0.4
				rect.borderColor = {255, 255, 255, 255}
				draw_push_rect(ctx.plugin.draw, rect)
			}
			case .LABEL: {
				d := c.data.(LabelData) or_continue
				draw_text(ctx.plugin.draw,
					d.text,
					c.calcBounds.x,
					c.calcBounds.y,
					ctx.theme.textColor)
			}
			case .BUTTON: {
				bgColor := ctx.theme.buttonColor
				d := c.data.(ButtonData) or_continue
				if d.id == ctx.activeId do bgColor = ctx.theme.buttonActiveColor
				else if d.id == ctx.hoveredId do bgColor = ctx.theme.buttonHoverColor
				draw_push_rect(ctx.plugin.draw, SimpleUIRect {
					x = c.calcBounds.x, y = c.calcBounds.y,
					width = c.calcBounds.w, height = c.calcBounds.h,
					color = bgColor,
					cornerRad = ctx.theme.cornerRadius,
					borderColor = ctx.theme.borderColor,
					borderWidth = ctx.theme.borderWidth,
				})
				textSize := draw_measure_text(ctx.plugin.draw, d.label)
				draw_text(ctx.plugin.draw, d.label,
					c.calcBounds.x + (c.calcBounds.w - textSize.x) * 0.5,
					c.calcBounds.y + (c.calcBounds.h - textSize.y) * 0.5,
					ctx.theme.textColor)
			}
			case .SLIDER_V: {
				bounds := c.calcBounds
				d := c.data.(SliderVData) or_continue
				thumbR := f32(slider_width) / 2
				trackRange := bounds.h - f32(slider_width)

				norm: f32
				switch v in d.binding {
				case SliderFloatBinding:
					norm = (v.val^ - v.min) / (v.max - v.min)
				case SliderParamBinding:
					inst := ctx.plugin.host
					if inst != nil && inst.params != nil {
						desc := param_table[v.param_idx]
						norm = f32(b.param_to_normalized(inst.params.values[v.param_idx], desc))
					}
				}
				sliderY := norm * trackRange

				thumbColor := ctx.theme.sliderColor
				if d.id == ctx.activeId do thumbColor = ctx.theme.sliderActiveColor
				else if d.id == ctx.hoveredId do thumbColor = ctx.theme.sliderHoverColor

				// Rail background
				draw_push_rect(ctx.plugin.draw, SimpleUIRect {
					x = bounds.x + (bounds.w / 2) - (slider_rail_width / 2),
					y = bounds.y + thumbR,
					width = slider_rail_width,
					height = trackRange,
					color = ctx.theme.sliderTrackColor,
					cornerRad = 2,
					borderColor = ctx.theme.borderColor,
					borderWidth = 0.8,
				})

				// Enabled part of the rail
				draw_push_rect(ctx.plugin.draw, SimpleUIRect {
					x = bounds.x + (bounds.w / 2) - (slider_rail_width / 2),
					y = bounds.y + thumbR + (trackRange - sliderY),
					width = slider_rail_width,
					height = sliderY,
					color = ctx.theme.sliderColor,
					cornerRad = 2,
				})

				// Thumb circle
				draw_push_rect(ctx.plugin.draw, SimpleUIRect {
					x = bounds.x + (bounds.w / 2) - (slider_width / 2),
					y = bounds.y + (trackRange - sliderY),
					width = slider_width,
					height = slider_width,
					color = thumbColor,
					cornerRad = slider_width / 2,
					borderColor = ctx.theme.sliderActiveColor,
					borderWidth = 0.5,
				})
			}
		}
	}
}

ui_size_fit_on_axis :: proc(ctx: ^UIContext, horiz: bool) {
	comp := ctx.currentComponent
	childIter := ui_iterate_children(comp)
	sizing_along_axis := (comp.direction == .HORIZONTAL) == horiz
	size: f32
	child_count: int

	for c in ui_next_child(&childIter) {
		child_count += 1
		child_sizing := c.sizingHoriz if horiz else c.sizingVert
		// GROW children contribute their min to FIT calculation
		child_size := child_sizing.min if child_sizing.type == .GROW else (c.calcBounds.w if horiz else c.calcBounds.h)
		if sizing_along_axis {
			size += child_size
		} else {
			size = math.max(size, child_size)
		}
	}

	if sizing_along_axis && child_count > 1 {
		size += comp.child_gaps * f32(child_count - 1)
	}
	size += 2 * (horiz ? comp.sizingHoriz.padding : comp.sizingVert.padding)

	// Clamp to FIT min/max
	fit_sizing := comp.sizingHoriz if horiz else comp.sizingVert
	if fit_sizing.max > 0 do size = math.min(size, fit_sizing.max)
	if fit_sizing.min > 0 do size = math.max(size, fit_sizing.min)

	if horiz {
		comp.calcBounds.w = size
	} else {
		comp.calcBounds.h = size
	}
}

ui_component_lastchild :: proc(node: ^Component) -> ^Component {
	node := node
	for node.firstChild != nil do node = node.firstChild
	return node
}

ui_iterate_children :: proc(comp: ^Component) -> ComponentIterator {
	return ComponentIterator{comp.firstChild}
}

ui_next_child :: proc(iter: ^ComponentIterator) -> (next: ^Component, cont: bool) {
	currentNode := iter.current
	if currentNode == nil do return nil, false
	iter.current = iter.current.nextSibling
	return currentNode, true
}

ui_iterate_pre_order :: proc(ctx: ^UIContext) -> ComponentIterator {
	return ComponentIterator{ctx.root}
}

ui_next_pre_order :: proc(iter: ^ComponentIterator) -> (next: ^Component, cont: bool) {
	currentNode := iter.current
	if currentNode == nil do return nil, false

	if currentNode.firstChild != nil {
		iter.current = currentNode.firstChild
	} else {
		walkUp := currentNode
		for walkUp != nil {
			if walkUp.nextSibling != nil {
				iter.current = walkUp.nextSibling
				return currentNode, true
			}
			walkUp = walkUp.parent
		}
		iter.current = nil
	}

	return currentNode, true
}

ui_iterate_post_order :: proc(ctx: ^UIContext) -> ComponentIterator {
	return ComponentIterator{ui_component_lastchild(ctx.root)}
}

ui_next_post_order :: proc(iter: ^ComponentIterator) -> (next: ^Component, cont: bool) {
	currentNode := iter.current
	if currentNode == nil do return nil, false

	if currentNode.nextSibling != nil {
		iter.current = ui_component_lastchild(iter.current.nextSibling)
	} else {
		iter.current = currentNode.parent
	}

	return currentNode, true
}

// Layout tests

@(private = "file")
test_init_ctx :: proc(ctx: ^UIContext) {
	ctx.componentCount = 0
	ctx.root = ui_alloc_component(ctx)
	ctx.root^ = Component{}
	ctx.root.calcBounds = {0, 0, 400, 300}
	ctx.currentComponent = ctx.root
}

@(private = "file")
test_open_comp :: proc(ctx: ^UIContext, sizingH, sizingV: AxisSizing, dir: LayoutDirection = .HORIZONTAL, child_gaps: f32 = 0) -> ^Component {
	comp := ui_open_component(ctx)
	comp.sizingHoriz = sizingH
	comp.sizingVert = sizingV
	comp.direction = dir
	comp.child_gaps = child_gaps
	return comp
}

@(private = "file")
test_close_comp :: proc(ctx: ^UIContext) {
	ui_close_component(ctx)
}

@(private = "file")
test_leaf :: proc(ctx: ^UIContext, sizingH, sizingV: AxisSizing) -> ^Component {
	comp := test_open_comp(ctx, sizingH, sizingV)
	test_close_comp(ctx)
	return comp
}

@(private = "file")
approx :: proc(a, b: f32, eps: f32 = 0.01) -> bool {
	return math.abs(a - b) < eps
}

@(test)
test_fixed_children_horizontal :: proc(t: ^testing.T) {
	// Two fixed-size children in a horizontal parent
	ctx: UIContext
	test_init_ctx(&ctx)
	parent := test_open_comp(&ctx, {type = .FIT}, {type = .FIT}, .HORIZONTAL, child_gaps = 10)
	a := test_leaf(&ctx, {type = .FIXED, value = 100}, {type = .FIXED, value = 50})
	b := test_leaf(&ctx, {type = .FIXED, value = 80}, {type = .FIXED, value = 50})
	test_close_comp(&ctx)

	ui_size_grow_components(&ctx)
	ui_position_components(&ctx)

	// FIT parent should wrap children: 100 + 10 gap + 80 = 190
	testing.expect(t, approx(parent.calcBounds.w, 190), "parent width")
	testing.expect(t, approx(parent.calcBounds.h, 50), "parent height")

	// Children positioned left to right
	testing.expect(t, approx(a.calcBounds.x, 0), "a.x")
	testing.expect(t, approx(b.calcBounds.x, 110), "b.x") // 100 + 10 gap
}

@(test)
test_grow_fills_parent :: proc(t: ^testing.T) {
	// One GROW child should fill the parent
	ctx: UIContext
	test_init_ctx(&ctx)
	child := test_leaf(&ctx, {type = .GROW}, {type = .GROW})

	ui_size_grow_components(&ctx)
	ui_position_components(&ctx)

	testing.expect(t, approx(child.calcBounds.w, 400), "child width")
	testing.expect(t, approx(child.calcBounds.h, 300), "child height")
}

@(test)
test_grow_distributes_evenly :: proc(t: ^testing.T) {
	// Two GROW children split parent evenly
	ctx: UIContext
	test_init_ctx(&ctx)
	ctx.root.direction = .HORIZONTAL
	a := test_leaf(&ctx, {type = .GROW}, {type = .FIXED, value = 50})
	b := test_leaf(&ctx, {type = .GROW}, {type = .FIXED, value = 50})

	ui_size_grow_components(&ctx)
	ui_position_components(&ctx)

	testing.expect(t, approx(a.calcBounds.w, 200), "a width")
	testing.expect(t, approx(b.calcBounds.w, 200), "b width")
	testing.expect(t, approx(a.calcBounds.x, 0), "a.x")
	testing.expect(t, approx(b.calcBounds.x, 200), "b.x")
}

@(test)
test_grow_with_fixed_sibling :: proc(t: ^testing.T) {
	// Fixed child + GROW child, GROW takes remaining space
	ctx: UIContext
	test_init_ctx(&ctx)
	ctx.root.direction = .HORIZONTAL
	ctx.root.child_gaps = 10
	fixed := test_leaf(&ctx, {type = .FIXED, value = 100}, {type = .FIXED, value = 50})
	grow := test_leaf(&ctx, {type = .GROW}, {type = .FIXED, value = 50})

	ui_size_grow_components(&ctx)
	ui_position_components(&ctx)

	// 400 - 100 fixed - 10 gap = 290
	testing.expect(t, approx(fixed.calcBounds.w, 100), "fixed width")
	testing.expect(t, approx(grow.calcBounds.w, 290), "grow width")
}

@(test)
test_padding :: proc(t: ^testing.T) {
	// Parent with padding, child positioned inset
	ctx: UIContext
	test_init_ctx(&ctx)
	parent := test_open_comp(&ctx,
		{type = .FIT, padding = 15},
		{type = .FIT, padding = 15},
		.HORIZONTAL)
	child := test_leaf(&ctx, {type = .FIXED, value = 100}, {type = .FIXED, value = 50})
	test_close_comp(&ctx)

	ui_size_grow_components(&ctx)
	ui_position_components(&ctx)

	// FIT + padding: 100 + 30 = 130
	testing.expect(t, approx(parent.calcBounds.w, 130), "parent width with padding")
	testing.expect(t, approx(parent.calcBounds.h, 80), "parent height with padding")
	// Child offset by padding
	testing.expect(t, approx(child.calcBounds.x, parent.calcBounds.x + 15), "child x offset by padding")
	testing.expect(t, approx(child.calcBounds.y, parent.calcBounds.y + 15), "child y offset by padding")
}

@(test)
test_vertical_layout :: proc(t: ^testing.T) {
	ctx: UIContext
	test_init_ctx(&ctx)
	ctx.root.direction = .VERTICAL
	ctx.root.child_gaps = 5
	a := test_leaf(&ctx, {type = .FIXED, value = 100}, {type = .FIXED, value = 30})
	b := test_leaf(&ctx, {type = .FIXED, value = 100}, {type = .FIXED, value = 40})

	ui_size_grow_components(&ctx)
	ui_position_components(&ctx)

	testing.expect(t, approx(a.calcBounds.y, 0), "a.y")
	testing.expect(t, approx(b.calcBounds.y, 35), "b.y") // 30 + 5 gap
}

@(test)
test_grow_min_max_clamp :: proc(t: ^testing.T) {
	// GROW with min/max clamping
	ctx: UIContext
	test_init_ctx(&ctx)
	ctx.root.direction = .HORIZONTAL
	child := test_leaf(&ctx, {type = .GROW, min = 50, max = 150}, {type = .FIXED, value = 50})

	ui_size_grow_components(&ctx)

	// Parent is 400, but max clamps to 150
	testing.expect(t, approx(child.calcBounds.w, 150), "clamped to max")
}
