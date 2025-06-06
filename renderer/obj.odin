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
	pos_idx:    uint,
	uv_idx:     uint,
	normal_idx: uint,
}

Mesh :: struct {
	verts: []Vertex_Data,
	idxs:  []u16,
}
Vertex_Data :: struct {
	pos:    [3]f32,
	uv:     [2]f32,
	normal: [3]f32,
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
	positions := make([dynamic][3]f32)
	defer delete(positions)
	uvs := make([dynamic][2]f32)
	defer delete(uvs)
	normals := make([dynamic][3]f32)
	defer delete(normals)
	faces := make([dynamic][3]Face)
	defer delete(faces)
	line_no := 0
	for bufio.scanner_scan(&scanner) {
		line := bufio.scanner_text(&scanner)
		line_no += 1
		if len(line) == 0 do continue
		switch line[0] {
		case 'v':
			switch line[1] {
			case ' ':
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
			case 'n':
				normal, err := parse_f32s(3, line[3:])
				if err != nil {
					log.panicf(
						"err in parsing %s normal, on line %d, reason: %v",
						file_name,
						line_no,
						err,
					)
				}
				append(&normals, normal)
			}
		case 'f':
			parsed_faces, err := parse_faces(line[2:])
			if err != nil {
				log.panicf(
					"err in parsing %s face, on line %d, reason: %v",
					file_name,
					line_no,
					err,
				)
			}
			append(&faces, parsed_faces)
		}
	}
	// log.debug("done parsing obj!")
	mesh.verts = make([]Vertex_Data, len(faces) * 3, allocator = context.temp_allocator)
	mesh.idxs = make([]u16, len(faces) * 3, allocator = context.temp_allocator)
	vert_idx := 0
	for face in faces {
		for vert in face {
			mesh.verts[vert_idx] = Vertex_Data {
				pos    = positions[vert.pos_idx],
				uv     = uvs[vert.uv_idx],
				normal = normals[vert.normal_idx],
			}
			mesh.idxs[vert_idx] = u16(vert_idx)
			vert_idx += 1
		}
	}
	// log.debug("done linking faces!")
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
		splits := strings.split_n(str, "/", 4, allocator = context.temp_allocator)
		if len(splits) > 3 {
			err = .Too_Many_Numba
		}
		if len(splits) < 3 {
			err = .Not_Enough_Numbas
		}
		numbas: [3]uint
		for split, i in splits {
			ok: bool
			numbas[i], ok = strconv.parse_uint(split, base = 10)
			if !ok {
				err = .Strconv_Err
				return
			}
			numbas[i] -= 1
		}
		faces[i].pos_idx = numbas[0]
		faces[i].uv_idx = numbas[1]
		faces[i].normal_idx = numbas[2]
	}
	return
}

