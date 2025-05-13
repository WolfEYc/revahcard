package renderer

import "core:io"
import "core:log"
import os "core:os/os2"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

Obj :: struct {
	pos: [dynamic][3]f32,
	uv:  [dynamic][2]f32,
	idx: [dynamic]Face,
}

Face :: struct {
	pos: uint,
	uv:  uint,
}

obj_load :: proc(file_name: string) -> (obj: Obj) {
	file_path := filepath.join(
		{dist_dir, shader_dir, file_name},
		allocator = context.temp_allocator,
	)
	bytes, err := os.read_entire_file_from_path(file_path, context.temp_allocator)
	if err != nil {
		log.panicf("obj os file open err: %v", err)
	}

	text := string(bytes)
	line_no := 0
	for line in strings.split_lines_iterator(&text) {
		line_no += 1
		if len(line) == 0 do continue
		switch line[0] {
		case 'v':
			switch line[1] {
			case ' ':
				if obj.pos == nil {
					obj.pos = make([dynamic][3]f32, allocator = context.temp_allocator)
				}
				pos, err := parse_f32s(3, line[2:])
				if err != nil {
					log.panicf(
						"err in parsing %s pos, on line %d, reason: %v",
						file_name,
						line_no,
						err,
					)
				}
				append(&obj.pos, pos)
			case 't':
				if obj.uv == nil {
					obj.uv = make([dynamic][2]f32, allocator = context.temp_allocator)
				}
				uv, err := parse_f32s(2, line[:3])
				if err != nil {
					log.panicf(
						"err in parsing %s uv, on line %d, reason: %v",
						file_name,
						line_no,
						err,
					)
				}
				append(&obj.uv, uv)
			}
		case 'f':
			if obj.idx == nil {
				obj.idx = make([dynamic]Face, allocator = context.temp_allocator)
			}
			faces, err := parse_faces(line[2:])
			if err != nil {
				log.panicf(
					"err in parsing %s face, on line %d, reason: %v",
					file_name,
					line_no,
					err,
				)
			}
			append_elems(&obj.idx, ..faces)
		}
	}
	return
}

Parse_Err :: enum {
	None = 0,
	Not_Enough_Numbas,
	Strconv_Err,
}

parse_f32s :: proc($N: uint, s: string) -> (nums: [N]f32, err: Parse_Err) {
	s := s
	for i in 0 ..< N {
		stop_idx := strings.index_rune(s, ' ')
		if stop_idx == -1 {
			err = .Not_Enough_Numbas
			return
		}
		ok: bool
		nums[i], ok = strconv.parse_f32(s[:stop_idx])
		if !ok {
			err = .Strconv_Err
			return
		}
		s = s[stop_idx + 1:]
	}
}

parse_faces :: proc(s: string) -> (faces: [3]Face, err: Parse_Err) {
	s := s
	i := 0
	for face_str in strings.split_iterator(&s, " ") {
		j := 0
		for num_str in strings.split_iterator(&face_str, "/") {
			faces[i][j], ok = strconv.parse_uint(num_str)
			if !ok {
				err = .Strconv_Err
				return
			}
			j += 1
		}
		if j != 3 {
			err = .Not_Enough_Numbas
			return
		}
		i += 1
	}
	if i != 3 {
		err = .Not_Enough_Numbas
		return
	}
}

//TODO
obj_to_mesh :: proc(obj: Obj) -> (mesh: Mesh) {

}

