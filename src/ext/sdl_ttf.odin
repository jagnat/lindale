package sdlttf

import "core:c"
import sdl "vendor:sdl3"

when ODIN_OS == .Windows {
	@(export) foreign import lib { "SDL3_ttf.lib" }
} else {
	@(export) foreign import lib { "system:SDL3_ttf" }
}

SDL_TTF_MAJOR_VERSION :: 3
SDL_TTF_MINOR_VERSION :: 3
SDL_TTF_MICRO_VERSION :: 0

Font :: struct {}

PROP_FONT_CREATE_FILENAME_STRING              :: "SDL_ttf.font.create.filename"
PROP_FONT_CREATE_IOSTREAM_POINTER             :: "SDL_ttf.font.create.iostream"
PROP_FONT_CREATE_IOSTREAM_OFFSET_NUMBER       :: "SDL_ttf.font.create.iostream.offset"
PROP_FONT_CREATE_IOSTREAM_AUTOCLOSE_BOOLEAN   :: "SDL_ttf.font.create.iostream.autoclose"
PROP_FONT_CREATE_SIZE_FLOAT                   :: "SDL_ttf.font.create.size"
PROP_FONT_CREATE_FACE_NUMBER                  :: "SDL_ttf.font.create.face"
PROP_FONT_CREATE_HORIZONTAL_DPI_NUMBER        :: "SDL_ttf.font.create.hdpi"
PROP_FONT_CREATE_VERTICAL_DPI_NUMBER          :: "SDL_ttf.font.create.vdpi"
PROP_FONT_CREATE_EXISTING_FONT                :: "SDL_ttf.font.create.existing_font"

PROP_FONT_OUTLINE_LINE_CAP_NUMBER             :: "SDL_ttf.font.outline.line_cap"
PROP_FONT_OUTLINE_LINE_JOIN_NUMBER            :: "SDL_ttf.font.outline.line_join"
PROP_FONT_OUTLINE_MITER_LIMIT_NUMBER          :: "SDL_ttf.font.outline.miter_limit"

PROP_RENDERER_TEXT_ENGINE_RENDERER            :: "SDL_ttf.renderer_text_engine.create.renderer"
PROP_RENDERER_TEXT_ENGINE_ATLAS_TEXTURE_SIZE  :: "SDL_ttf.renderer_text_engine.create.atlas_texture_size"


FontStyleFlags :: distinct bit_set[FontStyleFlag; u32]
FontStyleFlag :: enum u32 {
	BOLD = 0,
	ITALIC = 1,
	UNDERLINE = 2,
	STRIKETHROUGH = 3,
}

HintingFlags :: enum {
	INVALID = -1,
	NORMAL,
	LIGHT,
	MONO,
	NONE,
	LIGHT_SUBPIXEL,
}

HorizontalAlignment :: enum {
	INVALID = -1,
	LEFT,
	CENTER,
	RIGHT,
}

Direction :: enum {
	INVALID = 0,
	LTR = 4,
	RTL,
	TTB,
	BTT,
}

ImageType :: enum {
	INVALID,
	ALPHA,
	COLOR,
	SDF,
}

TextEngine :: struct {}
TextData :: struct {}

Text :: struct {
	text: cstring,
	num_lines: c.int,
	refcount: c.int,
	internal: ^TextData,
}

