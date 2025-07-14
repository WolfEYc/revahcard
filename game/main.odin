package main

import "../lib/glist"
import "../lib/sdle"
import "../renderer"
import "base:runtime"
import "core:log"
import "core:math"
import lal "core:math/linalg"
import "core:math/rand"
import "core:mem"
import sdl "vendor:sdl3"

GameState :: struct {
	ticks:       u64,
	ticks_ns:    u64,
	deltatime:   f32, // in seconds
	movedir:     [2]f32,
	mouse_delta: [2]f32,
	rot:         [3]f32, // yaw pitch roll
	freecam:     bool,
}

main :: proc() {
	context.logger = log.create_console_logger()
	when ODIN_DEBUG {
		sdl.SetLogPriorities(.VERBOSE)
		sdl.SetHint(sdl.HINT_RENDER_VULKAN_DEBUG, "1")
	}

	// init sdl
	ok := sdl.Init({.VIDEO});sdle.err(ok)

	gpu := sdl.CreateGPUDevice({.SPIRV}, true, "vulkan");sdle.err(gpu)
	window := sdl.CreateWindow("buffer", 1920, 1080, {.FULLSCREEN});sdle.err(window)
	r, err := renderer.init(gpu, window)
	if err != nil do log.panic(err)
	err = renderer.load_all_assets(r)
	if err != nil do log.panic(err)

	last_ticks := sdl.GetTicks()
	s: GameState

	drag_racer_idx, has_drag_racer := r.model_map["vehicle-drag-racer.glb"];assert(has_drag_racer)
	drag_racer_model := glist.get(r.models, drag_racer_idx)
	drag_racer_node, has_drag_racer_node :=
		drag_racer_model.node_map["vehicle-drag-racer"];assert(has_drag_racer_node)
	light_cube_idx, has_light_cube := r.model_map["white_light_cube.glb"];assert(has_light_cube)
	r.cam.pos.y = 1
	r.cam.pos.z = 1

	main_loop: for {
		temp_mem := runtime.default_temp_allocator_temp_begin()
		defer runtime.default_temp_allocator_temp_end(temp_mem)

		new_ticks := sdl.GetTicks()
		s.deltatime = f32(new_ticks - s.ticks) / 1000
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
			freecam_eventhandle(&s, r, ev)
		}
		// update state
		freecam_update(&s, r)

		renderer.begin_draw(r)
		{
			deg_per_s :: 90
			micros_per_deg :: 1_000_000 / deg_per_s
			degs := f64(s.ticks_ns / micros_per_deg) / 1000.0
			rads := f32(degs * lal.RAD_PER_DEG)
			quat := lal.quaternion_from_pitch_yaw_roll_f32(0, rads, 0)
			transform := lal.matrix4_from_trs([3]f32{0, 0, 0}, quat, [3]f32{1, 1, 1})
			req := renderer.Draw_Node_Req {
				model_idx = drag_racer_idx,
				transform = transform,
				node_idx  = drag_racer_node,
			}
			renderer.draw_node(r, req)
		}
		{
			deg_per_s :: 90
			micros_per_deg :: 1_000_000 / deg_per_s
			degs := f64(s.ticks_ns / micros_per_deg) / 1000.0
			rads := f32(degs * lal.RAD_PER_DEG)
			quat := lal.quaternion_from_pitch_yaw_roll_f32(0, rads, 0)
			transform1 := lal.matrix4_from_trs([3]f32{1, 0.7, 0}, quat, [3]f32{1, 1, 1})
			transform2 := lal.matrix4_from_trs([3]f32{-1, 0.7, 0}, quat, [3]f32{1, 1, 1})
			req1 := renderer.Draw_Node_Req {
				model_idx = light_cube_idx,
				transform = transform1,
				node_idx  = 1,
			}
			req2 := renderer.Draw_Node_Req {
				model_idx = light_cube_idx,
				transform = transform2,
				node_idx  = 1,
			}
			renderer.draw_node(r, req1)
			renderer.draw_node(r, req2)
		}
		renderer.end_draw(r)

		renderer.begin_render(r)
		renderer.begin_screen_render_pass(r)
		renderer.opaque_pass(r)
		renderer.end_render(r)
	}
}

