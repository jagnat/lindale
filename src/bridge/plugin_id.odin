package bridge

// Selects which plugin's vtable + state types are compiled in. The default
// here is the source-of-truth. The build script 'select' mode rewrites this file.
// Override one-off with -define:ACTIVE_PLUGIN=<name>.
ACTIVE_PLUGIN :: #config(ACTIVE_PLUGIN, "scopey")
