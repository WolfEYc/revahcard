package main


import sdle "../lib/sdle"
import "core:math"
import lal "core:math/linalg"
import sdl "vendor:sdl3"

import "../renderer"
freecam_update :: proc(s: ^GameState, r: ^renderer.Renderer) {
	defer s.mouse_delta = {0, 0}
	if !s.freecam do return
	rotspeed :: 0.05
	s.rot.x = math.wrap(s.rot.x - s.mouse_delta.x * rotspeed, 360)
	s.rot.y = math.clamp(s.rot.y - s.mouse_delta.y * rotspeed, -89, 89)

	rot_mat := lal.matrix3_from_yaw_pitch_roll(
		math.to_radians(s.rot.x),
		math.to_radians(s.rot.y),
		math.to_radians(s.rot.z),
	)
	forward := rot_mat * [3]f32{0, 0, -1}
	right := rot_mat * [3]f32{1, 0, 0}

	if s.movedir.x != 0 || s.movedir.y != 0 {
		cam_movedir := forward * s.movedir.y + right * s.movedir.x
		norm_movedir := lal.normalize(cam_movedir)
		movespeed :: 10.0
		r.cam.pos += norm_movedir * movespeed * s.deltatime
	}
	r.cam.target = r.cam.pos + forward
}

freecam_eventhandle :: proc(s: ^GameState, r: ^renderer.Renderer, ev: sdl.Event) {
	#partial switch ev.type {
	case .KEY_DOWN:
		#partial switch ev.key.scancode {
		case .W:
			s.movedir.y = 1
		case .A:
			s.movedir.x = -1
		case .S:
			s.movedir.y = -1
		case .D:
			s.movedir.x = 1
		}
	case .KEY_UP:
		#partial switch ev.key.scancode {
		case .Z:
			when ODIN_DEBUG {
				s.freecam = !s.freecam
				ok := sdl.SetWindowRelativeMouseMode(r._window, s.freecam);sdle.err(ok)
			}
		case .W:
			if s.movedir.y == 1 {
				s.movedir.y = 0
			}
		case .A:
			if s.movedir.x == -1 {
				s.movedir.x = 0
			}
		case .S:
			if s.movedir.y == -1 {
				s.movedir.y = 0
			}
		case .D:
			if s.movedir.x == 1 {
				s.movedir.x = 0
			}
		}
	case .MOUSE_MOTION:
		s.mouse_delta += {ev.motion.xrel, ev.motion.yrel}
	}

}

