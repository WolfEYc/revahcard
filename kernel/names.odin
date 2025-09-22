package kernel

import "base:runtime"
import "core:bufio"
import "core:encoding/hex"
import "core:hash"
import "core:log"
import vmem "core:mem/virtual"
import os "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:testing"

Name_DB :: struct {
	adj:        []string,
	color:      []Name_Color,
	food:       []string,
	adj_file:   []byte,
	color_file: []byte,
	food_file:  []byte,
	arena:      vmem.Arena,
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

Color_Err_Enum :: enum {
	NONE,
	NAME_NOT_FIRST_COL,
	COLOR_NOT_SECOND_COL,
}
Color_Err :: union #shared_nil {
	os.Error,
	Color_Err_Enum,
}
Food_Err :: distinct os.Error
Adj_Err :: distinct os.Error
Err_Name_Db :: union #shared_nil {
	Color_Err,
	Adj_Err,
	Food_Err,
}

make_name_db :: proc() -> (db: Name_DB, err: Err_Name_Db) {
	alloc_err := vmem.arena_init_growing(&db.arena);assert(alloc_err == nil)
	default_alloc := context.allocator
	context.allocator = vmem.arena_allocator(&db.arena)
	defer context.allocator = default_alloc
	ferr: os.Error
	adj: {
		db.adj_file, ferr = os.read_entire_file(adj_fpath, context.allocator)
		if ferr != nil {
			err = Adj_Err(ferr)
			return
		}
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
		db.color_file, ferr = os.read_entire_file(color_fpath, context.allocator)
		if ferr != nil {
			err = Color_Err(ferr)
			return
		}
		s := string(db.color_file)
		line_count := strings.count(s, "\n")
		db.color = make([]Name_Color, line_count)

		i := 0
		for line in strings.split_lines_iterator(&s) {
			defer i += 1
			split := strings.index_rune(line, ',')
			if split == -1 || split == len(line) - 1 {
				continue
			}
			row := [2]string{line[:split], line[split + 1:]}
			if i == 0 {
				if row[0] != "name" {
					err = Color_Err(Color_Err_Enum.NAME_NOT_FIRST_COL)
					return
				}
				if row[1] != "color" {
					err = Color_Err(Color_Err_Enum.COLOR_NOT_SECOND_COL)
					return
				}
				continue
			}
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
		db.food_file, ferr = os.read_entire_file(food_fpath, context.allocator)
		if ferr != nil {
			err = Food_Err(ferr)
			return
		}
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

destroy_name_db :: proc(db: ^Name_DB) {
	vmem.arena_destroy(&db.arena)
	db^ = {}
}

@(test)
test_make_and_delete_names_db :: proc(t: ^testing.T) {
	db, err := make_name_db()
	testing.expectf(t, err == nil, "err making name db, reason: %v", err)
	destroy_name_db(&db)
}

Card_Name :: struct {
	adj:   string,
	color: Name_Color,
	food:  string,
}

card_to_name :: proc(db: Name_DB, card: Card) -> (name: Card_Name) {
	food_data_mat := [2][4]byte {
		transmute([4]byte)card.effects,
		transmute([4]byte)card.effect_value,
	}
	food_data := transmute([size_of(food_data_mat)]byte)food_data_mat
	food_hash := hash.fnv32a(food_data[:])
	log.infof("freezer=%v", db.food)
	food_idx := food_hash % u32(len(db.food))
	name.food = db.food[food_idx]

	adj_data_mat := [2][4]byte{transmute([4]byte)card.targets, transmute([4]byte)card.target_count}
	adj_data := transmute([size_of(adj_data_mat)]byte)adj_data_mat
	adj_hash := hash.fnv32a(adj_data[:])
	adj_idx := adj_hash % u32(len(db.adj))
	name.adj = db.adj[adj_idx]

	color_data_mat := [2][4]byte {
		transmute([4]byte)card.effect_value,
		transmute([4]byte)card.target_count,
	}
	color_data := transmute([size_of(color_data_mat)]byte)color_data_mat
	color_hash := hash.fnv32a(color_data[:])
	log.infof("refrigerator=%v", db.color)
	color_idx := color_hash % u32(len(db.color))
	name.color = db.color[color_idx]
	return
}

@(test)
test_card_to_name :: proc(t: ^testing.T) {
	db, err := make_name_db()
	testing.expectf(t, err == nil, "err making name db, reason: %v", err)
	defer destroy_name_db(&db)
	card := Card {
		effects      = {.ATTACK, .SHARPEN},
		effect_value = 3,
		targets      = {.UP, .DOWN},
		target_count = 2,
		hp           = 12,
	}
	name := card_to_name(db, card)
	color := name.color.color
	testing.expect(t, len(name.adj) > 0, "adj was empty")
	testing.expect(t, len(name.color.name) > 0, "color name was empty")
	color_sum := color.r + color.g + color.b
	testing.expect(t, color_sum > 0, "color was black")
	testing.expect(t, len(name.food) > 0, "food name was empty")
	log.infof("card_name=%v", name)
}

