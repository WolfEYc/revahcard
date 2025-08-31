package renderer

import "core:math"

import "../lib/sdle"
import "base:runtime"
import "core:log"
import "core:mem"
import sdl "vendor:sdl3"


Shape :: struct {
	pos_buf:     sdl.GPUBufferBinding,
	index_buf:   sdl.GPUBufferBinding,
	num_verts:   u32,
	num_indices: u32,
	material:    Model_Material,
}

// trianglefan is assumed, 0 pos is added as 0, 0, 0
gen_shape :: proc(r: ^Renderer, positions: [][3]f32) -> (shape: Shape) {
	assert(len(positions) >= 3)
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)

	shape.material = Model_Material {
		normal_scale = 1,
		ao_strength  = 0,
		color        = 1,
		bindings     = r._tex_binds,
	}
	shape.num_verts = u32(len(positions)) + 1
	shape.num_indices = (shape.num_verts - 1) * 3
	idx_buf_size := size_of(u16) * shape.num_indices
	shape.index_buf.buffer = sdl.CreateGPUBuffer(
	r._gpu,
	{
		usage = {.INDEX},
		size  = idx_buf_size, // trianglefan
	},
	);sdle.err(shape.index_buf.buffer)
	vert_buf_size := size_of([3]f32) * shape.num_verts
	shape.pos_buf.buffer = sdl.CreateGPUBuffer(
	r._gpu,
	{
		usage = {.VERTEX},
		size  = vert_buf_size, // beig
	},
	);sdle.err(shape.pos_buf.buffer)
	tbuf := sdl.CreateGPUTransferBuffer(
		r._gpu,
		{usage = .UPLOAD, size = vert_buf_size + idx_buf_size},
	);sdle.err(tbuf)
	tbuf_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(r._gpu, tbuf, false)
	idx_buf := transmute([^]u16)tbuf_mem
	idx_buf[0] = 0
	idx_buf[1] = 1
	idx_buf[2] = 2
	fan: u16 = 3
	fan_end := u16(shape.num_indices) - 3
	for i: u16 = 3; i < fan_end; i += 3 {
		idx_buf[i] = 0
		idx_buf[i + 1] = fan - 1
		idx_buf[i + 2] = fan
		fan += 1
	}
	idx_buf[shape.num_indices - 3] = 0
	idx_buf[shape.num_indices - 2] = u16(shape.num_verts) - 1
	idx_buf[shape.num_indices - 1] = 1

	log.infof("rrect idx_buf: %v", idx_buf[:shape.num_indices])
	vert_start := idx_buf_size + size_of([3]f32)
	vert_mem := transmute([^][3]f32)tbuf_mem[idx_buf_size:]
	vert_mem[0] = 0
	mem.copy_non_overlapping(
		tbuf_mem[vert_start:],
		raw_data(positions),
		len(positions) * size_of([3]f32),
	)
	sdl.UnmapGPUTransferBuffer(r._gpu, tbuf)
	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = tbuf},
		{buffer = shape.index_buf.buffer, size = idx_buf_size},
		false,
	)
	sdl.UploadToGPUBuffer(
		r._copy_pass,
		{transfer_buffer = tbuf, offset = idx_buf_size},
		{buffer = shape.pos_buf.buffer, size = vert_buf_size},
		false,
	)
	sdl.ReleaseGPUTransferBuffer(r._gpu, tbuf)
	log.infof("shape idx binding: %v", shape.index_buf)
	log.infof("shape vert binding: %v", shape.pos_buf)
	return
}

Draw_Shape_Req :: struct {
	shape:     ^Shape,
	transform: mat4,
	entity_id: Entity_Id,
}

draw_shape :: proc(r: ^Renderer, req: Draw_Shape_Req) {
	if r._lens[.DRAW_REQ] + r._lens[.TEXT_DRAW] == MAX_RENDER_NODES do return
	shape := req.shape
	r._draw_call_reqs[r._lens[.DRAW_REQ]] = Draw_Call_Req {
		.PIPELINE_IDX  = uint(Pipeline_Idx.SHAPE),
		.MODEL_IDX     = uint(uintptr(shape)),
		.MATERIAL_IDX  = 0,
		.PRIMITIVE_IDX = 0,
		.TRANSFORM_IDX = uint(r._lens[.DRAW_REQ]),
	}
	r._draw_entity_ids[r._lens[.DRAW_REQ]] = req.entity_id
	r._draw_transforms[r._lens[.DRAW_REQ]] = req.transform
	r._lens[.DRAW_REQ] += 1
}

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
	log.infof("circle pt: %v", pt)
	return
}

gen_circle_positions :: proc(gen: Circle_Gen) -> (positions: [][3]f32) {
	positions = make([][3]f32, gen.quality)
	for i: uint = 0; i < gen.quality; i += 1 {
		positions[i].xy = gen_circle_pt(gen, i)
	}
	return
}

RRect_Gen :: struct {
	size:        [2]f32,
	centers:     [4][2]f32,
	arc_quality: uint,
	circle_gen:  Circle_Gen,
}

RRect_Input :: struct {
	size:    [2]f32,
	radius:  f32,
	quality: uint,
}

new_rrect_gen :: proc(input: RRect_Input) -> (rrect: RRect_Gen) {
	half := input.size / 2 - input.radius
	rrect = RRect_Gen {
		size        = input.size,
		centers     = {
			{half.x, half.y}, //top right
			{-half.x, half.y}, // top left
			{-half.x, -half.y}, // bot left
			{half.x, -half.y}, //bot right
		},
		arc_quality = input.quality / 4,
		circle_gen  = new_circle_gen(input.radius, input.quality),
	}
	return
}

gen_rrect_pt :: proc(rrect: RRect_Gen, i: uint) -> (pt: [2]f32) {
	corner_idx := i / rrect.arc_quality
	pt = rrect.centers[corner_idx] + gen_circle_pt(rrect.circle_gen, i)
	return
}

gen_rrect_positions :: proc(input: RRect_Input, gen: RRect_Gen) -> (positions: [][3]f32) {
	positions = make([][3]f32, input.quality)
	for i: uint = 0; i < input.quality; i += 1 {
		positions[i].xy = gen_rrect_pt(gen, i)
	}
	return
}

gen_rrect :: proc(r: ^Renderer, input: RRect_Input) -> (shape: Shape) {
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)

	gen := new_rrect_gen(input)
	positions := gen_rrect_positions(input, gen)
	log.infof("pozitions: %v", positions)
	shape = gen_shape(r, positions)
	return
}

