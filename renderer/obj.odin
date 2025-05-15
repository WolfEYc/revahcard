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
				uv, err := parse_f32s(2, line[:3])
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
			for face in faces {
				mesh.verts[face.pos] = Vertex_Data {
					pos = positions[face.pos],
					uv  = uvs[face.uv],
				}
				append(&mesh.idxs, u16(face.pos))
			}
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
	return
}

parse_faces :: proc(s: string) -> (faces: [3]Face, err: Parse_Err) {
	s := s
	for i in 0 ..< 3 {
		first_slash := strings.index_byte(s, '/')
		if first_slash == -1 {
			err = .Not_Enough_Numbas
			return
		}
		pos_str := s[:first_slash]
		uv_str := s[first_slash + 1:]
		ok: bool
		faces[i].pos, ok = strconv.parse_uint(pos_str, base = 10)
		if !ok {
			err = .Strconv_Err
			return
		}
		faces[i].uv, ok = strconv.parse_uint(uv_str, base = 10)
		if !ok {
			err = .Strconv_Err
			return
		}
		first_space := strings.index_byte(s, ' ')
		if first_space == -1 {
			err = .Not_Enough_Numbas
			return
		}
		s = s[first_space:]
	}
	return
}

