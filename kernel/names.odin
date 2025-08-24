package kernel

import "base:runtime"
import "core:bufio"
import "core:bytes"
import "core:encoding/csv"
import "core:encoding/hex"
import "core:hash"
import "core:log"
import mem "core:mem"
import vmem "core:mem/virtual"
import os "core:os/os2"
import "core:path/filepath"
import "core:strings"

Name_DB :: struct {
	adj:        []string,
	color:      []Name_Color,
	food:       []string,
	adj_file:   []byte,
	color_file: []byte,
	food_file:  []byte,
}

Name_Color :: struct {
	name:  string,
	color: [4]f32,
}

words_dir :: "words"
adj_fpath :: words_dir + os.Path_Separator_String + "adjectives.txt"
color_fpath :: words_dir + os.Path_Separator_String + "colors.csv"
food_fpath :: words_dir + os.Path_Separator_String + "foods.txt"

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
	adj: {
		db.adj_file, err = os.read_entire_file(adj_fpath, context.allocator)
		if err != nil do return
		iter := string(db.adj_file)
		line_count := strings.count(iter, "\n")
		db.adj = make([]string, line_count)
		i := 0
		for line in strings.split_lines_iterator(&iter) {
			db.adj[i] = line
			i += 1
		}
	}
	colors: {
		db.color_file, err = os.read_entire_file(color_fpath, context.allocator)
		r: csv.Reader
		r.trim_leading_space = true
		r.reuse_record = true
		r.reuse_record_buffer = true
		s := string(db.color_file)
		csv.reader_init_with_string(&r, s)
		line_count := strings.count(s, "\n")
		db.color = make([]Name_Color, line_count)
		for row, i, err in csv.iterator_next(&r) {
			if err != nil do return
			name_color: Name_Color
			hex_str := row[1]
			ok: bool
			name_color.color, ok = hex_to_color(hex_str)
			name_color.name = row[0]
			if !ok {
				log.errorf(
					"color_name=%s hex=%s could not be parsed, row=%d",
					name_color.name,
					hex_str,
					i,
				)
				continue
			}
			db.color[i] = name_color
		}
	}
	food: {
		db.food_file, err = os.read_entire_file(food_fpath, context.allocator)
		if err != nil do return
		iter := string(db.food_file)
		line_count := strings.count(iter, "\n")
		db.food = make([]string, line_count)
		i := 0
		for line in strings.split_lines_iterator(&iter) {
			db.food[i] = line
			i += 1
		}
	}
	return
}

destroy_names_db :: proc(db: Name_DB) {
	delete(db.adj)
	delete(db.color)
	delete(db.food)
	delete(db.adj_file)
	delete(db.color_file)
	delete(db.food_file)
}

Card_Name :: struct {
	adj:   string,
	color: Name_Color,
	food:  string,
}

card_to_name :: proc(db: Name_DB, card: Card) -> (name: Card_Name) {
	food_data_mat := [2][4]byte {
		transmute([4]byte)card.action.effects,
		transmute([4]byte)card.trigger_action.effects,
	}
	food_data := transmute([size_of(food_data_mat)]byte)food_data_mat
	food_hash := hash.fnv32a(food_data[:])
	food_idx := food_hash % u32(len(db.food))
	name.food = db.food[food_idx]

	adj_data_mat := [2][4]byte {
		transmute([4]byte)card.action.targets,
		transmute([4]byte)card.trigger_action.targets,
	}
	adj_data := transmute([size_of(adj_data_mat)]byte)adj_data_mat
	adj_hash := hash.fnv32a(adj_data[:])
	adj_idx := adj_hash % u32(len(db.adj))
	name.adj = db.adj[adj_idx]

	color_data_mat := [4][4]byte {
		transmute([4]byte)card.action.effect_value,
		transmute([4]byte)card.action.target_count,
		transmute([4]byte)card.trigger_action.effect_value,
		transmute([4]byte)card.trigger_action.target_count,
	}
	color_data := transmute([size_of(color_data_mat)]byte)color_data_mat
	color_hash := hash.fnv32a(color_data[:])
	color_idx := color_hash % u32(len(db.color))
	name.color = db.color[color_idx]
	return
}

