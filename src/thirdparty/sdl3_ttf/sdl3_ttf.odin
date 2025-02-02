package sdl3_ttf

import "core:c"

when ODIN_OS == .Windows {
	foreign import lib {
		"windows/SDL3_ttf.lib",
	}
}

Font :: distinct rawptr
TextEngine :: distinct rawptr

// TODO: From sdl3 package? Once we have official vendor lib
IOStream :: rawptr
GPUDevice :: rawptr

@(default_calling_convention="c", link_prefix="TTF_")
foreign lib {
	Version :: proc() -> c.int ---
	GetFreeTypeVersion :: proc(major, minor, patch: ^c.int) ---
	GetHarfBuzzVersion :: proc(major, minor, patch: ^c.int) ---
	Init :: proc() -> c.bool ---
	OpenFont :: proc(file: cstring, ptsize: f32) -> Font ---
	OpenFontIO :: proc(src: IOStream, closeio: c.bool, ptsize: f32) -> Font ---
	CloseFont :: proc(font: Font) ---
	SetFontSize :: proc(font: Font, ptsize: f32) -> c.bool ---
	CreateGPUTextEngine :: proc(device: GPUDevice) -> TextEngine ---
	
}