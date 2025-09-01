package main

import "../lib/pool"


EType :: union {
	^Render_Card,
}

Entity :: struct {
	id:          pool.Pool_Key,
	name:        string,
	variant:     EType,
	_marked_del: bool,
}

insert_entity :: proc(s: ^Game, e: ^Entity) {
	key, err := pool.insert_defered(&s.entities, e^);assert(err == nil)
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

