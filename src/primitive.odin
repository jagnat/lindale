package lindale

import "core:math/linalg"

Vec4f :: linalg.Vector4f32
Mat4f :: linalg.Matrix4x4f32

RectI32 :: struct {
    x, y, w, h: i32
}

ColorU8 :: struct {
	r, g, b, a: u8
}

ColorF32 :: [4]f32

ColorU8_from_hex :: proc(hexCode: u32) -> ColorU8 {
	col: ColorU8
    col.r = u8((hexCode >> 24) & 0xFF)
    col.g = u8((hexCode >> 16) & 0xFF)
    col.b = u8((hexCode >> 8) & 0xFF)
    col.a = u8(hexCode & 0xFF)
    return col
}