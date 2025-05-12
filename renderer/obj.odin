package renderer

import "core:io"
import os "core:os/os2"
import "core:strings"

Obj :: struct {
	pos: [][3]f32,
	uv:  [][2]f32,
	idx: []Face,
}

Face :: struct {
	pos: uint,
	uv:  uint,
}

obj_load :: proc(file_name: string) -> (obj: Obj) {
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)

	file_path := filepath.join(
		{constants.dist_dir, constants.shader_dir, file_name},
		allocator = context.temp_allocator,
	)
	bytes, err := os.read_entire_file_from_path(file_path, context.temp_allocator)
	if err != nil {
		log.panicf("obj os file open err: %v", err)
	}

	pos: [dynamic][3]f32
	uv: [dynamic][2]f32
	idx: [dynamic]Face

	text := string(bytes)
	for line in strings.split_lines_iterator(&text) {
		if len(line) == 0 do continue
		switch line[0] {
		case 'v':
			switch line[1] {
			case ' ':
				if pos == nil {
					pos = make([dynamic][3]f32)
				}

			case 't':

			}
		case 'f':

		}
	}


	return
}

