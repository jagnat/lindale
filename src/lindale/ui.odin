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

	toggleOnColor: ColorU8,
	toggleOffColor: ColorU8,
	toggleThumbColor: ColorU8,

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

knob_size            :: 64
knob_arc_thickness   :: 5
knob_track_thickness :: 3
knob_indicator_inset :: 2
knob_endcap_radius   :: 4
knob_start_angle     :: f32(3 * math.PI / 4)
knob_sweep_angle     :: f32(3 * math.PI / 2)
knob_drag_pixels     :: f32(200)

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
	toggleOnColor = {0x4c, 0x87, 0xc8, 0xff},
	toggleOffColor = {0x61, 0x66, 0x69, 0xff},
	toggleThumbColor = {0xff, 0xff, 0xff, 0xff},
	textColor = {0xff, 0xff, 0xff, 0xff},
	borderColor = {0x61, 0x63, 0x65, 0xff},

	padding = 10,
	itemSpacing = 10,
	cornerRadius = 10,
	borderWidth = 1.5,
}

THEME_JQ : UITheme : {
	bgColor = {0x1b, 0x1c, 0x19, 0xff},
	panelBgColor = {0x1b, 0x1c, 0x19, 0xff},
	buttonColor = {0x4e, 0x50, 0x52, 0xff},
	buttonHoverColor = {0x55, 0x58, 0x5a, 0xff},
	buttonActiveColor = {0x5d, 0x5f, 0x62, 0xff},
	sliderTrackColor = {0xcc, 0xc5, 0xb9, 0xff},
	sliderColor = {0x8d, 0xb3, 0x67, 0xff},
	sliderHoverColor = {0x9a, 0xbe, 0x6f, 0xff},
	sliderActiveColor = {0xb2, 0xd9, 0x8c, 0xff},
	toggleOnColor = {0x57, 0x72, 0x77, 0xff},
	toggleOffColor = {0x40, 0x35, 0x44, 0xff},
	toggleThumbColor = {0xeb, 0xed, 0xe9, 0xff},
	textColor = {0xe9, 0xe6, 0xde, 0xff},
	borderColor = {0xe9, 0xe6, 0xde, 0xff},

	padding = 10,
	itemSpacing = 10,
	cornerRadius = 10,
	borderWidth = 1.2,
}

LayoutDirection :: enum { VERTICAL, HORIZONTAL, }
SliderOrientation :: enum { VERTICAL, HORIZONTAL }

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
	SLIDER,
	TOGGLE,
	KNOB,
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

SliderData :: struct {
	label: string,
	id: u32,
	orientation: SliderOrientation,
	binding: union {
		SliderFloatBinding,
		SliderParamBinding,
	},
}

ToggleBoolBinding :: struct {
	val: ^bool,
}

ToggleParamBinding :: struct {
	param_idx: ParamIndex,
}

ToggleData :: struct {
	label: string,
	id: u32,
	t: f32, // reserved for future animation (0 = off, 1 = on)
	binding: union {
		ToggleBoolBinding,
		ToggleParamBinding,
	},
}

KnobFloatBinding :: struct {
	val: ^f32,
	min, max: f32,
}

KnobParamBinding :: struct {
	param_idx: ParamIndex,
}

KnobData :: struct {
	label: string,
	id: u32,
	binding: union {
		KnobFloatBinding,
		KnobParamBinding,
	},
}

