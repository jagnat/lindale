package bridge

// Selects which plugin's vtable + state types are compiled in. The default
// here is the source-of-truth. The set_plugin script rewrites this file.
// Override one-off with -define:ACTIVE_PLUGIN=<name>.
ACTIVE_PLUGIN :: #config(ACTIVE_PLUGIN, "template")
