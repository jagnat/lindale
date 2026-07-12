package sdk

import "core:math"
import "core:log"
import "core:testing"
import b "../bridge"

UITheme :: struct {
	bg_color: ColorU8,
	panel_bg_color: ColorU8,

	button_color: ColorU8,
	button_hover_color: ColorU8,
	button_active_color: ColorU8,

	slider_track_color: ColorU8,
	slider_color: ColorU8,
	slider_hover_color: ColorU8,
	slider_active_color: ColorU8,

	toggle_on_color: ColorU8,
	toggle_off_color: ColorU8,
	toggle_thumb_color: ColorU8,

	text_color: ColorU8,

	border_color: ColorU8,
	panel_border_color: ColorU8,

	padding: f32,
	item_spacing: f32,
	corner_radius: f32,
	border_width: f32,
	font_size: f32,
	panel_border_width: f32,

	slider_width: f32,
	slider_rail_width: f32,
	slider_rail_border_width: f32,
	slider_thumb_border_width: f32,

	knob_size: f32,
	knob_arc_thickness: f32,
	knob_track_thickness: f32,
	knob_indicator_inset: f32,
	knob_start_angle: f32,
	knob_sweep_angle: f32,
	knob_drag_pixels: f32,

	toggle_width: f32,
	toggle_height: f32,
	toggle_thumb_margin: f32,
}

DEFAULT_THEME : UITheme : {
	bg_color = {0x3c, 0x3f, 0x41, 0xff},
	panel_bg_color = {0x3c, 0x3f, 0x41, 0xff},
	button_color = {0x4e, 0x50, 0x52, 0xff},
	button_hover_color = {0x55, 0x58, 0x5a, 0xff},
	button_active_color = {0x5d, 0x5f, 0x62, 0xff},
	slider_track_color = {0x61, 0x66, 0x69, 0xff},
	slider_color = {0x4c, 0x87, 0xc8, 0xff},
	slider_hover_color = {0x60, 0x94, 0xce, 0xff},
	slider_active_color = {0x6b, 0x9c, 0xd2, 0xff},
	toggle_on_color = {0x4c, 0x87, 0xc8, 0xff},
	toggle_off_color = {0x61, 0x66, 0x69, 0xff},
	toggle_thumb_color = {0xff, 0xff, 0xff, 0xff},
	text_color = {0xff, 0xff, 0xff, 0xff},
	border_color = {0x61, 0x63, 0x65, 0xff},
	panel_border_color = {0xff, 0xff, 0xff, 0xff},

	padding = 10,
	item_spacing = 10,
	corner_radius = 10,
	border_width = 1.5,
	font_size = FONT_SIZE_DEFAULT,
	panel_border_width = 0.4,

	slider_width = 20,
	slider_rail_width = 4,
	slider_rail_border_width = 0.8,
	slider_thumb_border_width = 0.5,

	knob_size = 64,
	knob_arc_thickness = 5,
	knob_track_thickness = 3,
	knob_indicator_inset = 2,
	knob_start_angle = f32(3 * math.PI / 4),
	knob_sweep_angle = f32(3 * math.PI / 2),
	knob_drag_pixels = 200,

	toggle_width = 40,
	toggle_height = 22,
	toggle_thumb_margin = 3,
}

THEME_JQ : UITheme : {
	bg_color = {0x1b, 0x1c, 0x19, 0xff},
	panel_bg_color = {0x1b, 0x1c, 0x19, 0xff},
	button_color = {0x4e, 0x50, 0x52, 0xff},
	button_hover_color = {0x55, 0x58, 0x5a, 0xff},
	button_active_color = {0x5d, 0x5f, 0x62, 0xff},
	slider_track_color = {0xcc, 0xc5, 0xb9, 0xff},
	slider_color = {0x8d, 0xb3, 0x67, 0xff},
	slider_hover_color = {0x9a, 0xbe, 0x6f, 0xff},
	slider_active_color = {0xb2, 0xd9, 0x8c, 0xff},
	toggle_on_color = {0x57, 0x72, 0x77, 0xff},
	toggle_off_color = {0x40, 0x35, 0x44, 0xff},
	toggle_thumb_color = {0xeb, 0xed, 0xe9, 0xff},
	text_color = {0xe9, 0xe6, 0xde, 0xff},
	border_color = {0xe9, 0xe6, 0xde, 0xff},
	panel_border_color = {0xff, 0xff, 0xff, 0xff},

	padding = 10,
	item_spacing = 10,
	corner_radius = 10,
	border_width = 1.2,
	font_size = FONT_SIZE_DEFAULT,
	panel_border_width = 0.4,

	slider_width = 20,
	slider_rail_width = 4,
	slider_rail_border_width = 0.8,
	slider_thumb_border_width = 0.5,

	knob_size = 64,
	knob_arc_thickness = 5,
	knob_track_thickness = 3,
	knob_indicator_inset = 2,
	knob_start_angle = f32(3 * math.PI / 4),
	knob_sweep_angle = f32(3 * math.PI / 2),
	knob_drag_pixels = 200,

	toggle_width = 40,
	toggle_height = 22,
	toggle_thumb_margin = 3,
}

// Persists across frames; call any time, e.g. once in view_attached
ui_set_theme :: proc(ctx: ^UIContext, theme: UITheme) {
	ctx.theme = theme
}

LayoutDirection :: enum { Vertical, Horizontal, }
SliderOrientation :: enum { Vertical, Horizontal }

AlignX :: enum { Left, Center, Right, }
AlignY :: enum { Top, Center, Bottom, }
SizingType :: enum { Fixed, Fit, Grow, Percent }

AxisSizing :: struct {
	type: SizingType,
	value: f32, // Fixed: pixels; Percent: 0..1 fraction of parent content box
	min, max: f32, // for grow/fit/percent
	weight: f32, // grow share relative to sibling grow children, 0 means 1
	padding: f32,
}

ComponentType :: enum {
	Panel,
	Label,
	Button,
	Slider,
	Toggle,
	Knob,
	Canvas,
}

PanelData :: struct {
	skip_draw: bool,
}

LabelData :: struct {
	text: string,
	size: f32,
}

ButtonData :: struct {
	label: string,
	id: u32,
}

FloatBinding :: struct {
	val: ^f32,
	min, max: f32,
}

ParamBinding :: struct {
	param_idx: ParamIndex,
}

ValueBinding :: union {
	FloatBinding,
	ParamBinding,
}

ToggleBoolBinding :: struct {
	val: ^bool,
}

ToggleBinding :: union {
	ToggleBoolBinding,
	ParamBinding,
}

SliderData :: struct {
	id: u32,
	orientation: SliderOrientation,
	binding: ValueBinding,
}

ToggleData :: struct {
	id: u32,
	binding: ToggleBinding,
}

KnobData :: struct {
	id: u32,
	binding: ValueBinding,
}

CanvasData :: struct {
	draw_proc: proc(ctx: ^UIContext, this: ^Component, data: rawptr),
	data: rawptr
}

ComponentData :: union {
	PanelData,
	LabelData,
	ButtonData,
	SliderData,
	ToggleData,
	KnobData,
	CanvasData,
}

Component :: struct {
	type: ComponentType,
	sizing_horiz, sizing_vert: AxisSizing,

	direction: LayoutDirection,
	child_gaps: f32,
	align_x: AlignX,
	align_y: AlignY,

	// Floating components are excluded from flow layout and drawn on top.
	// Positioned against the parent content box via align_x/align_y plus float_offset
	floating: bool,
	float_offset: Vec2f,

	// w and h are calculated first, then finally x and y
	calc_bounds: RectF32,
	cursor: Vec2f, // Used for positioning pass

	parent: ^Component,
	first_child: ^Component,
	next_sibling: ^Component,

	data: ComponentData,
}

