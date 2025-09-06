package lindale

MAX_LAYOUT_DEPTH :: 32

UIContext :: struct {
	plugin: ^Plugin,
	windowBounds: RectF32,

	theme: UITheme,

	hotId: u32,
	activeId: u32,
	layoutStack: [MAX_LAYOUT_DEPTH]LayoutConfig,
	layoutIdx: int,
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
