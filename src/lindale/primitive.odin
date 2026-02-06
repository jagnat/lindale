package lindale

import "core:math"
import api "../platform_api"

// Re-export common types from platform_api
Vec2f :: api.Vec2f
Vec4f :: api.Vec4f
Mat4f :: api.Mat4f
RectI32 :: api.RectI32
RectF32 :: api.RectF32
ColorU8 :: api.ColorU8
ColorF32 :: api.ColorF32
RectInstance :: api.RectInstance
TextureHandle :: api.TextureHandle
DrawCommand :: api.DrawCommand
MouseState :: api.MouseState
MouseButton :: api.MouseButton

ColorF32_from_hex :: proc(hex: u32) -> ColorF32 {
	r := f32((hex >> 24) & 0xFF) / 255.0
	g := f32((hex >> 16) & 0xFF) / 255.0
	b := f32((hex >>  8) & 0xFF) / 255.0
	a := f32((hex >>  0) & 0xFF) / 255.0
	return {r, g, b, a}
}

ColorU8_from_hex :: proc(hexCode: u32) -> ColorU8 {
	r := u8((hexCode >> 24) & 0xFF)
	g := u8((hexCode >> 16) & 0xFF)
	b := u8((hexCode >> 8) & 0xFF)
	a := u8(hexCode & 0xFF)
	return {r, g, b, a}
}

decibels_to_linear :: proc(decibels: f64) -> f64 {
	return math.pow10_f64(decibels / 20)
}

linear_to_decibels :: proc(linear: f64) -> f64 {
	return 20 * math.log10(linear)
}

collide_vec2_rect :: proc(v: Vec2f, r: RectF32) -> bool {
	return v.x >= r.x && v.x <= r.x + r.w &&
		v.y >= r.y && v.y <= r.y + r.h
}

// FNV-1
string_hash_u64 :: proc(str: string) -> u64 {
	hash: u64 = 0xcbf29ce484222325
	for idx in 0..<len(str) {
		hash *= 0x100000001b3
		hash ~= u64(str[idx])
	}
	return hash
}

string_hash_u32 :: proc(str: string) -> u32 {
	hash: u32 = 0x811c9dc5
	for idx in 0..<len(str) {
		hash *= 0x01000193
		hash ~= u32(str[idx])
	}
	return hash
}