ComponentIterator :: struct {
	current: ^Component,
}

UI_MAX_COMPONENTS :: 512
UI_MAX_DEPTH :: 128
UI_MAX_ANIMS :: 128

UIAnimState :: struct {
	id: u32,
	value: f32,
	last_frame_touched: u32,
}

UIContext :: struct {
	// 'Arena'
	component_pool: [UI_MAX_COMPONENTS]Component,
	component_count: int,

	root: ^Component,
	current_component: ^Component,

	// Hit testing
	hovered_id: u32,
	active_id: u32,
	last_clicked_id: u32,
	drag_anchor_mouse_y: f32,
	drag_anchor_norm: f32,
	mouse: MouseState,
	theme: UITheme,

	// Id scoping
	id_seed_stack: [UI_MAX_DEPTH]u32,
	id_seed_count: int,

	// Retained animation state by widget ID
	anims: [UI_MAX_ANIMS]UIAnimState,
	anim_count: int,
	frame_counter: u32,

	plugin: ^PluginController
}

// Widget ids hash the label with the current scope seed, so
// duplicate labels are distinct in different scopes
ui_make_id :: proc(ctx: ^UIContext, label: string) -> u32 {
	id := string_hash_u32(label)
	if ctx.id_seed_count > 0 {
		id = (id ~ ctx.id_seed_stack[ctx.id_seed_count - 1]) * 0x01000193
	}
	return id
}

ui_push_id_raw :: proc(ctx: ^UIContext, value: u32) {
	assert(ctx.id_seed_count < UI_MAX_DEPTH)
	seed := ctx.id_seed_stack[ctx.id_seed_count - 1] if ctx.id_seed_count > 0 else 0
	ctx.id_seed_stack[ctx.id_seed_count] = (seed ~ value) * 0x01000193
	ctx.id_seed_count += 1
}

ui_push_id_string :: proc(ctx: ^UIContext, label: string) {
	ui_push_id_raw(ctx, string_hash_u32(label))
}

ui_push_id_index :: proc(ctx: ^UIContext, index: int) {
	ui_push_id_raw(ctx, u32(index) * 0x9E3779B1)
}

ui_push_id :: proc {ui_push_id_string, ui_push_id_index}

ui_pop_id :: proc(ctx: ^UIContext) {
	assert(ctx.id_seed_count > 0)
	ctx.id_seed_count -= 1
}

@(deferred_in = _ui_id_scope_end)
ui_id_scope :: proc(ctx: ^UIContext, label: string) -> bool {
	ui_push_id_string(ctx, label)
	return true
}
_ui_id_scope_end :: proc(ctx: ^UIContext, label: string) {
	ui_pop_id(ctx)
}

// Exponential approach toward target
ui_animate :: proc(ctx: ^UIContext, id: u32, target: f32, rate: f32 = 14) -> f32 {
	slot: ^UIAnimState
	for &a in ctx.anims[:ctx.anim_count] {
		if a.id == id {
			slot = &a
			break
		}
	}
	if slot == nil {
		if ctx.anim_count < UI_MAX_ANIMS {
			slot = &ctx.anims[ctx.anim_count]
			ctx.anim_count += 1
		} else {
			// Evict the least recently touched entry
			slot = &ctx.anims[0]
			for &a in ctx.anims[1:] {
				if a.last_frame_touched < slot.last_frame_touched do slot = &a
			}
		}
		slot^ = {id = id, value = target}
	}
	slot.last_frame_touched = ctx.frame_counter
	slot.value += (target - slot.value) * (1 - math.exp(-rate * ctx.plugin.frame_dt))
	return slot.value
}

@(deferred_in = ui_frame_end)
ui_frame_scoped :: proc(ctx: ^UIContext) -> bool {
	ui_frame_begin(ctx)
	return true
}

@(deferred_in = _ui_panel_close)
ui_panel :: proc(ctx: ^UIContext,
	dir: LayoutDirection = .Horizontal,
	child_gaps: f32 = 10,
	padding: f32 = 10,
	sizing_horiz: AxisSizing = {type = .Fit},
	sizing_vert: AxisSizing = {type = .Fit},
	skip_draw: bool = false,
	align_x: AlignX = .Left,
	align_y: AlignY = .Top,
	floating: bool = false,
	float_offset: Vec2f = {}) -> bool {
	comp := ui_open_component(ctx)
	comp.data = PanelData{skip_draw = skip_draw}
	comp.direction = dir
	comp.sizing_horiz = sizing_horiz
	comp.sizing_horiz.padding = padding
	comp.sizing_vert = sizing_vert
	comp.sizing_vert.padding = padding
	comp.child_gaps = child_gaps
	comp.align_x = align_x
	comp.align_y = align_y
	comp.floating = floating
	comp.float_offset = float_offset
	return true
}
_ui_panel_close :: proc(ctx: ^UIContext,
	dir: LayoutDirection = .Horizontal,
	child_gaps: f32 = 10,
	padding: f32 = 10,
	sizing_horiz: AxisSizing = {type = .Fit},
	sizing_vert: AxisSizing = {type = .Fit},
	skip_draw: bool = false,
	align_x: AlignX = .Left,
	align_y: AlignY = .Top,
	floating: bool = false,
	float_offset: Vec2f = {}) {
	ui_close_component(ctx)
}

ui_canvas :: proc(ctx: ^UIContext,
	draw_proc: proc(ctx: ^UIContext, this: ^Component, data: rawptr),
	data: rawptr,
	sizing_horiz: AxisSizing = {type = .Grow},
	sizing_vert: AxisSizing = {type = .Grow},)
{
	comp := ui_open_component(ctx)
	comp.type = .Canvas
	comp.data = CanvasData{draw_proc, data}
	comp.sizing_horiz = sizing_horiz
	comp.sizing_vert = sizing_vert
	ui_close_component(ctx)
}

ui_label :: proc(ctx: ^UIContext, text: string, align_x: AlignX = .Left, min_width: f32 = 0, size: f32 = 0) {
	comp := ui_open_component(ctx)
	comp.type = .Label
	comp.align_x = align_x
	resolved_size := size if size > 0 else ctx.theme.font_size
	text_size := draw_measure_text(ctx.plugin.draw, text, resolved_size)
	comp.sizing_horiz = {type = .Fixed, value = math.max(text_size.x, min_width)}
	comp.sizing_vert = {type = .Fixed, value = text_size.y}
	comp.data = LabelData{text = text, size = resolved_size}
	ui_close_component(ctx)
}

ui_button :: proc(ctx: ^UIContext, label: string) -> bool {
	id := ui_make_id(ctx, label)
	clicked := ctx.last_clicked_id == id
	if clicked do ctx.last_clicked_id = 0

	comp := ui_open_component(ctx)
	comp.type = .Button
	text_size := draw_measure_text(ctx.plugin.draw, label, ctx.theme.font_size)
	ascent, descent, _ := font_get_vertical_metrics(&ctx.plugin.draw.font_state, ctx.theme.font_size)
	comp.sizing_horiz = {type = .Fixed, value = text_size.x + ctx.theme.padding * 2}
	comp.sizing_vert = {type = .Fixed, value = (ascent - descent) + ctx.theme.padding * 2}
	comp.data = ButtonData{label = label, id = id}
	ui_close_component(ctx)
	return clicked
}

