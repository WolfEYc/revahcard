package entityarena

import "base:runtime"
import "core:slice/heap"

Entity_Idx :: u32
Gen_Counter :: u32
Entity_Key :: struct {
	idx: Entity_Idx,
	gen: Gen_Counter,
}

// yeah these guys are made to live forever, so pretty much just leak them LOL!!!
Entity_Pool :: struct($T: typeid) {
	_entities:        []T,
	_actives:         []bool,
	_gens:            []Gen_Counter,
	_vacant_min_heap: []Entity_Idx,
	_free_buf:        []Entity_Idx,
	_insert_buf:      []Entity_Idx,
	_vacant_len:      Entity_Idx,
	_max_used_len:    Entity_Idx,
	_free_buf_len:    Entity_Idx,
	_insert_buf_len:  Entity_Idx,
	_max_active_len:  Entity_Idx, // useful for not wasting iterating into the inactive only entities range
	cap:              Entity_Idx,
}

new :: proc($T: typeid, cap: Entity_Idx) -> (pool: Entity_Pool(T), err: runtime.Allocator_Error) {
	Entity_Elem :: struct {
		entity:     T,
		actives:    bool,
		gen:        Gen_Counter,
		heap_idx:   Entity_Idx,
		free_buf:   Entity_Idx,
		insert_buf: Entity_Idx,
	}
	Entity_SOA :: #soa[]Entity_Elem
	pool_mem: Entity_SOA
	pool_mem, err = make(Entity_SOA, cap)
	if err != nil {
		return
	}
	pool._entities, pool._actives, pool._gens, pool._vacant_min_heap, pool._free_buf, pool._insert_buf :=
		soa_unzip(pool_mem)
	pool.cap = cap
}

min_heap_less :: proc(a, b: Entity_Idx) -> bool {
	return a > b
}

validate_idx :: #force_inline proc(pool: ^Entity_Pool($T), key: Entity_Key) -> bool {
	assert(key < pool.cap)
	return key.gen != 0 && pool._actives[key.idx] && key.gen == pool._gens[key.idx]
}

@(require_results)
get :: #force_inline proc(pool: ^Entity_Pool($T), key: Entity_Key) -> (res: ^T, ok: bool) {
	if !validate_idx(pool, key) do return
	res = &pool._entities[idx.idx]
	ok = true
}

next :: #force_inline proc(
	pool: ^Entity_Pool($T),
	idx: ^Entity_Idx,
) -> (
	entity: ^T,
	key: Entity_Key,
	ok: bool,
) {
	i := idx^
	for ; i < pool._max_active_len; i += 1 {
		if !pool._actives[i] do continue
		next_key.idx = i
		next_key.gen = pool._gens[i]
		entity = &pool._entities[i]
		ok = true
		break
	}
	idx^ = i
}

@(private)
backtrack_max_active_idx :: proc(pool: ^Entity_Pool($T)) {
	for pool._max_active_len > 0 && !pool._actives[pool._max_active_len] {
		pool._max_active_len -= 1
	}
}

@(private)
free :: #force_inline proc(pool: ^Entity_Pool($T), idx: Entity_Idx) {
	pool._actives[idx] = false
	pool._vacant_min_heap[pool.cap - 1] = idx
	heap.push(pool._vacant_min_heap, min_heap_less)
}

free_immediate :: proc(pool: ^Entity_Pool($T), key: Entity_Key) {
	if !validate_idx(pool, key) do return
	free(pool, idx.idx)
	backtrack_max_active_idx(pool)
}

free_defered :: #force_inline proc(pool: ^Entity_Pool($T), key: Entity_Key) {
	if !validate_idx(pool, key) do return
	pool._free_buf[pool._free_buf_len] = idx.idx
	pool._free_buf_len += 1
}

flush_frees :: proc(pool: ^Entity_Pool($T)) {
	for idx in pool._free_buf[:pool._free_buf_len] {
		free(pool, idx)
	}
	pool._free_buf_len = 0
	backtrack_max_active_idx(pool)
}

insert_immediate :: proc(
	pool: ^Entity_Pool($T),
	elem: T,
) -> (
	key: Entity_Key,
	err: runtime.Allocator_Error,
) {
	if pool == nil {
		err = runtime.Allocator_Error.Invalid_Pointer
		return
	}
	if pool._max_used_len == pool.cap {
		err = runtime.Allocator_Error.Out_Of_Memory
		return
	}
	if pool._vacant_len == 0 {
		//grow used
		pool._entities[pool._max_used_len] = elem
		pool._actives[pool._max_used_len] = true
		pool._gens[pool._max_used_len] = 1
		key.idx = pool._max_used_len
		key.gen = 1
		pool._max_active_len = pool._max_used_len
		pool._max_used_len += 1
	} else {
		// reuse slot
		heap.pop(pool._vacant_min_heap, min_heap_less)
		pool._vacant_len -= 1
		vacant_idx := pool._vacant_min_heap[pool.cap - 1]
		pool._entities[vacant_idx] = elem
		pool._gens[vacant_idx] += 1
		pool._actives[vacant_idx] = true
		key.idx = vacant_idx
		key.gen = pool._gens[vacant_idx]
		pool._max_active_len = max(pool._max_active_len, vacant_idx + 1)
	}
}

insert_defered :: proc(
	pool: ^Entity_Pool($T),
	elem: T,
) -> (
	key: Entity_Key,
	err: runtime.Allocator_Error,
) {
	if pool == nil {
		err = runtime.Allocator_Error.Invalid_Pointer
		return
	}
	if pool._max_used_len == pool.cap {
		err = runtime.Allocator_Error.Out_Of_Memory
		return
	}
	if pool._vacant_len == 0 {
		//grow used
		key.gen = 1
		key.idx = pool._max_used_len

		pool._entities[key.idx] = elem
		pool._gens[key.idx] = 1

		pool._insert_buf[pool._insert_buf_len] = key.idx
		pool._insert_buf_len += 1

		pool._max_used_len += 1
	} else {
		// reuse slot
		heap.pop(pool._vacant_min_heap, min_heap_less)
		pool._vacant_len -= 1
		key.idx = pool._vacant_min_heap[pool.cap - 1]

		key.gen = pool._gens[key.idx] + 1
		pool._gens[key.idx] = key.gen
		pool._entities[key.idx] = elem

		pool._insert_buf[pool._insert_buf_len] = key.idx
		pool._insert_buf_len += 1
	}
}

flush_inserts :: proc(pool: ^Entity_Pool($T)) {
	for idx in pool._insert_buf[:pool._insert_buf_len] {
		pool._actives[idx] = true
		pool._max_active_len = max(pool._max_active_len, idx + 1)
	}
	pool._insert_buf_len = 0
}

