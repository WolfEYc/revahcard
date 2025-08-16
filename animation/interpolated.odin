package animation

import "base:intrinsics"
import "core:math"
import lal "core:math/linalg"

Interpolated :: struct($T: typeid) where intrinsics.type_is_float(intrinsics.type_elem_type(T)) {
	start:   T,
	end:     T,
	start_s: f32,
	end_s:   f32,
	ease:    Ease,
}

interpolate_normal :: proc(
	x: Interpolated($T),
	now_s: f32,
) -> (
	val: T,
) where !intrinsics.type_is_quaternion(T) {
	ELEM_TYPE :: intrinsics.type_elem_type(T)
	dt := (now_s - x.start_s) / (x.end_s - x.start_s)
	dt = clamp(dt, 0, 1) // maybe unclamped version too?
	dt1 := ease(x.ease, dt)
	delta := x.end - x.start
	lal.lerp(x.start, x.end, ELEM(dt1))
	return
}

interpolate_quaternion :: proc(
	x: Interpolated($T),
	now_s: f32,
) -> (
	val: T,
) where intrinsics.type_is_quaternion(T) {
	ELEM_TYPE :: intrinsics.type_elem_type(T)
	dt := (now_s - x.start_s) / (x.end_s - x.start_s)
	dt = clamp(dt, 0, 1) // maybe unclamped version too?
	dt1 := ease(x.ease, dt)
	delta := x.end - x.start
	val = lal.quaternion_slerp(x.start, x.end, ELEM_TYPE(dt1))
	return
}

interpolate :: proc {
	interpolate_normal,
	interpolate_quaternion,
}

set_target :: proc(x: ^Interpolated($T), now_s: f32, target: T) {
	x.start = interpolate(x^, now_s)
	x.start_s = now_s
	x.end = target
}

