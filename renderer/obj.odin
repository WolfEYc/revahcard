package renderer

import "base:runtime"
import "core:bufio"
import "core:io"
import "core:log"
import os "core:os/os2"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

Face :: struct {
	pos: uint,
	uv:  uint,
}

Mesh :: struct {
	verts: []Vertex_Data,
	idxs:  [dynamic]u16,
}
Vertex_Data :: struct {
	pos: [3]f32,
	uv:  [2]f32,
}
obj_load :: proc(file_name: string) -> (mesh: Mesh) {
	file_path := filepath.join(
		{dist_dir, model_dir, file_name},
		allocator = context.temp_allocator,
	)
	f, err := os.open(file_path)
	if err != nil {
		log.panicf("obj os file open err: %v", err)
	}
	s := os.to_stream(f)
	scanner: bufio.Scanner
	bufio.scanner_init(&scanner, s)
	defer bufio.scanner_destroy(&scanner)
	positions: [dynamic][3]f32
	uvs: [dynamic][2]f32
	line_no := 0
	for bufio.scanner_scan(&scanner) {
		line := bufio.scanner_text(&scanner)
		line_no += 1
		if len(line) == 0 do continue
		switch line[0] {
		case 'v':
			switch line[1] {
			case ' ':
				if positions == nil {
					positions = make([dynamic][3]f32, allocator = context.temp_allocator)
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
				append(&positions, pos)
			case 't':
				if uvs == nil {
					uvs = make([dynamic][2]f32, allocator = context.temp_allocator)
				}
				uv, err := parse_f32s(2, line[3:])
				if err != nil {
					log.panicf(
						"err in parsing %s uv, on line %d, reason: %v",
						file_name,
						line_no,
						err,
					)
				}
				append(&uvs, uv)
			}
		case 'f':
			if mesh.verts == nil {
				mesh.verts = make(
					[]Vertex_Data,
					len(positions),
					allocator = context.temp_allocator,
				)
				mesh.idxs = make(
					[dynamic]u16,
					0,
					len(positions),
					allocator = context.temp_allocator,
				)
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
			// bean: [3]u16
			for face, i in faces {
				mesh.verts[face.pos] = Vertex_Data {
					pos = positions[face.pos],
					uv  = uvs[face.uv],
				}
				// bean[i] = u16(face.pos)
				append(&mesh.idxs, u16(face.pos))
			}
		// log.debugf("%v", bean)
		}
	}
	return
}

Parse_Err :: enum {
	None = 0,
	Not_Enough_Numbas,
	Strconv_Err,
	Too_Many_Numba,
}

parse_f32s :: proc($N: uint, s: string) -> (nums: [N]f32, err: Parse_Err) {
	s := s
	for i in 0 ..< N {
		if len(s) == 0 {
			err = .Not_Enough_Numbas
			return
		}
		stop_idx := strings.index_rune(s, ' ')
		if stop_idx == -1 {
			stop_idx = len(s)
		}
		ok: bool
		nums[i], ok = strconv.parse_f32(s[:stop_idx])
		if !ok {
			err = .Strconv_Err
			return
		}
		if stop_idx == len(s) {
			s = s[:0]
		} else {
			s = s[stop_idx + 1:]
		}
	}
	return
}

parse_faces :: proc(s: string) -> (faces: [3]Face, err: Parse_Err) {
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)

	strs, alloc_err := strings.split_n(
		s,
		" ",
		4,
		allocator = context.temp_allocator,
	);assert(alloc_err == nil)
	if len(strs) > 3 {
		err = .Too_Many_Numba
		return
	}
	if len(strs) < 3 {
		err = .Not_Enough_Numbas
		return
	}
	for str, i in strs {
		splits := strings.split_n(str, "/", 3, allocator = context.temp_allocator)
		if len(strs) < 3 {
			err = .Not_Enough_Numbas
		}
		ok: bool
		faces[i].pos, ok = strconv.parse_uint(splits[0], base = 10)
		if !ok {
			err = .Strconv_Err
			return
		}
		faces[i].uv, ok = strconv.parse_uint(splits[1], base = 10)
		if !ok {
			err = .Strconv_Err
			return
		}
		faces[i].pos -= 1
		faces[i].uv -= 1
	}
	return
}

