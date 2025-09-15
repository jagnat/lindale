package lindale

import "core:math/linalg"

MAX_LAYOUT_DEPTH :: 64

UIContext :: struct {
	plugin: ^Plugin,
	windowBounds: RectF32,

	theme: UITheme,
	mouse: MouseInput,

	hoveredId: u32, // If a control has the mouse over it
	activeId: u32, // If a control is actually being interacted with
	layoutStack: [MAX_LAYOUT_DEPTH]LayoutConfig,
	layoutIdx: int,
	currentLayout: LayoutConfig,
}

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

LayoutDirection :: enum {
	HORIZONTAL, // L -> R
	VERTICAL // T -> B
}

LayoutConfig :: struct {
	direction: LayoutDirection,
	innerPad: f32,
	bounds: RectF32,
	cursor: Vec2f,
}

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
	cornerRadius = 12,
	borderWidth = 1.5,
}

ui_init :: proc(ctx: ^UIContext) {
	ctx.theme = DEFAULT_THEME
}

ui_begin_frame :: proc(ctx: ^UIContext) {
	ctx.mouse = ctx.plugin.mouse
	ctx.hoveredId = 0

	frameRect := RectF32 {
		0, 0,
		f32(ctx.plugin.render.width), f32(ctx.plugin.render.height)
	}

	ctx.layoutIdx = 0
	ctx.currentLayout = LayoutConfig {
		direction = .HORIZONTAL,
		innerPad = ctx.theme.padding,
		bounds = frameRect,
		cursor = {frameRect.x + ctx.theme.padding, frameRect.y + ctx.theme.padding}
	}
}

ui_end_frame :: proc(ctx: ^UIContext) {
	if ctx.mouse.buttonState[.LMB].released {
		ctx.activeId = 0
	}

	// if ctx.hoveredId == 0 {
	// 	ctx.activeId = 0
	// }
}

ui_get_widget_rect :: proc(ctx: ^UIContext, w, h: f32) -> RectF32 {
	rect := RectF32 {
		x = ctx.currentLayout.cursor.x,
		y = ctx.currentLayout.cursor.y,
		w = w,
		h = h,
	}

	if ctx.currentLayout.direction == .HORIZONTAL {
		ctx.currentLayout.cursor.x += w + ctx.theme.itemSpacing
	} else {
		ctx.currentLayout.cursor.y += h + ctx.theme.itemSpacing
	}

	return rect
}

ui_begin_panel :: proc(ctx: ^UIContext, label: string, rect: RectF32) {
	panelRect := SimpleUIRect {
		x = rect.x, y = rect.y,
		width = rect.w, height = rect.h,
		u = 0, v = 0, uw = 0, vh = 0,
		color = ctx.theme.panelBgColor,
		cornerRad = ctx.theme.cornerRadius,
		borderColor = ctx.theme.borderColor,
		borderWidth = ctx.theme.borderWidth
	}
	draw_push_rect(ctx.plugin.draw, panelRect)

	newLayout := LayoutConfig{
		direction = .HORIZONTAL,
		innerPad = ctx.theme.padding,
		bounds = rect,
		cursor = {rect.x + ctx.theme.padding, rect.y + ctx.theme.padding}
	}

	ctx.layoutStack[ctx.layoutIdx] = ctx.currentLayout
	ctx.layoutIdx += 1
	ctx.currentLayout = newLayout

	// TODO: Draw label?
	if len(label) > 0 {

	}
}

ui_end_panel :: proc(ctx: ^UIContext) {
	if ctx.layoutIdx > 0 {
		ctx.currentLayout = ctx.layoutStack[ctx.layoutIdx]
		ctx.layoutIdx -= 1
	}
}

ui_label :: proc(ctx: ^UIContext, text: string) {
	textSize := draw_measure_text(ctx.plugin.draw, text)
	rect := ui_get_widget_rect(ctx, textSize.x, textSize.y)
	rect.y += textSize.y / 2

	draw_text(ctx.plugin.draw, text, rect.x, rect.y, ctx.theme.textColor)
}