ui_slider :: proc(ctx: ^UIContext, label: string, binding: ValueBinding, orientation: SliderOrientation = .Vertical, align_x: AlignX = .Center, align_y: AlignY = .Center) {
	id := ui_make_id(ctx, label)
	comp := ui_open_component(ctx)
	comp.type = .Slider
	if orientation == .Vertical {
		comp.align_x = align_x
		comp.sizing_horiz = {type = .Fixed, value = ctx.theme.slider_width}
		comp.sizing_vert = {type = .Grow, value = 200, min = 200, max = 500}
	} else {
		comp.align_y = align_y
		comp.sizing_horiz = {type = .Grow, min = 100, max = 500}
		comp.sizing_vert = {type = .Fixed, value = ctx.theme.slider_width}
	}
	comp.data = SliderData{id, orientation, binding}
	ui_close_component(ctx)
}

ui_slider_param_labeled :: proc(ctx: ^UIContext, param_idx: ParamIndex, enum_to_string: proc(val: f64) -> string = nil) {
	desc := plugin_api().get_plugin_descriptor().params[param_idx]
	comp := ui_open_component(ctx)
	comp.data = PanelData{skip_draw = true}
	comp.direction = .Vertical
	comp.child_gaps = 5
	comp.sizing_horiz = {type = .Fit}
	comp.sizing_vert = {type = .Grow}
	ui_param_value_label(ctx, param_idx, enum_to_string)
	ui_slider(ctx, desc.name, ParamBinding{param_idx})
	ui_label(ctx, desc.name, align_x = .Center)
	ui_close_component(ctx)
}

ui_slider_h_param_labeled :: proc(ctx: ^UIContext, param_idx: ParamIndex, enum_to_string: proc(val: f64) -> string = nil) {
	desc := plugin_api().get_plugin_descriptor().params[param_idx]
	comp := ui_open_component(ctx)
	comp.data = PanelData{skip_draw = true}
	comp.direction = .Horizontal
	comp.child_gaps = 5
	comp.sizing_horiz = {type = .Grow}
	comp.sizing_vert = {type = .Fit}
	ui_label(ctx, desc.name)
	ui_slider(ctx, desc.name, ParamBinding{param_idx}, orientation = .Horizontal)
	ui_param_value_label(ctx, param_idx, enum_to_string, align_x = .Right)
	ui_close_component(ctx)
}

ui_toggle :: proc(ctx: ^UIContext, label: string, binding: ToggleBinding) {
	id := ui_make_id(ctx, label)
	comp := ui_open_component(ctx)
	comp.type = .Toggle
	comp.sizing_horiz = {type = .Fixed, value = ctx.theme.toggle_width}
	comp.sizing_vert = {type = .Fixed, value = ctx.theme.toggle_height}
	comp.data = ToggleData{id = id, binding = binding}
	ui_close_component(ctx)
}

ui_toggle_param_labeled :: proc(ctx: ^UIContext, param_idx: ParamIndex) {
	desc := plugin_api().get_plugin_descriptor().params[param_idx]
	comp := ui_open_component(ctx)
	comp.data = PanelData{skip_draw = true}
	comp.direction = .Horizontal
	comp.child_gaps = 6
	comp.sizing_horiz = {type = .Fit}
	comp.sizing_vert = {type = .Fit}
	ui_toggle(ctx, desc.name, ParamBinding{param_idx})
	ui_label(ctx, desc.name)
	ui_close_component(ctx)
}

ui_knob :: proc(ctx: ^UIContext, label: string, binding: ValueBinding, align_x: AlignX = .Center) {
	id := ui_make_id(ctx, label)
	comp := ui_open_component(ctx)
	comp.type = .Knob
	comp.align_x = align_x
	comp.sizing_horiz = {type = .Fixed, value = ctx.theme.knob_size}
	comp.sizing_vert = {type = .Fixed, value = ctx.theme.knob_size}
	comp.data = KnobData{id, binding}
	ui_close_component(ctx)
}

ui_knob_param_labeled :: proc(ctx: ^UIContext, param_idx: ParamIndex, enum_to_string: proc(val: f64) -> string = nil) {
	desc := plugin_api().get_plugin_descriptor().params[param_idx]
	comp := ui_open_component(ctx)
	comp.data = PanelData{skip_draw = true}
	comp.direction = .Vertical
	comp.child_gaps = 4
	comp.sizing_horiz = {type = .Fit}
	comp.sizing_vert = {type = .Fit}
	ui_label(ctx, desc.name, align_x = .Center)
	ui_knob(ctx, desc.name, ParamBinding{param_idx})
	ui_param_value_label(ctx, param_idx, enum_to_string)
	ui_close_component(ctx)
}

// Returns the width of the widest possible formatted value string for a parameter.
// Used to pre-size value labels so they don't change width as the value changes.
ui_slider_param_max_value_width :: proc(ctx: ^UIContext, param_idx: ParamIndex, enum_to_string: proc(val: f64) -> string = nil) -> f32 {
	desc := plugin_api().get_plugin_descriptor().params[param_idx]
	buf := make([]byte, 40, allocator = ctx.plugin.host.frame_allocator)
	max_width: f32 = 0

	if .List in desc.flags && enum_to_string != nil {
		for i in 0..=desc.step_count {
			norm := f64(i) / f64(desc.step_count) if desc.step_count > 0 else 0
			val := b.normalized_to_param(norm, desc)
			str := b.param_format_value_with_unit(val, desc, buf, enum_to_string)
			w := draw_measure_text(ctx.plugin.draw, str, ctx.theme.font_size).x
			max_width = math.max(max_width, w)
		}
	} else {
		str := b.param_format_value_with_unit(desc.min, desc, buf, nil)
		max_width = math.max(max_width, draw_measure_text(ctx.plugin.draw, str, ctx.theme.font_size).x)
		str = b.param_format_value_with_unit(desc.max, desc, buf, nil)
		max_width = math.max(max_width, draw_measure_text(ctx.plugin.draw, str, ctx.theme.font_size).x)
	}
	return max_width
}

@(private="file")
ui_param_value_label :: proc(ctx: ^UIContext, param_idx: ParamIndex,
                             enum_to_string: proc(val: f64) -> string = nil,
                             align_x: AlignX = .Center) {
	desc := plugin_api().get_plugin_descriptor().params[param_idx]
	max_w := ui_slider_param_max_value_width(ctx, param_idx, enum_to_string)
	buf := make([]byte, 40, allocator = ctx.plugin.host.frame_allocator)
	str := b.param_format_value_with_unit(ctx.plugin.host.params.values[param_idx], desc, buf, enum_to_string)
	ui_label(ctx, str, align_x = align_x, min_width = max_w)
}

@(private="file")
ui_param_get_normalized :: proc(ctx: ^UIContext, idx: ParamIndex) -> f32 {
	inst := ctx.plugin.host
	if inst == nil || inst.params == nil do return 0
	return f32(b.param_to_normalized(inst.params.values[idx], plugin_api().get_plugin_descriptor().params[idx]))
}

@(private="file")
ui_param_set_normalized :: proc(ctx: ^UIContext, idx: ParamIndex, norm: f32) {
	inst := ctx.plugin.host
	if inst != nil && inst.params != nil {
		inst.params.values[idx] = b.normalized_to_param(f64(norm), plugin_api().get_plugin_descriptor().params[idx])
	}
	if inst != nil && inst.host_api != nil && inst.host_api.param_edit_change != nil {
		inst.host_api.param_edit_change(inst.host_api.ctx, i32(idx), f64(norm))
	}
}

