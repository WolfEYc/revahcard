package glist

import "base:builtin"
import "base:runtime"

Glist_Idx :: u32
Glist :: struct($T: typeid) {
	_data:       []T,
	_update_map: map[Glist_Idx]T,
	_len:        Glist_Idx,
}

// There is no delete! as this is an insert/update only data structure,
// meant for static data that lives for the duration of the program
// like textures and stuff if you arent doing texture streaming or somethin, and use a set of global textures and meshes

make :: proc($T: typeid, cap: Glist_Idx) -> (list: Glist(T), err: runtime.Allocator_Error) {
	list._data = runtime.make([]T, cap) or_return
	list._update_map = runtime.make(map[Glist_Idx]T, cap) or_return
	return
}

insert :: #force_inline proc(
	list: ^Glist($T),
	e: T,
) -> (
	idx: Glist_Idx,
	err: runtime.Allocator_Error,
) #no_bounds_check {
	if list._len == cap(list) {
		err = runtime.Allocator_Error.Out_Of_Memory
		return
	}
	list._data[list._len] = e
	idx = list._len
	list._len += 1
	return
}

get :: #force_inline proc(list: Glist($T), idx: Glist_Idx) -> (elem: ^T) #no_bounds_check {
	assert(idx < list._len)
	return &list._data[idx]
}

update_deferred :: #force_inline proc(list: ^Glist($T), idx: Glist_Idx, e: T) #no_bounds_check {
	assert(idx < list._len)
	list._update_map[idx] = e
}

flush_updates :: #force_inline proc(list: ^Glist($T)) #no_bounds_check {
	for idx, e in list._update_map {
		list._data[idx] = e
	}
	clear(&list._update_map)
}

len :: #force_inline proc(list: ^Glist($T)) -> (len: Glist_Idx) {
	return list._len
}

cap :: #force_inline proc(list: ^Glist($T)) -> (cap: Glist_Idx) {
	return Glist_Idx(builtin.len(list._data))
}

