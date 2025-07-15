package sdle

import "core:log"
import sdl "vendor:sdl3"
sdl_ok_panic :: #force_inline proc(ok: bool, location := #caller_location) {
	if !ok do log.panicf("SDL Error: {}", sdl.GetError(), location = location)
}
sdl_nil_panic :: #force_inline proc(ptr: rawptr, location := #caller_location) {
	if ptr == nil do log.panicf("SDL Error: {}", sdl.GetError(), location = location)
}

sdl_prop_panic :: #force_inline proc(x: sdl.PropertiesID, location := #caller_location) {
	if x == 0 do log.panicf("SDL Error: {}", sdl.GetError(), location = location)
}
err :: proc {
	sdl_ok_panic,
	sdl_nil_panic,
	sdl_prop_panic,
}

