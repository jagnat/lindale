package lindale

import "core:math/linalg"
import "core:math"

Vec2f :: linalg.Vector2f32
Vec4f :: linalg.Vector4f32
Mat4f :: linalg.Matrix4x4f32

RectI32 :: struct {
	x, y, w, h: i32
}

RectF32 :: struct {
	x, y, w, h: f32
}

ColorU8 :: struct {
	r, g, b, a: u8
}

ColorF32 :: [4]f32

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

vec2_in_rect :: proc(v: Vec2f, r: RectF32) -> bool {
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