@(private="file")
ui_param_begin_edit :: proc(ctx: ^UIContext, idx: ParamIndex) {
	inst := ctx.plugin.host
	if inst != nil && inst.host_api != nil && inst.host_api.param_edit_start != nil {
		inst.host_api.param_edit_start(inst.host_api.ctx, i32(idx))
	}
}

@(private="file")
ui_param_end_edit :: proc(ctx: ^UIContext, idx: ParamIndex) {
	inst := ctx.plugin.host
	if inst != nil && inst.host_api != nil && inst.host_api.param_edit_end != nil {
		inst.host_api.param_edit_end(inst.host_api.ctx, i32(idx))
	}
}

@(private="file")
binding_get_norm :: proc(ctx: ^UIContext, binding: ValueBinding) -> f32 {
	switch v in binding {
	case FloatBinding: return clamp((v.val^ - v.min) / (v.max - v.min), 0, 1)
	case ParamBinding: return ui_param_get_normalized(ctx, v.param_idx)
	}
	return 0
}

@(private="file")
binding_set_norm :: proc(ctx: ^UIContext, binding: ValueBinding, norm: f32) {
	switch v in binding {
	case FloatBinding: v.val^ = v.min + norm * (v.max - v.min)
	case ParamBinding: ui_param_set_normalized(ctx, v.param_idx, norm)
	}
}

@(private="file")
binding_begin_edit :: proc(ctx: ^UIContext, binding: ValueBinding) {
	if pb, ok := binding.(ParamBinding); ok do ui_param_begin_edit(ctx, pb.param_idx)
}

@(private="file")
binding_end_edit :: proc(ctx: ^UIContext, binding: ValueBinding) {
	if pb, ok := binding.(ParamBinding); ok do ui_param_end_edit(ctx, pb.param_idx)
}

@(private="file")
binding_reset_to_default :: proc(ctx: ^UIContext, binding: ValueBinding) {
	if pb, ok := binding.(ParamBinding); ok {
		idx := pb.param_idx
		ui_param_begin_edit(ctx, idx)
		params := plugin_api().get_plugin_descriptor().params
		default_normalized := f32(b.param_to_normalized(params[idx].default_value, params[idx]))
		ui_param_set_normalized(ctx, pb.param_idx, default_normalized)
		ui_param_end_edit(ctx, idx)
	}
}

@(private="file")
ui_alloc_component :: proc(ctx: ^UIContext) -> ^Component {
	assert(ctx.component_count + 1 <= UI_MAX_COMPONENTS)
	comp := &ctx.component_pool[ctx.component_count]
	ctx.component_count += 1
	comp^ = {}
	return comp
}

ui_add_child_component :: proc(parent, child: ^Component) {
	if parent.first_child == nil {
		parent.first_child = child
	} else {
		last_sib := parent.first_child
		for last_sib.next_sibling != nil {
			last_sib = last_sib.next_sibling
		}
		last_sib.next_sibling = child
	}
	child.parent = parent
}

ui_open_component :: proc(ctx: ^UIContext) -> ^Component {
	comp := ui_alloc_component(ctx)
	parent := ctx.current_component
	ui_add_child_component(parent, comp)
	ctx.current_component = comp
	return comp
}

ui_close_component :: proc(ctx: ^UIContext) {
	current_comp := ctx.current_component
	#partial switch current_comp.sizing_horiz.type {
		case .Fixed: current_comp.calc_bounds.w = current_comp.sizing_horiz.value
		case .Fit: ui_size_fit_on_axis(ctx, true)
	}
	#partial switch current_comp.sizing_vert.type {
		case .Fixed: current_comp.calc_bounds.h = current_comp.sizing_vert.value
		case .Fit: ui_size_fit_on_axis(ctx, false)
	}
	ctx.current_component = current_comp.parent
}

ui_frame_begin :: proc(ctx: ^UIContext) {
	ctx.mouse = ctx.plugin.mouse
	ctx.plugin.mouse.pressed = {}
	ctx.plugin.mouse.released = {}
	ctx.plugin.mouse.double_clicked = {}
	ctx.plugin.mouse.scroll_delta = {}
	ctx.hovered_id = 0
	ctx.component_count = 0
	ctx.id_seed_count = 0
	ctx.frame_counter += 1
	ctx.root = ui_alloc_component(ctx)
	ctx.root^ = Component{}
	size := ctx.plugin.host.platform.get_size(ctx.plugin.host.renderer)
	ctx.root.calc_bounds = RectF32 {0, 0, f32(size.logical_width), f32(size.logical_height)}
	ctx.current_component = ctx.root
}

ui_frame_end :: proc(ctx: ^UIContext) {
	ui_size_grow_components(ctx)
	ui_position_components(ctx)
	ui_snap_components_to_pixels(ctx)
	ui_interact_components(ctx)
	ui_generate_draw_calls(ctx)
}

// Endpoint-round so siblings stay flush
ui_snap_components_to_pixels :: proc(ctx: ^UIContext) {
	it := ui_iterate_pre_order(ctx)
	for c in ui_next_pre_order(&it) {
		x0 := math.round(c.calc_bounds.x)
		y0 := math.round(c.calc_bounds.y)
		x1 := math.round(c.calc_bounds.x + c.calc_bounds.w)
		y1 := math.round(c.calc_bounds.y + c.calc_bounds.h)
		c.calc_bounds = {x0, y0, x1 - x0, y1 - y0}
	}
}

