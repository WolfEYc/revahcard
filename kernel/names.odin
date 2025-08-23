package kernel

import "base:runtime"
import "core:bufio"
import "core:encoding/csv"
import "core:encoding/hex"
import "core:log"
import vmem "core:mem/virtual"
import os "core:os/os2"
import "core:strings"

Name_DB :: struct {
	adj:       [dynamic]string,
	color:     [dynamic]Name_Color,
	food:      [dynamic]string,
	arr_arena: vmem.Arena,
	arr_alloc: runtime.Allocator,
	str_arena: vmem.Arena,
	str_alloc: runtime.Allocator,
}

Name_Color :: struct {
	name:  string,
	color: [4]f32,
}

words_dir :: "words"
adj_fpath :: words_dir + os.Path_Separator_String + "adjectives.txt"
color_fpath :: words_dir + os.Path_Separator_String + "colors.csv"
foods_fpath :: words_dir + os.Path_Separator_String + "foods.txt"

hex_to_color :: proc(hex_str: string) -> (color: [4]f32, ok: bool) {
	r: u8
	g: u8
	b: u8
	r, ok = hex.decode_sequence(hex_str[:2])
	if !ok do return
	g, ok = hex.decode_sequence(hex_str[2:][:2])
	if !ok do return
	b, ok = hex.decode_sequence(hex_str[4:][:2])
	if !ok do return

	color.rgb = [3]f32{f32(r), f32(g), f32(b)}
	color.a = 255
	color /= 255
	return
}


make_name_db :: proc() -> (db: Name_DB, err: os.Error) {
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)
	f: ^os.File

	alloc_err: runtime.Allocator_Error
	alloc_err = vmem.arena_init_growing(&db.arr_arena);assert(alloc_err == nil)
	db.arr_alloc = vmem.arena_allocator(&db.arr_arena)
	alloc_err = vmem.arena_init_growing(&db.str_arena);assert(alloc_err == nil)
	db.str_alloc = vmem.arena_allocator(&db.str_arena)

	adj: {
		f, err = os.open(adj_fpath)
		if err != nil do return
		defer os.close(f)
		s: bufio.Scanner
		bufio.scanner_init(&s, f.stream, context.temp_allocator)
		defer bufio.scanner_destroy(&s)
		db.adj = make([dynamic]string, db.arr_alloc)
		for bufio.scanner_scan(&s) {
			text := bufio.scanner_text(&s)
			text_cpy := strings.clone(text, db.str_alloc)
			append(&db.adj, text_cpy)
		}
	}
	colors: {
		f, err = os.open(adj_fpath)
		if err != nil do return
		defer os.close(f)
		r: csv.Reader
		r.trim_leading_space = true
		r.reuse_record = true
		r.reuse_record_buffer = true
		csv.reader_init(&r, f.stream, context.temp_allocator)
		defer csv.reader_destroy(&r)
		db.color = make([dynamic]Name_Color, db.arr_alloc)
		for row, i, err in csv.iterator_next(&r) {
			if err != nil do return
			name_color: Name_Color
			hex_str := row[1]
			ok: bool
			name_color.color, ok = hex_to_color(hex_str)
			name_color.name = strings.clone(row[0], db.str_alloc)
			if !ok {
				log.errorf("card color=%s hex could not be parsed, row=%d", name_color.name, i)
				continue
			}
			append(&db.color, name_color)
		}
	}
	return
}

