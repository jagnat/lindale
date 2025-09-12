package lindale

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
	cornerRadius = 5,
	borderWidth = 1,
}

ui_init :: proc(ctx: ^UIContext) {
	ctx.theme = DEFAULT_THEME
}

ui_begin_frame :: proc(ctx: ^UIContext) {
	ctx.mouse = ctx.plugin.mouse
	ctx.hoveredId = 0

	ctx.layoutIdx = 0
	ctx.currentLayout = {}
}

ui_end_frame :: proc(ctx: ^UIContext) {
	if ctx.mouse.buttonState[.LMB].released {
		ctx.activeId = 0
	}

	if ctx.hoveredId == 0 {
		ctx.activeId = 0
	}
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

ui_begin_panel :: proc(label: string, rect: RectF32) {
	
}