package main

import "../animation"
import "../kernel"
import "../lib/glist"
import "../lib/sdle"
import "../renderer"
import "base:runtime"
import "core:log"
import "core:math"
import lal "core:math/linalg"
import "core:math/rand"
import "core:mem"
import "core:slice"
import "core:time"
import sdl "vendor:sdl3"

Game :: struct {
	time_s:      f32,
	ticks:       u64,
	ticks_ns:    u64,
	deltatime:   f32, // in seconds
	movedir:     [2]f32,
	mouse_delta: [2]f32,
	rot:         [3]f32, // yaw pitch roll
	freecam:     bool,

	// kernel
	k:           kernel.Kernel,

	// render
	r:           ^renderer.Renderer,
	card:        renderer.Shape,
}

main :: proc() {
	context.logger = log.create_console_logger()
	when ODIN_DEBUG {
		sdl.SetLogPriorities(.VERBOSE)
		sdl.SetHint(sdl.HINT_RENDER_VULKAN_DEBUG, "1")
	}
	s: Game

	// init sdl
	ok := sdl.Init({.VIDEO});sdle.err(ok)

	gpu := sdl.CreateGPUDevice({.SPIRV}, true, "vulkan");sdle.err(gpu)
	window := sdl.CreateWindow("buffer", 1920, 1080, {.FULLSCREEN});sdle.err(window)

	err: runtime.Allocator_Error
	s.r, err = renderer.init(gpu, window)
	if err != nil do log.panic(err)

	last_ticks := sdl.GetTicks()
	s.time_s = f32(last_ticks) / 1000

	s.r.cam.pos.y = 1
	s.r.cam.pos.z = 1

	load_assets(&s)

	main_loop: for {
		temp_mem := runtime.default_temp_allocator_temp_begin()
		defer runtime.default_temp_allocator_temp_end(temp_mem)

		new_ticks := sdl.GetTicks()
		s.deltatime = f32(new_ticks - s.ticks) / 1000
		s.time_s = f32(new_ticks) / 1000
		s.ticks = new_ticks
		s.ticks_ns = sdl.GetTicksNS()
		// process events
		ev: sdl.Event
		for sdl.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT:
				break main_loop
			case .KEY_DOWN:
				#partial switch ev.key.scancode {
				case .ESCAPE:
					break main_loop
				}
			}
			freecam_eventhandle(&s, ev)
		}
		// update state
		freecam_update(&s)
		render(&s)
	}
}

