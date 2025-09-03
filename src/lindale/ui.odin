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
	sliderThumbColor: ColorU8,
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

ui_init :: proc(ctx: ^UIContext) {
	
}
