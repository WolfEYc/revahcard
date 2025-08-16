package renderer

import "core:math"


Circle_Gen :: struct {
	radius:  f32,
	quality: uint,
	da:      f32,
}

new_circle_gen :: proc(radius: f32, quality: uint) -> (circle: Circle_Gen) {
	circle = Circle_Gen {
		radius  = radius,
		quality = quality,
		da      = 2 * math.PI / f32(quality),
	}
	return
}

gen_circle_pt :: proc(circle: Circle_Gen, i: uint) -> (pt: [2]f32) {
	angle := circle.da * f32(i)
	pt = circle.radius * [2]f32{math.cos(angle), math.sin(angle)}
	return
}

gen_circle :: proc(circle: Circle_Gen) -> (model: Model) {

	return
}

RRect_Gen :: struct {
	size:        [2]f32,
	centers:     [4][2]f32,
	arc_quality: uint,
	circle_gen:  Circle_Gen,
}

new_rrect_gen :: proc(size: [2]f32, radius: f32, quality: uint) -> (rrect: RRect_Gen) {
	rrect = RRect_Gen {
		size        = size,
		centers     = {
			{radius, radius}, // top left
			{size.x - radius, radius}, //top right
			{radius, size.y - radius}, // bot left
			{size.x - radius, size.y - radius}, //bot right
		},
		arc_quality = quality / 4,
		circle_gen  = new_circle_gen(radius, quality),
	}
	return
}

gen_rrect_pt :: proc(rrect: RRect_Gen, i: uint) -> (pt: [2]f32) {
	corner_idx := i / rrect.arc_quality
	pt = rrect.centers[corner_idx] + gen_circle_pt(rrect.circle_gen, i - corner_idx)
	return
}

gen_rrect :: proc(gen: RRect_Gen) -> (model: Model) {

	return
}

