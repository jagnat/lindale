package lindale

import "core:sys/windows"
import "core:fmt"
import "core:strings"

debug_print :: proc(format: string, args: ..any) {
	when ODIN_OS == .Windows {
		buf: [512]u8;
		n := fmt.bprintf(buf[:], format, ..args);
		// windows.OutputDebugStringA(strings.unsafe_string_to_cstring(n));
		// windows.OutputDebugStringA("\n");
	}
}