ComponentData :: union {
	PanelData,
	LabelData,
	ButtonData,
	SliderData,
	ToggleData,
	KnobData,
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
	dragAnchorMouseY: f32,
	dragAnchorNorm: f32,
	mouse: MouseState,
	theme: UITheme,

	plugin: ^PluginController
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

ui_label :: proc(ctx: ^UIContext, text: string, alignX: AlignX = .LEFT, minWidth: f32 = 0) {
	comp := ui_open_component(ctx)
	comp.type = .LABEL
	comp.alignX = alignX
	textSize := draw_measure_text(ctx.plugin.draw, text)
	comp.sizingHoriz = {type = .FIXED, value = math.max(textSize.x, minWidth)}
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
	comp.type = .SLIDER
	comp.alignX = alignX
	comp.sizingHoriz = {type = .FIXED, value = slider_width}
	comp.sizingVert = {type = .GROW, value = 200, min = 200, max = 500}
	comp.data = SliderData{label, id, .VERTICAL, SliderFloatBinding{val, min, max}}
	ui_close_component(ctx)
}

ui_slider_h :: proc(ctx: ^UIContext, label: string, val: ^f32, min, max: f32, alignY: AlignY = .CENTER) {
	id := string_hash_u32(label)
	comp := ui_open_component(ctx)
	comp.type = .SLIDER
	comp.alignY = alignY
	comp.sizingHoriz = {type = .GROW, min = 100, max = 500}
	comp.sizingVert = {type = .FIXED, value = slider_width}
	comp.data = SliderData{label, id, .HORIZONTAL, SliderFloatBinding{val, min, max}}
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

ui_slider_param :: proc(ctx: ^UIContext, label: string, param_idx: ParamIndex, orientation: SliderOrientation = .VERTICAL, alignX: AlignX = .CENTER) {
	id := string_hash_u32(label)
	comp := ui_open_component(ctx)
	comp.type = .SLIDER
	if orientation == .VERTICAL {
		comp.alignX = alignX
		comp.sizingHoriz = {type = .FIXED, value = slider_width}
		comp.sizingVert = {type = .GROW, value = 200, min = 200, max = 500}
	} else {
		comp.sizingHoriz = {type = .GROW, min = 100, max = 500}
		comp.sizingVert = {type = .FIXED, value = slider_width}
	}
	comp.data = SliderData{label, id, orientation, SliderParamBinding{param_idx}}
	ui_close_component(ctx)
}

ui_slider_param_labeled :: proc(ctx: ^UIContext, label: string, param_idx: ParamIndex, enum_to_string: proc(val: f64) -> string = nil) {
	comp := ui_open_component(ctx)
	comp.data = PanelData{skipDraw = true}
	comp.direction = .VERTICAL
	comp.child_gaps = 5
	comp.sizingHoriz = {type = .FIT}
	comp.sizingVert = {type = .GROW}
	maxValWidth := ui_slider_param_max_value_width(ctx, param_idx, enum_to_string)
	paramBuf := make([]byte, 40, allocator = ctx.plugin.host.frame_allocator)
	str := b.param_format_value_with_unit(ctx.plugin.host.params.values[param_idx], param_table[param_idx], paramBuf, enum_to_string)
	ui_label(ctx, str, alignX = .CENTER, minWidth = maxValWidth)
	ui_slider_param(ctx, label, param_idx, alignX = .CENTER)
	ui_label(ctx, label, alignX = .CENTER)
	ui_close_component(ctx)
}

// Returns the width of the widest possible formatted value string for a parameter.
// Used to pre-size value labels so they don't change width as the value changes.
ui_slider_param_max_value_width :: proc(ctx: ^UIContext, param_idx: ParamIndex, enum_to_string: proc(val: f64) -> string = nil) -> f32 {
	desc := param_table[param_idx]
	buf := make([]byte, 40, allocator = ctx.plugin.host.frame_allocator)
	maxWidth: f32 = 0

	if .List in desc.flags && enum_to_string != nil {
		for i in 0..=desc.step_count {
			norm := f64(i) / f64(desc.step_count) if desc.step_count > 0 else 0
			val := b.normalized_to_param(norm, desc)
			str := b.param_format_value_with_unit(val, desc, buf, enum_to_string)
			w := draw_measure_text(ctx.plugin.draw, str).x
			maxWidth = math.max(maxWidth, w)
		}
	} else {
		str := b.param_format_value_with_unit(desc.min, desc, buf, nil)
		maxWidth = math.max(maxWidth, draw_measure_text(ctx.plugin.draw, str).x)
		str = b.param_format_value_with_unit(desc.max, desc, buf, nil)
		maxWidth = math.max(maxWidth, draw_measure_text(ctx.plugin.draw, str).x)
	}
	return maxWidth
}

ui_slider_h_param_labeled :: proc(ctx: ^UIContext, label: string, param_idx: ParamIndex, enum_to_string: proc(val: f64) -> string = nil) {
	comp := ui_open_component(ctx)
	comp.data = PanelData{skipDraw = true}
	comp.direction = .HORIZONTAL
	comp.child_gaps = 5
	comp.sizingHoriz = {type = .GROW}
	comp.sizingVert = {type = .FIT}
	ui_label(ctx, label)
	ui_slider_param(ctx, label, param_idx, orientation = .HORIZONTAL)
	maxValWidth := ui_slider_param_max_value_width(ctx, param_idx, enum_to_string)
	paramBuf := make([]byte, 40, allocator = ctx.plugin.host.frame_allocator)
	str := b.param_format_value_with_unit(ctx.plugin.host.params.values[param_idx], param_table[param_idx], paramBuf, enum_to_string)
	ui_label(ctx, str, alignX = .RIGHT, minWidth = maxValWidth)
	ui_close_component(ctx)
}

ui_toggle :: proc(ctx: ^UIContext, label: string, val: ^bool) {
	id := string_hash_u32(label)
	comp := ui_open_component(ctx)
	comp.type = .TOGGLE
	comp.sizingHoriz = {type = .FIXED, value = 40}
	comp.sizingVert = {type = .FIXED, value = 22}
	comp.data = ToggleData{label = label, id = id, binding = ToggleBoolBinding{val}}
	ui_close_component(ctx)
}

ui_toggle_param :: proc(ctx: ^UIContext, label: string, param_idx: ParamIndex) {
	id := string_hash_u32(label)
	comp := ui_open_component(ctx)
	comp.type = .TOGGLE
	comp.sizingHoriz = {type = .FIXED, value = 40}
	comp.sizingVert = {type = .FIXED, value = 22}
	comp.data = ToggleData{label = label, id = id, binding = ToggleParamBinding{param_idx}}
	ui_close_component(ctx)
}

ui_toggle_labeled :: proc(ctx: ^UIContext, label: string, val: ^bool) {
	comp := ui_open_component(ctx)
	comp.data = PanelData{skipDraw = true}
	comp.direction = .HORIZONTAL
	comp.child_gaps = 6
	comp.sizingHoriz = {type = .FIT}
	comp.sizingVert = {type = .FIT}
	ui_toggle(ctx, label, val)
	ui_label(ctx, label)
	ui_close_component(ctx)
}

ui_toggle_param_labeled :: proc(ctx: ^UIContext, label: string, param_idx: ParamIndex) {
	comp := ui_open_component(ctx)
	comp.data = PanelData{skipDraw = true}
	comp.direction = .HORIZONTAL
	comp.child_gaps = 6
	comp.sizingHoriz = {type = .FIT}
	comp.sizingVert = {type = .FIT}
	ui_toggle_param(ctx, label, param_idx)
	ui_label(ctx, label)
	ui_close_component(ctx)
}

ui_knob :: proc(ctx: ^UIContext, label: string, val: ^f32, min, max: f32, alignX: AlignX = .CENTER) {
	id := string_hash_u32(label)
	comp := ui_open_component(ctx)
	comp.type = .KNOB
	comp.alignX = alignX
	comp.sizingHoriz = {type = .FIXED, value = knob_size}
	comp.sizingVert = {type = .FIXED, value = knob_size}
	comp.data = KnobData{label, id, KnobFloatBinding{val, min, max}}
	ui_close_component(ctx)
}

ui_knob_param :: proc(ctx: ^UIContext, label: string, param_idx: ParamIndex, alignX: AlignX = .CENTER) {
	id := string_hash_u32(label)
	comp := ui_open_component(ctx)
	comp.type = .KNOB
	comp.alignX = alignX
	comp.sizingHoriz = {type = .FIXED, value = knob_size}
	comp.sizingVert = {type = .FIXED, value = knob_size}
	comp.data = KnobData{label, id, KnobParamBinding{param_idx}}
	ui_close_component(ctx)
}

ui_knob_param_labeled :: proc(ctx: ^UIContext, param_idx: ParamIndex, enum_to_string: proc(val: f64) -> string = nil) {
	desc := param_table[param_idx]
	comp := ui_open_component(ctx)
	comp.data = PanelData{skipDraw = true}
	comp.direction = .VERTICAL
	comp.child_gaps = 4
	comp.sizingHoriz = {type = .FIT}
	comp.sizingVert = {type = .FIT}
	maxValWidth := ui_slider_param_max_value_width(ctx, param_idx, enum_to_string)
	valBuf := make([]byte, 40, allocator = ctx.plugin.host.frame_allocator)
	valStr := b.param_format_value_with_unit(ctx.plugin.host.params.values[param_idx], desc, valBuf, enum_to_string)
	ui_label(ctx, desc.name, alignX = .CENTER)
	ui_knob_param(ctx, desc.name, param_idx)
	ui_label(ctx, valStr, alignX = .CENTER, minWidth = maxValWidth)
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
	ctx.theme = THEME_JQ
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
			case .SLIDER: {
				d := c.data.(SliderData) or_continue
				mouseOver := collide_vec2_rect(ctx.mouse.pos, c.calcBounds)
				if mouseOver do ctx.hoveredId = d.id
				if d.id == ctx.activeId {
					thumbR := f32(slider_width) / 2
					norm: f32
					if d.orientation == .VERTICAL {
						trackRange := c.calcBounds.h - f32(slider_width)
						mouseP := clamp(ctx.mouse.pos.y, c.calcBounds.y + thumbR, c.calcBounds.y + c.calcBounds.h - thumbR)
						norm = clamp(1.0 - (mouseP - c.calcBounds.y - thumbR) / trackRange, 0, 1)
					} else {
						trackRange := c.calcBounds.w - f32(slider_width)
						mouseP := clamp(ctx.mouse.pos.x, c.calcBounds.x + thumbR, c.calcBounds.x + c.calcBounds.w - thumbR)
						norm = clamp((mouseP - c.calcBounds.x - thumbR) / trackRange, 0, 1)
					}

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
			case .TOGGLE: {
				d := c.data.(ToggleData) or_continue
				mouseOver := collide_vec2_rect(ctx.mouse.pos, c.calcBounds)
				if mouseOver do ctx.hoveredId = d.id
				// Click = press + release while hovered
				if d.id == ctx.activeId {
					if .Left not_in ctx.mouse.down {
						if mouseOver {
							switch v in d.binding {
							case ToggleBoolBinding:
								v.val^ = !v.val^
							case ToggleParamBinding:
								inst := ctx.plugin.host
								if inst != nil && inst.params != nil {
									cur_norm := b.param_to_normalized(inst.params.values[v.param_idx], param_table[v.param_idx])
									new_norm := f64(0) if cur_norm >= 0.5 else f64(1)
									inst.params.values[v.param_idx] = b.normalized_to_param(new_norm, param_table[v.param_idx])
									if inst.hostApi != nil && inst.hostApi.param_edit_start != nil {
										inst.hostApi.param_edit_start(inst.hostApi.ctx, i32(v.param_idx))
									}
									if inst.hostApi != nil && inst.hostApi.param_edit_change != nil {
										inst.hostApi.param_edit_change(inst.hostApi.ctx, i32(v.param_idx), new_norm)
									}
									if inst.hostApi != nil && inst.hostApi.param_edit_end != nil {
										inst.hostApi.param_edit_end(inst.hostApi.ctx, i32(v.param_idx))
									}
								}
							}
						}
						ctx.activeId = 0
					}
				} else if d.id == ctx.hoveredId && .Left in ctx.mouse.pressed {
					ctx.activeId = d.id
				}
			}
			case .KNOB: {
				d := c.data.(KnobData) or_continue
				mouseOver := collide_vec2_rect(ctx.mouse.pos, c.calcBounds)
				if mouseOver do ctx.hoveredId = d.id
				if d.id == ctx.activeId {
					norm := clamp(ctx.dragAnchorNorm + (ctx.dragAnchorMouseY - ctx.mouse.pos.y) / knob_drag_pixels, 0, 1)

					switch v in d.binding {
						case KnobFloatBinding: {
							v.val^ = v.min + norm * (v.max - v.min)
						}
						case KnobParamBinding: {
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
						if pb, ok := d.binding.(KnobParamBinding); ok {
							inst := ctx.plugin.host
							if inst != nil && inst.hostApi != nil && inst.hostApi.param_edit_end != nil {
								inst.hostApi.param_edit_end(inst.hostApi.ctx, i32(pb.param_idx))
							}
						}
						ctx.activeId = 0
					}
				} else if d.id == ctx.hoveredId && .Left in ctx.mouse.pressed {
					ctx.activeId = d.id
					curNorm: f32
					switch v in d.binding {
					case KnobFloatBinding:
						curNorm = clamp((v.val^ - v.min) / (v.max - v.min), 0, 1)
					case KnobParamBinding:
						inst := ctx.plugin.host
						if inst != nil && inst.params != nil {
							curNorm = f32(b.param_to_normalized(inst.params.values[v.param_idx], param_table[v.param_idx]))
						}
						if inst != nil && inst.hostApi != nil && inst.hostApi.param_edit_start != nil {
							inst.hostApi.param_edit_start(inst.hostApi.ctx, i32(v.param_idx))
						}
					}
					ctx.dragAnchorMouseY = ctx.mouse.pos.y
					ctx.dragAnchorNorm = curNorm
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
				textSize := draw_measure_text(ctx.plugin.draw, d.text)
				textX := c.calcBounds.x
				switch c.alignX {
				case .LEFT:
				case .CENTER: textX = c.calcBounds.x + (c.calcBounds.w - textSize.x) * 0.5
				case .RIGHT:  textX = c.calcBounds.x + c.calcBounds.w - textSize.x
				}
				draw_text(ctx.plugin.draw, d.text, textX, c.calcBounds.y, ctx.theme.textColor)
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
			case .SLIDER: {
				bounds := c.calcBounds
				d := c.data.(SliderData) or_continue
				thumbR := f32(slider_width) / 2

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

				thumbColor := ctx.theme.sliderColor
				if d.id == ctx.activeId do thumbColor = ctx.theme.sliderActiveColor
				else if d.id == ctx.hoveredId do thumbColor = ctx.theme.sliderHoverColor

				if d.orientation == .VERTICAL {
					trackRange := bounds.h - f32(slider_width)
					sliderY := norm * trackRange

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
					// Filled portion
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
				} else {
					trackRange := bounds.w - f32(slider_width)
					sliderX := norm * trackRange

					// Rail background
					draw_push_rect(ctx.plugin.draw, SimpleUIRect {
						x = bounds.x + thumbR,
						y = bounds.y + (bounds.h / 2) - (slider_rail_width / 2),
						width = trackRange,
						height = slider_rail_width,
						color = ctx.theme.sliderTrackColor,
						cornerRad = 2,
						borderColor = ctx.theme.borderColor,
						borderWidth = 0.8,
					})
					// Filled portion
					draw_push_rect(ctx.plugin.draw, SimpleUIRect {
						x = bounds.x + thumbR,
						y = bounds.y + (bounds.h / 2) - (slider_rail_width / 2),
						width = sliderX,
						height = slider_rail_width,
						color = ctx.theme.sliderColor,
						cornerRad = 2,
					})
					// Thumb circle
					draw_push_rect(ctx.plugin.draw, SimpleUIRect {
						x = bounds.x + sliderX,
						y = bounds.y + (bounds.h / 2) - (slider_width / 2),
						width = slider_width,
						height = slider_width,
						color = thumbColor,
						cornerRad = slider_width / 2,
						borderColor = ctx.theme.sliderActiveColor,
						borderWidth = 0.5,
					})
				}
			}
			case .TOGGLE: {
				bounds := c.calcBounds
				d := c.data.(ToggleData) or_continue

				on: bool
				switch v in d.binding {
				case ToggleBoolBinding:
					on = v.val^
				case ToggleParamBinding:
					inst := ctx.plugin.host
					if inst != nil && inst.params != nil {
						on = b.param_to_normalized(inst.params.values[v.param_idx], param_table[v.param_idx]) >= 0.5
					}
				}

				bgColor := ctx.theme.toggleOnColor if on else ctx.theme.toggleOffColor
				pillRad := bounds.h / 2
				// Pill background
				draw_push_rect(ctx.plugin.draw, SimpleUIRect {
					x = bounds.x, y = bounds.y,
					width = bounds.w, height = bounds.h,
					color = bgColor,
					cornerRad = pillRad,
				})
				// Thumb circle
				margin: f32 = 3
				thumbR := pillRad - margin
				thumbX := bounds.x + margin + thumbR + (bounds.w - bounds.h) * (f32(1) if on else f32(0))
				thumbY := bounds.y + pillRad
				draw_circle(ctx.plugin.draw, thumbX, thumbY, thumbR, ctx.theme.toggleThumbColor)
			}
			case .KNOB: {
				bounds := c.calcBounds
				d := c.data.(KnobData) or_continue

				norm: f32
				switch v in d.binding {
				case KnobFloatBinding:
					norm = clamp((v.val^ - v.min) / (v.max - v.min), 0, 1)
				case KnobParamBinding:
					inst := ctx.plugin.host
					if inst != nil && inst.params != nil {
						desc := param_table[v.param_idx]
						norm = f32(b.param_to_normalized(inst.params.values[v.param_idx], desc))
					}
				}

				arcColor := ctx.theme.sliderColor
				if d.id == ctx.activeId do arcColor = ctx.theme.sliderActiveColor
				else if d.id == ctx.hoveredId do arcColor = ctx.theme.sliderHoverColor

				center := Vec2f{bounds.x + bounds.w * 0.5, bounds.y + bounds.h * 0.5}
				radius := math.min(bounds.w, bounds.h) * 0.5 - knob_arc_thickness

				// Track arc (full sweep)
				draw_push_arc(ctx.plugin.draw, center, radius,
					knob_start_angle, knob_start_angle + knob_sweep_angle,
					knob_track_thickness, ctx.theme.sliderTrackColor)

				end_fill := knob_start_angle + norm * knob_sweep_angle
				if norm > 0.001 {
					draw_push_arc(ctx.plugin.draw, center, radius,
						knob_start_angle, end_fill,
						knob_arc_thickness, arcColor)
				}

				// Indicator line + end-cap dot at the current angle
				dir := Vec2f{math.cos(end_fill), math.sin(end_fill)}
				inner := Vec2f{center.x + dir.x * knob_indicator_inset, center.y + dir.y * knob_indicator_inset}
				outer := Vec2f{center.x + dir.x * (radius - knob_arc_thickness - 4), center.y + dir.y * (radius - knob_arc_thickness - 4)}
				draw_push_pill(ctx.plugin.draw, inner, outer, knob_track_thickness, arcColor)

				endCap := Vec2f{center.x + dir.x * radius, center.y + dir.y * radius}
				draw_circle(ctx.plugin.draw, endCap.x, endCap.y, knob_endcap_radius, arcColor)
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