ui_button :: proc(ctx: ^UIContext, label: string) -> bool {
	id := string_hash_u32(label)
	textSize := draw_measure_text(ctx.plugin.draw, label)
	padding := ctx.theme.padding
	rect := ui_get_widget_rect(ctx, textSize.x + 2 * padding, textSize.y + 2 * padding)

	mouseOver := collide_vec2_rect(ctx.mouse.pos, rect)

	if mouseOver {
		ctx.hoveredId = id
	}

	clicked := false

	color := ctx.theme.buttonColor

	// TODO: Update colors
	if id == ctx.activeId {
		color = ctx.theme.buttonActiveColor
		if ctx.mouse.buttonState[.LMB].released {
			clicked = mouseOver
		}
	} else if id == ctx.hoveredId {
		color = ctx.theme.buttonHoverColor
		if ctx.mouse.buttonState[.LMB].pressed {
			ctx.activeId = id
		}
	}

	buttonRect := SimpleUIRect{
		x = rect.x, y = rect.y,
		width = rect.w, height = rect.h,
		u = 0, v = 0, uw = 0, vh = 0,
		color = color,
		cornerRad = ctx.theme.cornerRadius,
		borderColor = ctx.theme.borderColor,
		borderWidth = ctx.theme.borderWidth,
	}
	draw_push_rect(ctx.plugin.draw, buttonRect)

	textX := rect.x + (rect.w - textSize.x) * 0.5
	textY := rect.y + (rect.h - textSize.y) * 0.5
	draw_text(ctx.plugin.draw, label, textX, textY, ctx.theme.textColor)

	return clicked
}

ui_slider_v :: proc(ctx: ^UIContext, label: string, val: ^f32, min, max: f32, height: f32 = 100) {
	slider_width :: 20
	slider_rail_width :: 4

	id := string_hash_u32(label)
	padding := ctx.theme.padding
	sliderP := (val^ - min) / (max - min)
	sliderY := sliderP * height
	boundsRect := ui_get_widget_rect(ctx, slider_width, height)
	nodeRect := RectF32 {boundsRect.x, 0, slider_width, slider_width}
	nodeRect.y = boundsRect.y + (height - sliderY - slider_width / 2)
	mouseOver := collide_vec2_rect(ctx.mouse.pos, boundsRect)
	mouseOverNode := collide_vec2_rect(ctx.mouse.pos, nodeRect)

	if mouseOver {
		ctx.hoveredId = id
	}

	nodeColor := ctx.theme.sliderColor

	if id == ctx.activeId {
		nodeColor = ctx.theme.sliderActiveColor
		mouseP := ctx.mouse.pos.y
		if mouseP < boundsRect.y do mouseP = boundsRect.y
		if mouseP > boundsRect.y + boundsRect.h do mouseP = boundsRect.y + boundsRect.h
		mouseP = (height - (mouseP - boundsRect.y)) / height
		val^ = linalg.lerp(min, max, mouseP)
	} else if id == ctx.hoveredId {
		if mouseOverNode {
			nodeColor = ctx.theme.sliderHoverColor
		}
		if ctx.mouse.buttonState[.LMB].pressed {
			ctx.activeId = id
		}
	}

	// Draw full rail
	railRect := SimpleUIRect {
		x = boundsRect.x + (boundsRect.w / 2) - (slider_rail_width / 2),
		y = boundsRect.y,
		width = slider_rail_width,
		height = height,
		u = 0, v = 0, uw = 0, vh = 0,
		color = ctx.theme.sliderTrackColor,
		cornerRad = 2,
		borderColor = ctx.theme.borderColor,
		borderWidth = 0.8,
	}
	draw_push_rect(ctx.plugin.draw, railRect)

	// Rail up to slider node
	enabledRailRect := SimpleUIRect {
		x = boundsRect.x + (boundsRect.w / 2) - (slider_rail_width / 2),
		y = boundsRect.y + (height - sliderY),
		width = slider_rail_width,
		height = sliderY,
		u = 0, v = 0, uw = 0, vh = 0,
		color = ctx.theme.sliderColor,
		cornerRad = 2,
	}
	draw_push_rect(ctx.plugin.draw, enabledRailRect)

	// Slider thumb rect
	thumbRect := SimpleUIRect {
		x = boundsRect.x + (boundsRect.w / 2) - (slider_width / 2),
		y = boundsRect.y + (height - sliderY) - (slider_width / 2),
		width = slider_width,
		height = slider_width,
		u = 0, v = 0, uw = 0, vh = 0,
		color = nodeColor,
		cornerRad = slider_width / 2,
		borderColor = ctx.theme.sliderActiveColor,
		borderWidth = 0.5,
	}
	draw_push_rect(ctx.plugin.draw, thumbRect)
}
