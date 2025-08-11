package animation

import "base:intrinsics"

Interpolated :: struct(
	$T: typeid
) where intrinsics.type_is_float(T) ||
	intrinsics.type_is_float(intrinsics.type_elem_type(T))
{
	start:   T,
	end:     T,
	start_s: f32,
	end_s:   f32,
	ease:    Ease,
}

set_target :: proc(x: ^Interpolated($T), now_s: f32, target: T) {
	x.start = interpolate(x^, now_s)
	x.start_s = now_s
	x.end = target
}

interpolate_scalar :: proc(x: Interpolated($T), now_s: f32) -> (val: T) {
	dt := (now_s - x.start_s) / (x.end_s - x.start_s)
	dt = clamp(dt, 0, 1) // maybe unclamped version too?
	dt1 := ease(x.ease, dt)
	delta := x.end - x.start
	val = x.start + delta * T(dt1)
	return
}

interpolate_vector :: proc(x: Interpolated([$N]$E), now_s: f32) -> (val: E) {
	dt := (now_s - x.start_s) / (x.end_s - x.start_s)
	dt = clamp(dt, 0, 1) // maybe unclamped version too?
	dt1 := ease(x.ease, dt)
	delta := x.end - x.start
	val = x.start + delta * E(dt1)
	return
}
interpolate_quaternion64 :: proc(
	x: Interpolated(quaternion64),
	now_s: f32,
) -> (
	val: quaternion64,
) {
	dt := (now_s - x.start_s) / (x.end_s - x.start_s)
	dt = clamp(dt, 0, 1) // maybe unclamped version too?
	dt1 := ease(x.ease, dt)
	delta := x.end - x.start
	val = x.start + delta * u16(dt1)
	return
}

interpolate :: proc {
	interpolate_scalar,
	interpolate_vector,
	interpolate_quaternion64,
}

Hi :: Interpolated(quaternion256)
Hi_B :: Interpolated(quaternion64)

