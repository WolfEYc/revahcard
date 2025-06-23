package renderer
import gltf "../lib/glTF2"
import "../lib/glist"
import "../lib/pool"
import "../lib/sdle"
import "base:runtime"
import "core:encoding/json"
import "core:log"
import "core:mem"
import sdl "vendor:sdl3"


GLTF_Ctx :: struct {
	file_name:     string,
	mesh_name:     string,
	mesh_idx:      int,
	primitive_idx: int,
}
mesh_err_fmt :: "err loading model=%s, mesh_name=%s mesh_idx=%d primitive=%d missing %s"
get_primitive_attr :: proc(
	gltf_ctx: GLTF_Ctx,
	primitive: gltf.Mesh_Primitive,
	attr: string,
) -> (
	accessor: gltf.Integer,
) {
	ok: bool
	accessor, ok = primitive.attributes[attr]
	if !ok do panic_primitive_err(gltf_ctx, attr)
	return
}

panic_primitive_err :: proc(gltf_ctx: GLTF_Ctx, missing: string) {
	log.panicf(
		mesh_err_fmt,
		gltf_ctx.file_name,
		gltf_ctx.mesh_name,
		gltf_ctx.mesh_idx,
		gltf_ctx.primitive_idx,
		missing,
	)
}
load_gltf :: proc(r: ^Renderer, file_name: string) -> (err: runtime.Allocator_Error) {
	gltf_ctx: GLTF_Ctx
	gltf_ctx.file_name = file_name

	assert(r._copy_pass != nil)
	assert(r._copy_cmd_buf != nil)
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)
	log.infof("loading model: %s", file_name)

	data, load_err := gltf.load_from_file(file_name)
	if load_err != nil {
		log.panicf("err loading model %s, reason: %v", file_name, load_err)
	}
	defer gltf.unload(data)
	model: Model
	model.buffers = make([]^sdl.GPUBuffer, len(data.buffer_views))
	model.accessors = make([]Model_Accessor, len(data.accessors))
	model.meshes = make([]Model_Mesh, len(data.meshes))
	model.nodes = make([]Model_Node, len(data.nodes))

	// buffers
	transfer_buffer_size := u32(0)
	for buffer in data.buffers {
		transfer_buffer_size += buffer.byte_length
	}
	transfer_buf := sdl.CreateGPUTransferBuffer(
		r._gpu,
		{usage = .UPLOAD, size = transfer_buffer_size},
	);sdle.err(transfer_buf)
	defer sdl.ReleaseGPUTransferBuffer(r._gpu, transfer_buf)

	transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(
		r._gpu,
		transfer_buf,
		false,
	);sdle.err(transfer_mem)
	offset := 0
	for buffer in data.buffers {
		switch buf_ptr in buffer.uri {
		case string:
			panic("external buffers not supported")
		case []byte:
			int_byte_len := int(buffer.byte_length)
			mem.copy(transfer_mem[offset:], raw_data(buf_ptr), int_byte_len)
			offset += int_byte_len
		}
	}
	sdl.UnmapGPUTransferBuffer(r._gpu, transfer_buf)

	// buffer views
	for buffer_view, i in data.buffer_views {
		target, ok := buffer_view.target.?
		if !ok {
			name := buffer_view.name.?
			log.panicf("model %s had buffer view %d:%s with unknown target", file_name, i, name)
		}
		usage: sdl.GPUBufferUsageFlags
		switch target {
		case .Array:
			usage = {.VERTEX}
		case .Element_Array:
			usage = {.INDEX}
		}
		gpu_buf := sdl.CreateGPUBuffer(
			r._gpu,
			{usage = usage, size = buffer_view.byte_length},
		);sdle.err(gpu_buf)
		sdl.UploadToGPUBuffer(
			r._copy_pass, // figure out buffer shenanegains TODO get buffer offset into transfer_mem
			{transfer_buffer = transfer_buf, offset = buffer_view.byte_offset},
			{buffer = gpu_buf, size = buffer_view.byte_length},
			false,
		)
		model.buffers[i] = gpu_buf
	}

	// accessors
	for accessor, i in data.accessors {
		buffer_view, ok := accessor.buffer_view.?
		if !ok {
			name := accessor.name.?
			log.panicf(
				"model %s had accessor %d:%s with no buffer view, sparse not supported",
				file_name,
				i,
				name,
			)
		}
		model.accessors[i] = Model_Accessor {
			buffer = buffer_view,
			offset = accessor.byte_offset,
		}
	}

	//lights
	lights: []json.Object
	if lights_ext_value, has_lights_ext := data.extensions.(json.Object)["KHR_lights_punctual"];
	   has_lights_ext {
		lights_arr := lights_ext_value.(json.Array)
		lights = make([]json.Object, len(lights_arr), context.temp_allocator)
		for light, i in lights_arr {
			lights[i] = light.(json.Object)
		}
	}

	// meshes
	for gltf_mesh, mesh_idx in data.meshes {
		gltf_ctx.mesh_name = gltf_mesh.name.?
		gltf_ctx.mesh_idx = mesh_idx
		gpu_mesh: Model_Mesh
		gpu_mesh.primitives = make([]GPU_Primitive, len(gltf_mesh.primitives))
		for gltf_primitive, primitive_idx in gltf_mesh.primitives {
			gltf_ctx.primitive_idx = primitive_idx
			gpu_primitive: GPU_Primitive
			ok: bool
			gpu_primitive.indices, ok = gltf_primitive.indices.?
			if !ok do panic_primitive_err(gltf_ctx, "indices")
			gpu_primitive.pos = get_primitive_attr(gltf_ctx, gltf_primitive, "POSITION")
			gpu_primitive.uv = get_primitive_attr(gltf_ctx, gltf_primitive, "TEXCOORD_0")
			gpu_primitive.normal = get_primitive_attr(gltf_ctx, gltf_primitive, "NORMAL")
			gpu_primitive.tangent = get_primitive_attr(gltf_ctx, gltf_primitive, "TANGENT")

			gpu_mesh.primitives[primitive_idx] = gpu_primitive
		}
		model.meshes[mesh_idx] = gpu_mesh
	}

	model_idx := glist.insert(&r._models, model) or_return

	// nodes 
	node_mapper := make([]pool.Pool_Key, len(data.nodes), context.temp_allocator)
	for gltf_node, i in data.nodes {
		node: Node
		// node lights
		lights_ext, ok := gltf_node.extensions.(json.Object)["KHR_lights_punctual"]
		if ok {
			light_idx := lights_ext.(json.Object)["light"].(json.Integer)
			light := lights[light_idx]
			light_type := light["type"].(json.String)
			color: [4]f32 = 1.0
			maybe_color, has_color := light["color"]
			if has_color {
				light_color := maybe_color.(json.Array)
				for channel, i in light_color {
					color[i] = f32(channel.(json.Float))
				}
			}
			intensity := f32(light["intensity"].(json.Float))
			color *= intensity
			switch light_type {
			case "point":
				node.light_color = color
				node.lit = true
			}
		}
		// node meshes
		mesh_idx, has_mesh := gltf_node.mesh.?
		if has_mesh {
			node.mesh = Mesh_Renderer {
				model = model_idx,
				mesh  = mesh_idx,
			}
		}
		node.pos = gltf_node.translation
		node.scale = gltf_node.scale
		node.rot = gltf_node.rotation
		node.children = make([]pool.Pool_Key, len(gltf_node.children))
		node_mapper[i] = pool.insert_defered(&r._nodes, node) or_return
	} // end nodes

	for key, i in node_mapper {
		gltf_node := data.nodes[i]
		node := pool.get(&r._nodes, key)
	}
	//TODO child nodes


	return
}

