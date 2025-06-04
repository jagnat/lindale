package lindale

import "core:math/linalg"
import "core:math"

Vec4f :: linalg.Vector4f32
Mat4f :: linalg.Matrix4x4f32

RectI32 :: struct {
	x, y, w, h: i32
}

ColorU8 :: struct {
	r, g, b, a: u8
}

ColorF32 :: [4]f32

ColorF32_from_hex :: proc(hex: u32) -> [4]f32 {
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
