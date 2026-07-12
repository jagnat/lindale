package sdk

import "core:math"
import b "../bridge"

// Re-export common types from platform_api
Vec2f :: b.Vec2f
Vec4f :: b.Vec4f
Mat4f :: b.Mat4f
RectI32 :: b.RectI32
RectF32 :: b.RectF32
ColorU8 :: b.ColorU8
ColorF32 :: b.ColorF32
DrawInstance :: b.DrawInstance
ShaderMode   :: b.ShaderMode
TextureHandle :: b.TextureHandle
DrawCommand :: b.DrawCommand
MouseState :: b.MouseState
MouseButton :: b.MouseButton

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

ColorU8_lerp :: proc(from, to: ColorU8, t: f32) -> ColorU8 {
	t := clamp(t, 0, 1)
	return {
		u8(f32(from.r) + (f32(to.r) - f32(from.r)) * t),
		u8(f32(from.g) + (f32(to.g) - f32(from.g)) * t),
		u8(f32(from.b) + (f32(to.b) - f32(from.b)) * t),
		u8(f32(from.a) + (f32(to.a) - f32(from.a)) * t),
	}
}

ColorF32_from_ColorU8 :: proc(col: ColorU8) -> ColorF32 {
	r := f32(col.r) / 255.0
	g := f32(col.g) / 255.0
	b := f32(col.b) / 255.0
	a := f32(col.a) / 255.0
	return {r, g, b, a}
}

decibels_to_linear_f64 :: proc(decibels: f64) -> f64 {
	return math.pow10_f64(decibels / 20)
}

decibels_to_linear_f32 :: proc(decibels: f32) -> f32 {
	return math.pow10_f32(decibels / 20)
}

decibels_to_linear :: proc {decibels_to_linear_f64, decibels_to_linear_f32}

linear_to_decibels_f64 :: proc(linear: f64) -> f64 {
	return 20 * math.log10(linear)
}

linear_to_decibels_f32 :: proc(linear: f32) -> f32 {
	return 20 * math.log10(linear)
}

linear_to_decibels :: proc { linear_to_decibels_f64, linear_to_decibels_f32 }

// interpolates through p1..p2, with p0 and p3 as neighbor tangents
catmull_rom :: #force_inline proc(p0, p1, p2, p3: Vec2f, t: f32) -> Vec2f {
	t2 := t * t
	t3 := t2 * t
	return 0.5 * (p1 * 2 + (p2 - p0) * t + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2 + (p1 * 3 - p0 - p2 * 3 + p3) * t3)
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
