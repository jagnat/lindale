package lindale

import "core:fmt"
import "core:strings"
import "core:slice"
import "core:math"

// Forward declaration - you'll implement this
MouseState :: struct {
	lmbDown: bool,
	lmbPressed: bool,
	lmbReleased: bool,
	rmbDown: bool,
	rmbPressed: bool,
	rmbReleased: bool,
	scrollDelta: f32,
	mouseX, mouseY: f32,
}

platform_get_mouse_state :: proc() -> MouseState

// // Basic types
// Vec2f :: struct { x, y: f32 }
// RectF :: struct { x, y, w, h: f32 }

// UI State
UIContext :: struct {
	draw: ^DrawContext,
	mouse: MouseState,
	hotItem: u32,      // Item mouse is over
	activeItem: u32,   // Item being interacted with
	lastWidget: u32,   // For auto-layout
	
	// Layout state
	layoutStack: [dynamic]LayoutState,
	currentLayout: LayoutState,
}

LayoutState :: struct {
	containerRect: RectF32,
	cursor: Vec2f,
	itemSpacing: f32,
	padding: f32,
	isHorizontal: bool,
}

// UI Theme
UITheme :: struct {
	panelColor: ColorU8,
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

// Global UI context
g_ui: UIContext
g_theme: UITheme

// Hash function for generating widget IDs
ui_hash :: proc(str: string) -> u32 {
	hash: u32 = 2166136261
	for b in str {
		hash = (hash ~ u32(b)) * 16777619
	}
	return hash
}

// Initialize UI system
ui_init :: proc(drawCtx: ^DrawContext) {
	g_ui.draw = drawCtx
	g_ui.layoutStack = make([dynamic]LayoutState)
	
	// Default theme
	g_theme = UITheme{
		panelColor = {45, 45, 45, 255},
		buttonColor = {70, 70, 70, 255},
		buttonHoverColor = {90, 90, 90, 255},
		buttonActiveColor = {50, 50, 50, 255},
		sliderTrackColor = {60, 60, 60, 255},
		sliderThumbColor = {120, 120, 120, 255},
		textColor = {255, 255, 255, 255},
		borderColor = {100, 100, 100, 255},
		padding = 8,
		itemSpacing = 4,
		cornerRadius = 4,
		borderWidth = 1,
	}
}

// Begin frame - call this at start of each frame
ui_begin_frame :: proc() {
	// g_ui.mouse = platform_get_mouse_state()
	g_ui.hotItem = 0
	
	// Clear layout stack
	clear(&g_ui.layoutStack)
	g_ui.currentLayout = {}
}

// End frame - call this at end of each frame
ui_end_frame :: proc() {
	// If mouse was released, clear active item
	if g_ui.mouse.lmbReleased {
		g_ui.activeItem = 0
	}
	
	// If no widget is hot, clear active item
	if g_ui.hotItem == 0 {
		g_ui.activeItem = 0
	}
}

// Check if point is in rectangle
ui_point_in_rect :: proc(x, y: f32, rect: RectF32) -> bool {
	return x >= rect.x && x <= rect.x + rect.w && 
	       y >= rect.y && y <= rect.y + rect.h
}

// Get next widget rect based on current layout
ui_get_widget_rect :: proc(width, height: f32) -> RectF32 {
	rect := RectF32 {
		x = g_ui.currentLayout.cursor.x,
		y = g_ui.currentLayout.cursor.y,
		w = width,
		h = height,
	}
	
	// Advance cursor
	if g_ui.currentLayout.isHorizontal {
		g_ui.currentLayout.cursor.x += width + g_ui.currentLayout.itemSpacing
	} else {
		g_ui.currentLayout.cursor.y += height + g_ui.currentLayout.itemSpacing
	}
	
	return rect
}

// Panel - creates a container with background
ui_begin_panel :: proc(label: string, rect: RectF32) {
	// Draw panel background
	panelRect := SimpleUIRect{
		x = rect.x, y = rect.y,
		width = rect.w, height = rect.h,
		u = 0, v = 0, uw = 0, vh = 0,
		color = g_theme.panelColor,
		cornerRad = g_theme.cornerRadius,
	}
	draw_push_rect(g_ui.draw, panelRect)
	
	// Push new layout state
	newLayout := LayoutState{
		containerRect = rect,
		cursor = {rect.x + g_theme.padding, rect.y + g_theme.padding},
		itemSpacing = g_theme.itemSpacing,
		padding = g_theme.padding,
		isHorizontal = false,
	}
	
	append(&g_ui.layoutStack, g_ui.currentLayout)
	g_ui.currentLayout = newLayout
	
	// Draw title if provided
	if len(label) > 0 {
		ui_label(label)
		ui_spacing(4)
	}
}

ui_end_panel :: proc() {
	// Restore previous layout
	if len(g_ui.layoutStack) > 0 {
		g_ui.currentLayout = pop(&g_ui.layoutStack)
	}
}

// Set layout direction
ui_layout_horizontal :: proc() {
	g_ui.currentLayout.isHorizontal = true
}

ui_layout_vertical :: proc() {
	g_ui.currentLayout.isHorizontal = false
}

// Add spacing
ui_spacing :: proc(amount: f32) {
	if g_ui.currentLayout.isHorizontal {
		g_ui.currentLayout.cursor.x += amount
	} else {
		g_ui.currentLayout.cursor.y += amount
	}
}

// Same line - continue on same line for next widget
ui_same_line :: proc() {
	if !g_ui.currentLayout.isHorizontal {
		// Move cursor back up and switch to horizontal temporarily
		g_ui.currentLayout.cursor.y -= g_ui.currentLayout.itemSpacing
		// Note: This is a simple same_line, more complex layouts would need a stack
	}
}

// Label - displays text
ui_label :: proc(text: string) {
	textSize := draw_measure_text(g_ui.draw, text)
	rect := ui_get_widget_rect(textSize.x, textSize.y)
	
	draw_text(g_ui.draw, text, rect.x, rect.y, g_theme.textColor)
}

// Button - returns true when clicked
ui_button :: proc(label: string) -> bool {
	id := ui_hash(label)
	textSize := draw_measure_text(g_ui.draw, label)
	rect := ui_get_widget_rect(textSize.x + g_theme.padding * 2, textSize.y + g_theme.padding * 2)
	
	// Check interaction
	mouseOver := ui_point_in_rect(g_ui.mouse.mouseX, g_ui.mouse.mouseY, rect)
	
	if mouseOver {
		g_ui.hotItem = id
	}
	
	clicked := false
	buttonColor := g_theme.buttonColor
	
	if g_ui.activeItem == id {
		buttonColor = g_theme.buttonActiveColor
		if g_ui.mouse.lmbReleased {
			clicked = mouseOver
		}
	} else if g_ui.hotItem == id {
		buttonColor = g_theme.buttonHoverColor
		if g_ui.mouse.lmbPressed {
			g_ui.activeItem = id
		}
	}
	
	// Draw button
	buttonRect := SimpleUIRect{
		x = rect.x, y = rect.y,
		width = rect.w, height = rect.h,
		u = 0, v = 0, uw = 0, vh = 0,
		color = buttonColor,
		cornerRad = g_theme.cornerRadius,
	}
	draw_push_rect(g_ui.draw, buttonRect)
	
	// Draw text centered
	textX := rect.x + (rect.w - textSize.x) * 0.5
	textY := rect.y + (rect.h - textSize.y) * 0.5
	draw_text(g_ui.draw, label, textX, textY, g_theme.textColor)
	
	return clicked
}

// Horizontal slider - returns true if value changed
ui_slider_horizontal :: proc(label: string, value: ^f32, minVal, maxVal: f32, width: f32 = 200) -> bool {
	id := ui_hash(label)
	sliderHeight: f32 = 20
	rect := ui_get_widget_rect(width, sliderHeight)
	
	// Check interaction
	mouseOver := ui_point_in_rect(g_ui.mouse.mouseX, g_ui.mouse.mouseY, rect)
	changed := false
	
	if mouseOver {
		g_ui.hotItem = id
	}
	
	if g_ui.activeItem == id {
		if g_ui.mouse.lmbDown {
			// Calculate new value based on mouse position
			t := (g_ui.mouse.mouseX - rect.x) / rect.w
			t = math.clamp(t, 0, 1)
			newValue := minVal + t * (maxVal - minVal)
			if newValue != value^ {
				value^ = newValue
				changed = true
			}
		}
	} else if g_ui.hotItem == id && g_ui.mouse.lmbPressed {
		g_ui.activeItem = id
	}
	
	// Draw track
	trackRect := SimpleUIRect{
		x = rect.x, y = rect.y + rect.h * 0.4,
		width = rect.w, height = rect.h * 0.2,
		u = 0, v = 0, uw = 0, vh = 0,
		color = g_theme.sliderTrackColor,
		cornerRad = g_theme.cornerRadius * 0.5,
	}
	draw_push_rect(g_ui.draw, trackRect)
	
	// Draw thumb
	t := (value^ - minVal) / (maxVal - minVal)
	thumbX := rect.x + t * rect.w - 8
	thumbRect := SimpleUIRect{
		x = thumbX, y = rect.y,
		width = 16, height = rect.h,
		u = 0, v = 0, uw = 0, vh = 0,
		color = g_theme.sliderThumbColor,
		cornerRad = g_theme.cornerRadius,
	}
	draw_push_rect(g_ui.draw, thumbRect)
	
	// Draw label
	if len(label) > 0 {
		draw_text(g_ui.draw, label, rect.x, rect.y - 20, g_theme.textColor)
	}
	
	return changed
}

// Vertical slider - returns true if value changed
ui_slider_vertical :: proc(label: string, value: ^f32, minVal, maxVal: f32, height: f32 = 200) -> bool {
	id := ui_hash(label)
	sliderWidth: f32 = 20
	rect := ui_get_widget_rect(sliderWidth, height)
	
	// Check interaction
	mouseOver := ui_point_in_rect(g_ui.mouse.mouseX, g_ui.mouse.mouseY, rect)
	changed := false
	
	if mouseOver {
		g_ui.hotItem = id
	}
	
	if g_ui.activeItem == id {
		if g_ui.mouse.lmbDown {
			// Calculate new value based on mouse position (inverted Y)
			t := 1.0 - (g_ui.mouse.mouseY - rect.y) / rect.h
			t = math.clamp(t, 0, 1)
			newValue := minVal + t * (maxVal - minVal)
			if newValue != value^ {
				value^ = newValue
				changed = true
			}
		}
	} else if g_ui.hotItem == id && g_ui.mouse.lmbPressed {
		g_ui.activeItem = id
	}
	
	// Draw track
	trackRect := SimpleUIRect{
		x = rect.x + rect.w * 0.4, y = rect.y,
		width = rect.w * 0.2, height = rect.h,
		u = 0, v = 0, uw = 0, vh = 0,
		color = g_theme.sliderTrackColor,
		cornerRad = g_theme.cornerRadius * 0.5,
	}
	draw_push_rect(g_ui.draw, trackRect)
	
	// Draw thumb (inverted Y)
	t := (value^ - minVal) / (maxVal - minVal)
	thumbY := rect.y + (1.0 - t) * rect.h - 8
	thumbRect := SimpleUIRect{
		x = rect.x, y = thumbY,
		width = rect.w, height = 16,
		u = 0, v = 0, uw = 0, vh = 0,
		color = g_theme.sliderThumbColor,
		cornerRad = g_theme.cornerRadius,
	}
	draw_push_rect(g_ui.draw, thumbRect)
	
	// Draw label
	if len(label) > 0 {
		draw_text(g_ui.draw, label, rect.x + rect.w + 4, rect.y, g_theme.textColor)
	}
	
	return changed
}

// Simple combo box - returns selected index, -1 if no change
ui_combo :: proc(label: string, items: []string, selectedIndex: ^int) -> bool {
	id := ui_hash(label)
	comboWidth: f32 = 200
	comboHeight: f32 = 24
	rect := ui_get_widget_rect(comboWidth, comboHeight)
	
	// Check interaction with main button
	mouseOver := ui_point_in_rect(g_ui.mouse.mouseX, g_ui.mouse.mouseY, rect)
	changed := false
	
	if mouseOver {
		g_ui.hotItem = id
	}
	
	// Draw main combo box
	buttonColor := g_theme.buttonColor
	if g_ui.hotItem == id {
		buttonColor = g_theme.buttonHoverColor
	}
	
	comboRect := SimpleUIRect{
		x = rect.x, y = rect.y,
		width = rect.w, height = rect.h,
		u = 0, v = 0, uw = 0, vh = 0,
		color = buttonColor,
		cornerRad = g_theme.cornerRadius,
	}
	draw_push_rect(g_ui.draw, comboRect)
	
	// Draw current selection text
	currentText := selectedIndex^ >= 0 && selectedIndex^ < len(items) ? items[selectedIndex^] : "None"
	draw_text(g_ui.draw, currentText, rect.x + 8, rect.y + 4, g_theme.textColor)
	
	// Draw dropdown arrow
	draw_text(g_ui.draw, "v", rect.x + rect.w - 20, rect.y + 4, g_theme.textColor)
	
	// Simple dropdown - if clicked, cycle through options (basic implementation)
	if g_ui.hotItem == id && g_ui.mouse.lmbPressed {
		selectedIndex^ = (selectedIndex^ + 1) % len(items)
		changed = true
	}
	
	// Draw label
	if len(label) > 0 {
		draw_text(g_ui.draw, label, rect.x, rect.y - 20, g_theme.textColor)
	}
	
	return changed
}

// Utility function to create a simple layout
ui_auto_layout_vertical :: proc(x, y, width, height: f32) {
	g_ui.currentLayout = LayoutState{
		containerRect = {x, y, width, height},
		cursor = {x, y},
		itemSpacing = g_theme.itemSpacing,
		padding = g_theme.padding,
		isHorizontal = false,
	}
}