@(default_calling_convention="c", link_prefix="TTF_", require_results)
foreign lib {
	Version :: proc() -> c.int
	GetFreeTypeVersion :: proc(major, minor, patch: ^c.int)
	GetHarfBuzzVersion :: proc(major, minor, patch: ^c.int)

	Init :: proc() -> c.bool
	OpenFont :: proc(file: cstring, ptsize: f32) -> ^Font
	OpenFontIO :: proc(src: ^sdl.IOStream, closeio: c.bool, ptsize: f32) -> ^Font
	OpenFontWithProperties :: proc(props: sdl.PropertiesID) -> ^Font
	CopyFont :: proc(existing_font: ^Font) -> ^Font
	GetFontProperties :: proc(font: ^Font) -> sdl.PropertiesID
	GetFontGeneration :: proc(font: ^Font) -> u32
	AddFallbackFont :: proc(font, fallback: ^Font) -> c.bool
	RemoveFallbackFont :: proc(font, fallback: ^Font)
	ClearFallbackFonts :: proc(font: ^Font)
	SetFontSize :: proc(font: ^Font, ptsize: f32) -> c.bool
	SetFontSizeDPI :: proc(font: ^Font, ptsize: f32, hdpi, vdpi: c.int) -> c.bool
	GetFontSize :: proc(font: ^Font) -> f32
	GetFontDPI :: proc(font: ^Font, hdpi, vdpi: ^c.int) -> c.bool
	SetFontStyle :: proc(font: ^Font, style: FontStyleFlags)
	GetFontStyle :: proc(font: ^Font) -> FontStyleFlags
	SetFontOutline :: proc(font: ^Font, outline: c.int) -> c.bool
	GetFontOutline :: proc(font: ^Font) -> c.int
	SetFontHinting :: proc(font: ^Font, hinting: HintingFlags)
	GetNumFontFaces :: proc(font: ^Font) -> c.int
	GetFontHinting :: proc(font: ^Font) -> HintingFlags
	SetFontSDF :: proc(font: ^Font, enabled: c.bool) -> c.bool
	GetFontSDF :: proc(font: ^Font) -> c.bool
	SetFontWrapAlignment :: proc(font: ^Font, align: HorizontalAlignment)
	GetFontWrapAlignment :: proc(font: ^Font) -> HorizontalAlignment
	GetFontHeight :: proc(font: ^Font) -> c.int
	GetFontAscent :: proc(font: ^Font) -> c.int
	GetFontDescent :: proc(font: ^Font) -> c.int
	SetFontLineSkip :: proc(font: ^Font, lineskip: c.int)
	GetFontLineSkip :: proc(font: ^Font) -> c.int
	SetFontKerning :: proc(font: ^Font, enabled: c.bool)
	GetFontKerning :: proc(font: ^Font) -> c.bool
	FontIsFixedWidth :: proc(font: ^Font) -> c.bool
	FontIsScalable :: proc(font: ^Font) -> c.bool
	GetFontFamilyName :: proc(font: ^Font) -> cstring
	GetFontStyleName :: proc(font: ^Font) -> cstring
	SetFontDirection :: proc(font: ^Font, direction: Direction) -> c.bool
	GetFontDirection :: proc(font: ^Font) -> Direction
	StringToTag :: proc(str: cstring) -> u32
	TagToString :: proc(tag: u32, str: cstring, size: c.size_t)
	SetFontScript :: proc(font: ^Font, script: u32) -> c.bool
	GetFontScript :: proc(font: ^Font) -> u32
	GetGlyphScript :: proc(ch: u32) -> u32
	SetFontLanguage :: proc(font: ^Font, language_bcp47: cstring) -> c.bool
	FontHasGlyph :: proc(font: ^Font, ch: u32) -> c.bool
	GetGlyphImage :: proc(font: ^Font, ch: u32, image_type: ^ImageType) -> ^sdl.Surface
	GetGlyphImageForIndex :: proc(font: ^Font, glyph_index: u32, image_type: ^ImageType) -> ^sdl.Surface
	GetGlyphMetrics :: proc(font: ^Font, ch: u32, minx, maxx, miny, maxy, advance: ^c.int) -> c.bool
	GetGlyphKerning :: proc(font: ^Font, previous_ch, ch: u32, kerning: ^c.int) -> c.bool
	GetStringSize :: proc(font: ^Font, text: cstring, length: c.size_t, w, h: ^c.int) -> c.bool
	GetStringSizeWrapped :: proc(font: ^Font, text: cstring, length: c.size_t, wrap_width: c.int, w, h: ^c.int) -> c.bool
	MeasureString :: proc(font: ^Font, text: cstring, length: c.size_t, max_width: c.int, measured_width: ^c.int, measured_length: ^c.size_t) -> c.bool
	RenderText_Solid :: proc(font: ^Font, text: cstring, length: c.size_t, fg: sdl.Color) -> ^sdl.Surface
	RenderText_Solid_Wrapped :: proc(font: ^Font, text: cstring, length: c.size_t, fg: sdl.Color, wrapLength: c.int) -> ^sdl.Surface
	RenderGlyph_Solid :: proc(font: ^Font, ch: u32, fg: sdl.Color) -> ^sdl.Surface
	RenderText_Shaded :: proc(font: ^Font, text: cstring, length: c.size_t, fg, bg: sdl.Color) -> ^sdl.Surface
	RenderText_Shaded_Wrapped :: proc(font: ^Font, text: cstring, length: c.size_t, fg, bg: sdl.Color, wrapLength: c.int) -> ^sdl.Surface
	RenderGlyph_Shaded :: proc(font: ^Font, ch: u32, fg, bg: sdl.Color) -> ^sdl.Surface
	RenderText_Blended :: proc(font: ^Font, text: cstring, length: c.size_t, fg: sdl.Color) -> ^sdl.Surface
	RenderText_Blended_Wrapped :: proc(font: ^Font, text: cstring, length: c.size_t, fg: sdl.Color, wrapLength: c.int) -> ^sdl.Surface
	RenderGlyph_Blended :: proc(font: ^Font, ch: u32, fg: sdl.Color) -> ^sdl.Surface
	RenderText_LCD :: proc(font: ^Font, text: cstring, length: c.size_t, fg, bg: sdl.Color) -> ^sdl.Surface
	RenderText_LCD_Wrapped :: proc(font: ^Font, text: cstring, length: c.size_t, fg, bg: sdl.Color, wrapLength: c.int) -> ^sdl.Surface
	RenderGlyph_LCD :: proc(font: ^Font, ch: u32, fg, bg: sdl.Color) -> ^sdl.Surface
	CreateSurfaceTextEngine :: proc() -> ^TextEngine
	DrawSurfaceText :: proc(text: ^Text, x, y: c.int, surface: sdl.Surface) -> c.bool
	DestroySurfaceTextEngine :: proc(engine: ^TextEngine)
	CreateRendererTextEngine :: proc(renderer: ^sdl.Renderer) -> ^TextEngine
	CreateRendererTextEngineWithProperties :: proc(props: sdl.PropertiesID) -> ^TextEngine

}
