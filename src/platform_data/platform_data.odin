package platform_data

SwapchainData :: struct {
	swapchainArg0, swapchainArg1, swapchainArg2: rawptr,
}

PlatformData :: struct {
	graphicsDevice, graphicsDeviceCtx: rawptr,
	width, height: int,
	swapchain: SwapchainData,
}