ui_interact_components :: proc(ctx: ^UIContext) {
	it := ui_iterate_draw_order(ctx)
	for c in ui_next_draw_order(&it) {
		if c == ctx.root do continue
		switch c.type {
			case .Panel, .Label: break
			case .Canvas: break // TODO: Canvas interact callback?
			case .Button: {
				d := c.data.(ButtonData) or_continue
				mouse_over := collide_vec2_rect(ctx.mouse.pos, c.calc_bounds)
				if mouse_over do ctx.hovered_id = d.id
				if d.id == ctx.active_id {
					if .Left not_in ctx.mouse.down {
						if mouse_over do ctx.last_clicked_id = d.id
						ctx.active_id = 0
					}
				} else if d.id == ctx.hovered_id && .Left in ctx.mouse.pressed {
					ctx.active_id = d.id
				}
			}
			case .Slider: {
				d := c.data.(SliderData) or_continue
				mouse_over := collide_vec2_rect(ctx.mouse.pos, c.calc_bounds)
				if mouse_over do ctx.hovered_id = d.id
				if d.id == ctx.active_id {
					thumb_r := ctx.theme.slider_width / 2
					norm: f32
					if d.orientation == .Vertical {
						track_range := c.calc_bounds.h - ctx.theme.slider_width
						mouse_p := clamp(ctx.mouse.pos.y, c.calc_bounds.y + thumb_r, c.calc_bounds.y + c.calc_bounds.h - thumb_r)
						norm = clamp(1.0 - (mouse_p - c.calc_bounds.y - thumb_r) / track_range, 0, 1)
					} else {
						track_range := c.calc_bounds.w - ctx.theme.slider_width
						mouse_p := clamp(ctx.mouse.pos.x, c.calc_bounds.x + thumb_r, c.calc_bounds.x + c.calc_bounds.w - thumb_r)
						norm = clamp((mouse_p - c.calc_bounds.x - thumb_r) / track_range, 0, 1)
					}
					binding_set_norm(ctx, d.binding, norm)
					if .Left not_in ctx.mouse.down {
						binding_end_edit(ctx, d.binding)
						ctx.active_id = 0
					}
				} else if d.id == ctx.hovered_id && .Left in ctx.mouse.double_clicked {
					// Reset param to default on double click
					binding_reset_to_default(ctx, d.binding)
				} else if d.id == ctx.hovered_id && .Left in ctx.mouse.pressed {
					ctx.active_id = d.id
					binding_begin_edit(ctx, d.binding)
				}
			}
			case .Toggle: {
				d := c.data.(ToggleData) or_continue
				mouse_over := collide_vec2_rect(ctx.mouse.pos, c.calc_bounds)
				if mouse_over do ctx.hovered_id = d.id
				// Click = press + release while hovered
				if d.id == ctx.active_id {
					if .Left not_in ctx.mouse.down {
						if mouse_over {
							switch v in d.binding {
							case ToggleBoolBinding:
								v.val^ = !v.val^
							case ParamBinding:
								cur := ui_param_get_normalized(ctx, v.param_idx)
								new := f32(0) if cur >= 0.5 else f32(1)
								ui_param_begin_edit(ctx, v.param_idx)
								ui_param_set_normalized(ctx, v.param_idx, new)
								ui_param_end_edit(ctx, v.param_idx)
							}
						}
						ctx.active_id = 0
					}
				} else if d.id == ctx.hovered_id && .Left in ctx.mouse.pressed {
					ctx.active_id = d.id
				}
			}
			case .Knob: {
				d := c.data.(KnobData) or_continue
				mouse_over := collide_vec2_rect(ctx.mouse.pos, c.calc_bounds)
				if mouse_over do ctx.hovered_id = d.id
				if d.id == ctx.active_id {
					norm := clamp(ctx.drag_anchor_norm + (ctx.drag_anchor_mouse_y - ctx.mouse.pos.y) / ctx.theme.knob_drag_pixels, 0, 1)
					binding_set_norm(ctx, d.binding, norm)
					if .Left not_in ctx.mouse.down {
						binding_end_edit(ctx, d.binding)
						ctx.active_id = 0
					}
				} else if d.id == ctx.hovered_id && .Left in ctx.mouse.double_clicked {
					// Reset param to default on double click
					binding_reset_to_default(ctx, d.binding)
				} else if d.id == ctx.hovered_id && .Left in ctx.mouse.pressed {
					ctx.active_id = d.id
					ctx.drag_anchor_mouse_y = ctx.mouse.pos.y
					ctx.drag_anchor_norm = binding_get_norm(ctx, d.binding)
					binding_begin_edit(ctx, d.binding)
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
	sizing_along_axis := (comp.direction == .Horizontal) == horiz
	padding := comp.sizing_horiz.padding if horiz else comp.sizing_vert.padding
	parent_size := comp.calc_bounds.w if horiz else comp.calc_bounds.h
	content_size := parent_size - padding * 2

	child_iter := ui_iterate_children(comp)
	for c in ui_next_child(&child_iter) {
		sizing := c.sizing_horiz if horiz else c.sizing_vert
		size: f32
		if sizing.type == .Percent {
			size = sizing.value * content_size
		} else if sizing.type == .Grow && (c.floating || !sizing_along_axis) {
			size = content_size
		} else {
			continue
		}
		if sizing.min > 0 do size = math.max(size, sizing.min)
		if sizing.max > 0 do size = math.min(size, sizing.max)
		if horiz {
			c.calc_bounds.w = size
		} else {
			c.calc_bounds.h = size
		}
	}

	if !sizing_along_axis do return
	// main axis

	// distribute remaining space among grow children by weight
	used: f32
	weight_sum: f32
	child_count: int

	child_iter = ui_iterate_children(comp)
	for c in ui_next_child(&child_iter) {
		if c.floating do continue
		child_count += 1
		sizing := c.sizing_horiz if horiz else c.sizing_vert
		if sizing.type == .Grow {
			weight_sum += sizing.weight if sizing.weight > 0 else 1
		} else {
			used += c.calc_bounds.w if horiz else c.calc_bounds.h
		}
	}

	if weight_sum == 0 do return

	if child_count > 1 {
		used += comp.child_gaps * f32(child_count - 1)
	}
	used += padding * 2

	grow_space := parent_size - used

	child_iter = ui_iterate_children(comp)
	for c in ui_next_child(&child_iter) {
		if c.floating do continue
		sizing := &c.sizing_horiz if horiz else &c.sizing_vert
		if sizing.type != .Grow do continue
		weight := sizing.weight if sizing.weight > 0 else 1
		size := grow_space * weight / weight_sum
		if sizing.min > 0 do size = math.max(size, sizing.min)
		if sizing.max > 0 do size = math.min(size, sizing.max)
		if horiz {
			c.calc_bounds.w = size
		} else {
			c.calc_bounds.h = size
		}
	}
}

ui_position_components :: proc(ctx: ^UIContext) {
	ctx.root.cursor = {ctx.root.sizing_horiz.padding, ctx.root.sizing_vert.padding}
	it := ui_iterate_pre_order(ctx)

	for c in ui_next_pre_order(&it) {
		if c == ctx.root do continue
		parent := c.parent
		content_w := parent.calc_bounds.w - 2 * parent.sizing_horiz.padding
		content_h := parent.calc_bounds.h - 2 * parent.sizing_vert.padding

		if c.floating {
			switch c.align_x {
			case .Left:   c.calc_bounds.x = parent.calc_bounds.x + parent.sizing_horiz.padding
			case .Center: c.calc_bounds.x = parent.calc_bounds.x + parent.sizing_horiz.padding + (content_w - c.calc_bounds.w) * 0.5
			case .Right:  c.calc_bounds.x = parent.calc_bounds.x + parent.sizing_horiz.padding + content_w - c.calc_bounds.w
			}
			switch c.align_y {
			case .Top:    c.calc_bounds.y = parent.calc_bounds.y + parent.sizing_vert.padding
			case .Center: c.calc_bounds.y = parent.calc_bounds.y + parent.sizing_vert.padding + (content_h - c.calc_bounds.h) * 0.5
			case .Bottom: c.calc_bounds.y = parent.calc_bounds.y + parent.sizing_vert.padding + content_h - c.calc_bounds.h
			}
			c.calc_bounds.x += c.float_offset.x
			c.calc_bounds.y += c.float_offset.y
		} else if parent.direction == .Horizontal {
			c.calc_bounds.x = parent.cursor.x
			switch c.align_y {
			case .Top:    c.calc_bounds.y = parent.calc_bounds.y + parent.sizing_vert.padding
			case .Center: c.calc_bounds.y = parent.calc_bounds.y + parent.sizing_vert.padding + (content_h - c.calc_bounds.h) * 0.5
			case .Bottom: c.calc_bounds.y = parent.calc_bounds.y + parent.sizing_vert.padding + content_h - c.calc_bounds.h
			}
			parent.cursor.x += c.calc_bounds.w + parent.child_gaps
		} else {
			c.calc_bounds.y = parent.cursor.y
			switch c.align_x {
			case .Left:   c.calc_bounds.x = parent.calc_bounds.x + parent.sizing_horiz.padding
			case .Center: c.calc_bounds.x = parent.calc_bounds.x + parent.sizing_horiz.padding + (content_w - c.calc_bounds.w) * 0.5
			case .Right:  c.calc_bounds.x = parent.calc_bounds.x + parent.sizing_horiz.padding + content_w - c.calc_bounds.w
			}
			parent.cursor.y += c.calc_bounds.h + parent.child_gaps
		}

		c.cursor = {c.calc_bounds.x + c.sizing_horiz.padding, c.calc_bounds.y + c.sizing_vert.padding}
	}
}

ui_generate_draw_calls :: proc(ctx: ^UIContext) {
	it := ui_iterate_draw_order(ctx)

	for c in ui_next_draw_order(&it) {
		if c == ctx.root do continue // Skip root node
		switch c.type {
			case .Panel: {
				d := c.data.(PanelData) or_continue
				if d.skip_draw do continue
				rect := SimpleUIRect{}
				rect.x = c.calc_bounds.x
				rect.y = c.calc_bounds.y
				rect.width = c.calc_bounds.w
				rect.height = c.calc_bounds.h
				rect.color = ctx.theme.panel_bg_color
				rect.corner_rad = ctx.theme.corner_radius
				rect.border_width = ctx.theme.panel_border_width
				rect.border_color = ctx.theme.panel_border_color
				draw_push_rect(ctx.plugin.draw, rect)
			}
			case .Label: {
				d := c.data.(LabelData) or_continue
				text_size := draw_measure_text(ctx.plugin.draw, d.text, d.size)
				text_x := c.calc_bounds.x
				switch c.align_x {
				case .Left:
				case .Center: text_x = c.calc_bounds.x + (c.calc_bounds.w - text_size.x) * 0.5
				case .Right:  text_x = c.calc_bounds.x + c.calc_bounds.w - text_size.x
				}
				draw_text(ctx.plugin.draw, d.text, text_x, c.calc_bounds.y, ctx.theme.text_color, d.size)
			}
			case .Button: {
				d := c.data.(ButtonData) or_continue
				hover_t := ui_animate(ctx, d.id, f32(1) if d.id == ctx.hovered_id else f32(0))
				bg_color := color_u8_lerp(ctx.theme.button_color, ctx.theme.button_hover_color, hover_t)
				if d.id == ctx.active_id do bg_color = ctx.theme.button_active_color
				draw_push_rect(ctx.plugin.draw, SimpleUIRect {
					x = c.calc_bounds.x, y = c.calc_bounds.y,
					width = c.calc_bounds.w, height = c.calc_bounds.h,
					color = bg_color,
					corner_rad = ctx.theme.corner_radius,
					border_color = ctx.theme.border_color,
					border_width = ctx.theme.border_width,
				})
				text_size := draw_measure_text(ctx.plugin.draw, d.label, ctx.theme.font_size)
				draw_text(ctx.plugin.draw, d.label,
					c.calc_bounds.x + (c.calc_bounds.w - text_size.x) * 0.5,
					c.calc_bounds.y + (c.calc_bounds.h - text_size.y) * 0.5,
					ctx.theme.text_color, ctx.theme.font_size)
			}
			case .Slider: {
				bounds := c.calc_bounds
				d := c.data.(SliderData) or_continue
				thumb_r := ctx.theme.slider_width / 2

				norm := binding_get_norm(ctx, d.binding)

				hover_t := ui_animate(ctx, d.id, f32(1) if d.id == ctx.hovered_id else f32(0))
				thumb_color := color_u8_lerp(ctx.theme.slider_color, ctx.theme.slider_hover_color, hover_t)
				if d.id == ctx.active_id do thumb_color = ctx.theme.slider_active_color

				if d.orientation == .Vertical {
					track_range := bounds.h - ctx.theme.slider_width
					slider_y := norm * track_range

					// Rail background
					draw_push_rect(ctx.plugin.draw, SimpleUIRect {
						x = bounds.x + (bounds.w / 2) - (ctx.theme.slider_rail_width / 2),
						y = bounds.y + thumb_r,
						width = ctx.theme.slider_rail_width,
						height = track_range,
						color = ctx.theme.slider_track_color,
						corner_rad = ctx.theme.slider_rail_width / 2,
						border_color = ctx.theme.border_color,
						border_width = ctx.theme.slider_rail_border_width,
					})
					// Filled portion
					draw_push_rect(ctx.plugin.draw, SimpleUIRect {
						x = bounds.x + (bounds.w / 2) - (ctx.theme.slider_rail_width / 2),
						y = bounds.y + thumb_r + (track_range - slider_y),
						width = ctx.theme.slider_rail_width,
						height = slider_y,
						color = ctx.theme.slider_color,
						corner_rad = ctx.theme.slider_rail_width / 2,
					})
					// Thumb circle
					draw_push_rect(ctx.plugin.draw, SimpleUIRect {
						x = bounds.x + (bounds.w / 2) - (ctx.theme.slider_width / 2),
						y = bounds.y + (track_range - slider_y),
						width = ctx.theme.slider_width,
						height = ctx.theme.slider_width,
						color = thumb_color,
						corner_rad = ctx.theme.slider_width / 2,
						border_color = ctx.theme.slider_active_color,
						border_width = ctx.theme.slider_thumb_border_width,
					})
				} else {
					track_range := bounds.w - ctx.theme.slider_width
					slider_x := norm * track_range

					// Rail background
					draw_push_rect(ctx.plugin.draw, SimpleUIRect {
						x = bounds.x + thumb_r,
						y = bounds.y + (bounds.h / 2) - (ctx.theme.slider_rail_width / 2),
						width = track_range,
						height = ctx.theme.slider_rail_width,
						color = ctx.theme.slider_track_color,
						corner_rad = ctx.theme.slider_rail_width / 2,
						border_color = ctx.theme.border_color,
						border_width = ctx.theme.slider_rail_border_width,
					})
					// Filled portion
					draw_push_rect(ctx.plugin.draw, SimpleUIRect {
						x = bounds.x + thumb_r,
						y = bounds.y + (bounds.h / 2) - (ctx.theme.slider_rail_width / 2),
						width = slider_x,
						height = ctx.theme.slider_rail_width,
						color = ctx.theme.slider_color,
						corner_rad = ctx.theme.slider_rail_width / 2,
					})
					// Thumb circle
					draw_push_rect(ctx.plugin.draw, SimpleUIRect {
						x = bounds.x + slider_x,
						y = bounds.y + (bounds.h / 2) - (ctx.theme.slider_width / 2),
						width = ctx.theme.slider_width,
						height = ctx.theme.slider_width,
						color = thumb_color,
						corner_rad = ctx.theme.slider_width / 2,
						border_color = ctx.theme.slider_active_color,
						border_width = ctx.theme.slider_thumb_border_width,
					})
				}
			}
			case .Toggle: {
				bounds := c.calc_bounds
				d := c.data.(ToggleData) or_continue

				on: bool
				switch v in d.binding {
				case ToggleBoolBinding:
					on = v.val^
				case ParamBinding:
					on = ui_param_get_normalized(ctx, v.param_idx) >= 0.5
				}

				t := ui_animate(ctx, d.id, f32(1) if on else f32(0), 18)
				bg_color := color_u8_lerp(ctx.theme.toggle_off_color, ctx.theme.toggle_on_color, t)
				pill_rad := bounds.h / 2
				// Pill background
				draw_push_rect(ctx.plugin.draw, SimpleUIRect {
					x = bounds.x, y = bounds.y,
					width = bounds.w, height = bounds.h,
					color = bg_color,
					corner_rad = pill_rad,
				})
				// Thumb circle
				margin := ctx.theme.toggle_thumb_margin
				thumb_r := pill_rad - margin
				thumb_x := bounds.x + margin + thumb_r + (bounds.w - bounds.h) * t
				thumb_y := bounds.y + pill_rad
				draw_circle(ctx.plugin.draw, thumb_x, thumb_y, thumb_r, ctx.theme.toggle_thumb_color)
			}
			case .Knob: {
				bounds := c.calc_bounds
				d := c.data.(KnobData) or_continue

				norm := binding_get_norm(ctx, d.binding)

				hover_t := ui_animate(ctx, d.id, f32(1) if d.id == ctx.hovered_id else f32(0))
				arc_color := color_u8_lerp(ctx.theme.slider_color, ctx.theme.slider_hover_color, hover_t)
				if d.id == ctx.active_id do arc_color = ctx.theme.slider_active_color

				center := Vec2f{bounds.x + bounds.w * 0.5, bounds.y + bounds.h * 0.5}
				radius := math.min(bounds.w, bounds.h) * 0.5 - ctx.theme.knob_arc_thickness

				// Track arc (full sweep)
				draw_push_arc(ctx.plugin.draw, center, radius,
					ctx.theme.knob_start_angle, ctx.theme.knob_start_angle + ctx.theme.knob_sweep_angle,
					ctx.theme.knob_track_thickness, ctx.theme.slider_track_color)

				end_fill := ctx.theme.knob_start_angle + norm * ctx.theme.knob_sweep_angle
				if norm > 0.001 {
					draw_push_arc(ctx.plugin.draw, center, radius,
						ctx.theme.knob_start_angle, end_fill,
						ctx.theme.knob_arc_thickness, arc_color)
				}

				// Indicator line + end-cap dot at the current angle
				dir := Vec2f{math.cos(end_fill), math.sin(end_fill)}
				inner := Vec2f{center.x + dir.x * ctx.theme.knob_indicator_inset, center.y + dir.y * ctx.theme.knob_indicator_inset}
				outer := Vec2f{center.x + dir.x * (radius - ctx.theme.knob_arc_thickness - 4), center.y + dir.y * (radius - ctx.theme.knob_arc_thickness - 4)}
				draw_push_pill(ctx.plugin.draw, inner, outer, ctx.theme.knob_track_thickness, arc_color)
			}
			case .Canvas: {
				d := c.data.(CanvasData) or_continue
				cb := c.calc_bounds
				draw_set_scissor(ctx.plugin.draw, RectI32{i32(cb.x), i32(cb.y), i32(cb.w), i32(cb.h)})
				if d.draw_proc != nil do d.draw_proc(ctx, c, d.data)
				draw_remove_scissor(ctx.plugin.draw)
			}
		}
	}
}

ui_size_fit_on_axis :: proc(ctx: ^UIContext, horiz: bool) {
	comp := ctx.current_component
	child_iter := ui_iterate_children(comp)
	sizing_along_axis := (comp.direction == .Horizontal) == horiz
	size: f32
	child_count: int

	for c in ui_next_child(&child_iter) {
		if c.floating do continue
		child_count += 1
		child_sizing := c.sizing_horiz if horiz else c.sizing_vert
		// Grow and Percent children contribute their min to Fit calculation
		child_size := c.calc_bounds.w if horiz else c.calc_bounds.h
		if child_sizing.type == .Grow || child_sizing.type == .Percent {
			child_size = child_sizing.min
		}
		if sizing_along_axis {
			size += child_size
		} else {
			size = math.max(size, child_size)
		}
	}

	if sizing_along_axis && child_count > 1 {
		size += comp.child_gaps * f32(child_count - 1)
	}
	size += 2 * (horiz ? comp.sizing_horiz.padding : comp.sizing_vert.padding)

	// Clamp to Fit min/max
	fit_sizing := comp.sizing_horiz if horiz else comp.sizing_vert
	if fit_sizing.max > 0 do size = math.min(size, fit_sizing.max)
	if fit_sizing.min > 0 do size = math.max(size, fit_sizing.min)

	if horiz {
		comp.calc_bounds.w = size
	} else {
		comp.calc_bounds.h = size
	}
}

ui_component_lastchild :: proc(node: ^Component) -> ^Component {
	node := node
	for node.first_child != nil do node = node.first_child
	return node
}

ui_iterate_children :: proc(comp: ^Component) -> ComponentIterator {
	return ComponentIterator{comp.first_child}
}

ui_next_child :: proc(iter: ^ComponentIterator) -> (next: ^Component, cont: bool) {
	current_node := iter.current
	if current_node == nil do return nil, false
	iter.current = iter.current.next_sibling
	return current_node, true
}

ui_iterate_pre_order :: proc(ctx: ^UIContext) -> ComponentIterator {
	return ComponentIterator{ctx.root}
}

ui_next_pre_order :: proc(iter: ^ComponentIterator) -> (next: ^Component, cont: bool) {
	current_node := iter.current
	if current_node == nil do return nil, false

	if current_node.first_child != nil {
		iter.current = current_node.first_child
	} else {
		walk_up := current_node
		for walk_up != nil {
			if walk_up.next_sibling != nil {
				iter.current = walk_up.next_sibling
				return current_node, true
			}
			walk_up = walk_up.parent
		}
		iter.current = nil
	}

	return current_node, true
}

ui_iterate_post_order :: proc(ctx: ^UIContext) -> ComponentIterator {
	return ComponentIterator{ui_component_lastchild(ctx.root)}
}

ui_next_post_order :: proc(iter: ^ComponentIterator) -> (next: ^Component, cont: bool) {
	current_node := iter.current
	if current_node == nil do return nil, false

	if current_node.next_sibling != nil {
		iter.current = ui_component_lastchild(iter.current.next_sibling)
	} else {
		iter.current = current_node.parent
	}

	return current_node, true
}

ui_in_floating_subtree :: proc(c: ^Component) -> bool {
	for n := c; n != nil; n = n.parent {
		if n.floating do return true
	}
	return false
}

// yields in-flow components in pre-order, then floating, so floating
// content draws and hit-tests on top of everything else
DrawOrderIterator :: struct {
	ctx: ^UIContext,
	inner: ComponentIterator,
	floating_pass: bool,
}

ui_iterate_draw_order :: proc(ctx: ^UIContext) -> DrawOrderIterator {
	return DrawOrderIterator{ctx, ui_iterate_pre_order(ctx), false}
}

ui_next_draw_order :: proc(it: ^DrawOrderIterator) -> (next: ^Component, cont: bool) {
	for {
		c, ok := ui_next_pre_order(&it.inner)
		if !ok {
			if it.floating_pass do return nil, false
			it.floating_pass = true
			it.inner = ui_iterate_pre_order(it.ctx)
			continue
		}
		if ui_in_floating_subtree(c) == it.floating_pass do return c, true
	}
}

// Layout tests

@(private = "file")
test_init_ctx :: proc(ctx: ^UIContext) {
	ctx.component_count = 0
	ctx.root = ui_alloc_component(ctx)
	ctx.root^ = Component{}
	ctx.root.calc_bounds = {0, 0, 400, 300}
	ctx.current_component = ctx.root
}

@(private = "file")
test_open_comp :: proc(ctx: ^UIContext, sizing_h, sizing_v: AxisSizing, dir: LayoutDirection = .Horizontal, child_gaps: f32 = 0) -> ^Component {
	comp := ui_open_component(ctx)
	comp.sizing_horiz = sizing_h
	comp.sizing_vert = sizing_v
	comp.direction = dir
	comp.child_gaps = child_gaps
	return comp
}

@(private = "file")
test_close_comp :: proc(ctx: ^UIContext) {
	ui_close_component(ctx)
}

@(private = "file")
test_leaf :: proc(ctx: ^UIContext, sizing_h, sizing_v: AxisSizing) -> ^Component {
	comp := test_open_comp(ctx, sizing_h, sizing_v)
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
	parent := test_open_comp(&ctx, {type = .Fit}, {type = .Fit}, .Horizontal, child_gaps = 10)
	a := test_leaf(&ctx, {type = .Fixed, value = 100}, {type = .Fixed, value = 50})
	b := test_leaf(&ctx, {type = .Fixed, value = 80}, {type = .Fixed, value = 50})
	test_close_comp(&ctx)

	ui_size_grow_components(&ctx)
	ui_position_components(&ctx)

	// Fit parent should wrap children: 100 + 10 gap + 80 = 190
	testing.expect(t, approx(parent.calc_bounds.w, 190), "parent width")
	testing.expect(t, approx(parent.calc_bounds.h, 50), "parent height")

	// Children positioned left to right
	testing.expect(t, approx(a.calc_bounds.x, 0), "a.x")
	testing.expect(t, approx(b.calc_bounds.x, 110), "b.x") // 100 + 10 gap
}

@(test)
test_grow_fills_parent :: proc(t: ^testing.T) {
	// One Grow child should fill the parent
	ctx: UIContext
	test_init_ctx(&ctx)
	child := test_leaf(&ctx, {type = .Grow}, {type = .Grow})

	ui_size_grow_components(&ctx)
	ui_position_components(&ctx)

	testing.expect(t, approx(child.calc_bounds.w, 400), "child width")
	testing.expect(t, approx(child.calc_bounds.h, 300), "child height")
}

@(test)
test_grow_distributes_evenly :: proc(t: ^testing.T) {
	// Two Grow children split parent evenly
	ctx: UIContext
	test_init_ctx(&ctx)
	ctx.root.direction = .Horizontal
	a := test_leaf(&ctx, {type = .Grow}, {type = .Fixed, value = 50})
	b := test_leaf(&ctx, {type = .Grow}, {type = .Fixed, value = 50})

	ui_size_grow_components(&ctx)
	ui_position_components(&ctx)

	testing.expect(t, approx(a.calc_bounds.w, 200), "a width")
	testing.expect(t, approx(b.calc_bounds.w, 200), "b width")
	testing.expect(t, approx(a.calc_bounds.x, 0), "a.x")
	testing.expect(t, approx(b.calc_bounds.x, 200), "b.x")
}

@(test)
test_grow_with_fixed_sibling :: proc(t: ^testing.T) {
	// Fixed child + Grow child, Grow takes remaining space
	ctx: UIContext
	test_init_ctx(&ctx)
	ctx.root.direction = .Horizontal
	ctx.root.child_gaps = 10
	fixed := test_leaf(&ctx, {type = .Fixed, value = 100}, {type = .Fixed, value = 50})
	grow := test_leaf(&ctx, {type = .Grow}, {type = .Fixed, value = 50})

	ui_size_grow_components(&ctx)
	ui_position_components(&ctx)

	// 400 - 100 fixed - 10 gap = 290
	testing.expect(t, approx(fixed.calc_bounds.w, 100), "fixed width")
	testing.expect(t, approx(grow.calc_bounds.w, 290), "grow width")
}

@(test)
test_padding :: proc(t: ^testing.T) {
	// Parent with padding, child positioned inset
	ctx: UIContext
	test_init_ctx(&ctx)
	parent := test_open_comp(&ctx,
		{type = .Fit, padding = 15},
		{type = .Fit, padding = 15},
		.Horizontal)
	child := test_leaf(&ctx, {type = .Fixed, value = 100}, {type = .Fixed, value = 50})
	test_close_comp(&ctx)

	ui_size_grow_components(&ctx)
	ui_position_components(&ctx)

	// Fit + padding: 100 + 30 = 130
	testing.expect(t, approx(parent.calc_bounds.w, 130), "parent width with padding")
	testing.expect(t, approx(parent.calc_bounds.h, 80), "parent height with padding")
	// Child offset by padding
	testing.expect(t, approx(child.calc_bounds.x, parent.calc_bounds.x + 15), "child x offset by padding")
	testing.expect(t, approx(child.calc_bounds.y, parent.calc_bounds.y + 15), "child y offset by padding")
}

@(test)
test_vertical_layout :: proc(t: ^testing.T) {
	ctx: UIContext
	test_init_ctx(&ctx)
	ctx.root.direction = .Vertical
	ctx.root.child_gaps = 5
	a := test_leaf(&ctx, {type = .Fixed, value = 100}, {type = .Fixed, value = 30})
	b := test_leaf(&ctx, {type = .Fixed, value = 100}, {type = .Fixed, value = 40})

	ui_size_grow_components(&ctx)
	ui_position_components(&ctx)

	testing.expect(t, approx(a.calc_bounds.y, 0), "a.y")
	testing.expect(t, approx(b.calc_bounds.y, 35), "b.y") // 30 + 5 gap
}

@(test)
test_grow_min_max_clamp :: proc(t: ^testing.T) {
	// Grow with min/max clamping
	ctx: UIContext
	test_init_ctx(&ctx)
	ctx.root.direction = .Horizontal
	child := test_leaf(&ctx, {type = .Grow, min = 50, max = 150}, {type = .Fixed, value = 50})

	ui_size_grow_components(&ctx)

	// Parent is 400, but max clamps to 150
	testing.expect(t, approx(child.calc_bounds.w, 150), "clamped to max")
}

@(test)
test_percent_of_parent :: proc(t: ^testing.T) {
	ctx: UIContext
	test_init_ctx(&ctx)
	ctx.root.direction = .Horizontal
	a := test_leaf(&ctx, {type = .Percent, value = 0.5}, {type = .Percent, value = 0.25})

	ui_size_grow_components(&ctx)
	ui_position_components(&ctx)

	testing.expect(t, approx(a.calc_bounds.w, 200), "50 percent of 400")
	testing.expect(t, approx(a.calc_bounds.h, 75), "25 percent of 300")
}

@(test)
test_grow_weights :: proc(t: ^testing.T) {
	// Weighted Grow children split 1:3
	ctx: UIContext
	test_init_ctx(&ctx)
	ctx.root.direction = .Horizontal
	a := test_leaf(&ctx, {type = .Grow, weight = 1}, {type = .Fixed, value = 50})
	b := test_leaf(&ctx, {type = .Grow, weight = 3}, {type = .Fixed, value = 50})

	ui_size_grow_components(&ctx)
	ui_position_components(&ctx)

	testing.expect(t, approx(a.calc_bounds.w, 100), "weight 1 of 4")
	testing.expect(t, approx(b.calc_bounds.w, 300), "weight 3 of 4")
}

@(test)
test_floating_skips_flow :: proc(t: ^testing.T) {
	// Floating child doesn't affect Fit sizing or flow, positions from parent origin
	ctx: UIContext
	test_init_ctx(&ctx)
	parent := test_open_comp(&ctx, {type = .Fit}, {type = .Fit}, .Horizontal, child_gaps = 10)
	a := test_leaf(&ctx, {type = .Fixed, value = 100}, {type = .Fixed, value = 50})
	f := test_open_comp(&ctx, {type = .Fixed, value = 30}, {type = .Fixed, value = 30})
	f.floating = true
	f.float_offset = {5, 6}
	test_close_comp(&ctx)
	test_close_comp(&ctx)

	ui_size_grow_components(&ctx)
	ui_position_components(&ctx)

	testing.expect(t, approx(parent.calc_bounds.w, 100), "fit parent ignores floating child")
	testing.expect(t, approx(a.calc_bounds.x, 0), "in-flow child position unchanged")
	testing.expect(t, approx(f.calc_bounds.x, 5), "floating x from parent origin plus offset")
	testing.expect(t, approx(f.calc_bounds.y, 6), "floating y from parent origin plus offset")
}
