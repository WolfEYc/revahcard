package main

import an "../animation"
import "../lib/pool"
import "core:log"


EType :: union {
	^Render_Card,
	^Control,
}

Entity :: struct {
	id:           pool.Pool_Key,
	name:         string,
	variant:      EType,
	_marked_del:  bool,
	interactable: bool,
	pos:          an.Interpolated([3]f32),
	rot:          an.Interpolated(quaternion128),
	hover_pos:    [3]f32,
	hold_pos:     [3]f32,
	standby_pos:  [3]f32,
	hover_rot:    quaternion128,
	hold_rot:     quaternion128,
	standby_rot:  quaternion128,
	hover_ease:   an.Ease,
	hold_ease:    an.Ease,
	standby_ease: an.Ease,
	hover_s:      f32,
	hold_s:       f32,
	standby_s:    f32,
}

insert_entity :: proc(s: ^Game, e: ^Entity, loc := #caller_location) {
	key, err := pool.insert_defered(&s.entities, e^)
	if err != nil do log.panicf("%v", err, location = loc)
	e.id = key
}

free_entity :: proc(s: ^Game, id: pool.Pool_Key) {
	entity, ok := pool.get(&s.entities, id);assert(ok)
	pool.free_defered(&s.entities, id)
	entity._marked_del = true
}

flush_entities :: proc(s: ^Game) {
	idx: pool.Pool_Idx
	for entity in pool.next(&s.entities, &idx) {
		if entity._marked_del {
			gc_entity(entity)
		}
	}
}

gc_entity :: proc(e: ^Entity) {
	if len(e.name) > 0 {
		delete(e.name)
	}
}

