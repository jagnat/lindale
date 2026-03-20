package lindale

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:math"
import "core:math/rand"
import "core:time"
import dif "../thirdparty/uFFT_DIF"
import dit "../thirdparty/uFFT_DIT"

import b "../bridge"

Plugin :: struct {
	instance: ^b.PluginInstance,

	audioProcessor: ^AudioProcessorContext,

	draw: ^DrawContext,
	ui:   ^UIContext,
	mouse: b.MouseState,

	viewBounds:    RectI32,
	inDraw:        bool,
	lastDrawTime:  time.Tick,
}

PluginComponentSet :: bit_set[PluginComponent]
PluginComponent :: enum {
	Audio,
	Controller,
}

PluginApi :: struct {
	process_audio:          proc(plug: ^Plugin),
	draw:                   proc(plug: ^Plugin),
	view_attached:          proc(plug: ^Plugin),
	view_removed:           proc(plug: ^Plugin),
	view_resized:           proc(plug: ^Plugin, rect: RectI32),
	query_parameter_layout: proc() -> []b.ParamDescriptor,
}

fallbackApi :: PluginApi {
	process_audio          = plugin_process_audio,
	draw                   = plugin_draw,
	view_attached          = plugin_view_attached,
	view_removed           = plugin_view_removed,
	view_resized           = plugin_view_resized,
	query_parameter_layout = plugin_query_parameter_layout,
}

HOT_DLL :: #config(HOT_DLL, false)

when HOT_DLL {
	@(export) GetPluginApi :: proc() -> PluginApi {
		return PluginApi {
			process_audio          = plugin_process_audio,
			draw                   = plugin_draw,
			view_attached          = plugin_view_attached,
			view_removed           = plugin_view_removed,
			view_resized           = plugin_view_resized,
			query_parameter_layout = plugin_query_parameter_layout,
		}
	}
}

plugin_query_parameter_layout :: proc() -> []b.ParamDescriptor {
	return param_table[:]
}

// @(private)
plugin_init :: proc(plugin: ^Plugin, components: PluginComponentSet) {
	if .Audio in components {
		if plugin.audioProcessor == nil {
			plugin.audioProcessor = new(AudioProcessorContext)
		}
		if plugin.audioProcessor.paramChanges == nil {
			plugin.audioProcessor.paramChanges = make([][]ParameterChange, len(param_table))
		}
	}

	if .Controller in components {
		param_init()
	}
}

@(private)
plugin_destroy :: proc(plug: ^Plugin) {

}

plugin_view_attached :: proc(plug: ^Plugin) {
	if plug.draw == nil {
		plug.draw = new(DrawContext)
		plug.draw.plugin = plug
		plug.draw.clearColor = {0, 0, 0, 1}
		font_init(&plug.draw.fontState)
		plug.draw.initialized = true
	}
	if plug.ui == nil {
		plug.ui = new(UIContext)
		plug.ui.plugin = plug
	}
}

@(private)
plugin_view_removed :: proc(plug: ^Plugin) {
	if plug.draw != nil {
		font_invalidate_texture(&plug.draw.fontState)
	}
}

@(private)
plugin_view_resized :: proc(plug: ^Plugin, rect: RectI32) {
	plug.viewBounds = rect
}

plugin_draw :: proc(plug: ^Plugin) {
	if plug.draw == nil || plug.ui == nil do return

	if plug.inDraw {
		log.warn("Re-entrant draw detected!")
		return
	}
	plug.inDraw = true
	defer plug.inDraw = false

	plug.lastDrawTime = time.tick_now()

	draw_clear(plug.draw)
	draw_set_clear_color(plug.draw, {0.08, 0.08, 0.1, 1.0})

	if ui_frame_scoped(plug.ui) {
		if ui_panel(plug.ui, dir = .VERTICAL, sizingHoriz = {type = .GROW}, sizingVert = {type = .GROW}) {

			if ui_panel(plug.ui, dir = .HORIZONTAL, sizingHoriz = {type = .GROW}, sizingVert = {type = .GROW}, child_gaps = 10,) {
				if ui_button(plug.ui, "TEST") {
				}
				ui_slider_param_labeled(plug.ui, "Gain", PARAM_GAIN)
				ui_slider_param_labeled(plug.ui, "Mix", PARAM_MIX)
				ui_slider_param_labeled(plug.ui, "Freq", PARAM_FREQ)
			}

			if ui_panel(plug.ui, dir = .HORIZONTAL,) {
				ui_button(plug.ui, "Play")
				ui_button(plug.ui, "Stop")
				ui_button(plug.ui, "Record")
			}
		}
	}

	plug.draw.frame += 1

	draw_submit(plug.draw)
}

@(private)
plugin_process_audio :: proc(plug: ^Plugin) {
	audioContext := plug.audioProcessor
	if audioContext == nil do return
	if plug.instance == nil || plug.instance.params == nil do return

	freq := plug.instance.params.values[PARAM_FREQ]
	samplesPerHalfPeriod := cast(i32)(audioContext.sampleRate / (2 * freq))

	mix := f32(plug.instance.params.values[PARAM_MIX] / 100.0)

	outputs := audioContext.outputBuffers
	inputs := audioContext.inputBuffers

	if len(outputs) < 1 do return

	// Generate output buffer, iterate samples TODO: should be done channel first?
	for s in 0..< len(outputs[0].buffers32[0]) {
		AMPLITUDE :: 0.01
		squareVal : f32 = audioContext.squarePhase < samplesPerHalfPeriod ? AMPLITUDE : -AMPLITUDE
		audioContext.squarePhase += 1
		if audioContext.squarePhase >= 2 * samplesPerHalfPeriod do audioContext.squarePhase = 0

		for i in 0 ..< len(outputs) {
			outputBufs := outputs[i].buffers32
			numChannels := len(outputs[i].buffers32)
			inputBufs := inputs[i].buffers32

			for c in 0..<numChannels {
				inVal : f32 = 0
				if len(inputs) > 0 && len(inputs[i].buffers32) > c {
					inVal = inputs[i].buffers32[c][s]
				}
				out := outputBufs[c]
				out[s] = mix * squareVal + (1 - mix) * inVal
			}
		}
	}
}
