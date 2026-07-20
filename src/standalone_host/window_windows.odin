package standalone_host

import win "core:sys/windows"

import "../sdk"

PlatformWindow :: struct {
	hwnd: win.HWND,
	parent_view: rawptr,
}

WINDOW_CLASS_NAME :: "LindaleStandaloneWindow"

standalone_wndproc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	switch msg {
	case win.WM_DESTROY:
		win.PostQuitMessage(0)
		return 0
	}
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}

window_create :: proc(title: string, cfg: sdk.ViewConfig) -> PlatformWindow {
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))

	wcex := win.WNDCLASSEXW {
		cbSize = size_of(win.WNDCLASSEXW),
		style = win.CS_HREDRAW | win.CS_VREDRAW,
		lpfnWndProc = standalone_wndproc,
		hInstance = instance,
		hCursor = win.LoadCursorW(nil, transmute(win.LPCWSTR)uintptr(32512)), // IDC_ARROW
		lpszClassName = win.L(WINDOW_CLASS_NAME),
	}
	win.RegisterClassExW(&wcex)

	style := win.WS_OVERLAPPED | win.WS_CAPTION | win.WS_SYSMENU | win.WS_MINIMIZEBOX
	if cfg.resizable do style |= win.WS_THICKFRAME | win.WS_MAXIMIZEBOX

	// grow the window rect so the client area matches the view size
	rect := win.RECT{0, 0, cfg.default_width, cfg.default_height}
	win.AdjustWindowRect(&rect, style, false)

	hwnd := win.CreateWindowExW(
		0,
		win.L(WINDOW_CLASS_NAME),
		win.utf8_to_wstring(title),
		style,
		win.CW_USEDEFAULT, win.CW_USEDEFAULT,
		rect.right - rect.left, rect.bottom - rect.top,
		nil, nil, instance, nil)

	win.ShowWindow(hwnd, win.SW_SHOW)

	return {
		hwnd = hwnd,
		parent_view = rawptr(hwnd),
	}
}

window_run_event_loop :: proc() {
	msg: win.MSG
	for win.GetMessageW(&msg, nil, 0, 0) > 0 {
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}
}
