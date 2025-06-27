package renderer
import gltf "../lib/glTF2"
import "../lib/glist"
import "../lib/pool"
import "../lib/sdle"
import "base:runtime"
import "core:encoding/json"
import "core:log"
import "core:mem"
import "core:slice"
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
	model.materials = make([]Model_Material, len(data.materials))

	// buffers
	transfer_buffer_size := u32(0)
	buffer_sizer := make([]u32, len(data.buffers))
	for buffer, i in data.buffers {
		buffer_sizer[i] = transfer_buffer_size
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
	for buffer, i in data.buffers {
		switch buf_ptr in buffer.uri {
		case string:
			panic("external buffers not supported")
		case []byte:
			mem.copy(transfer_mem[buffer_sizer[i]:], raw_data(buf_ptr), int(buffer.byte_length))
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
		offset := buffer_sizer[buffer_view.buffer] + buffer_view.byte_offset
		sdl.UploadToGPUBuffer(
			r._copy_pass,
			{transfer_buffer = transfer_buf, offset = offset},
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
	if lights_ext_value, has_lights_ext := data.extensions.(json.Object)["KHR_lights_punctual"];
	   has_lights_ext {
		lights_arr := lights_ext_value.(json.Array)
		model.lights = make([]Model_Light, len(lights_arr), context.temp_allocator)
		for json_obj_light, i in lights_arr {
			json_light := json_obj_light.(json.Object)
			light_type := json_light["type"].(json.String)
			if light_type != "point" {
				log.infof(
					"light at index %d of type %s not supported, only point lights for now.",
					i,
					light_type,
				)
				continue
			}
			color: [4]f32 = 1.0
			maybe_color, has_color := json_light["color"]
			if has_color {
				light_color := maybe_color.(json.Array)
				for channel, i in light_color {
					color[i] = f32(channel.(json.Float))
				}
			}
			intensity := f32(json_light["intensity"].(json.Float))
			color *= intensity
			model.lights[i].color = color
		}
	}

	// materials
	for gltf_material, i in data.materials {
		model_material: Model_Material
		diffuse_metal_rough, has_base_metal := gltf_material.metallic_roughness.?;assert(has_base_metal)
		diffuse_tex, has_diffuse := diffuse_metal_rough.base_color_texture.?;assert(has_diffuse)
		metal_rough_tex, has_metal_rough := diffuse_metal_rough.metallic_roughness_texture.?;assert(has_metal_rough)
		ok: bool
		model_material.diffuse_buf, ok = data.images[diffuse_tex.index].buffer_view.?
		assert(ok)
		model_material.metal_rough_buf, ok = data.images[metal_rough_tex.index].buffer_view.?
		assert(ok)
		normal, has_normal := gltf_material.normal_texture.?;assert(has_normal)
		model_material.normal_buf, ok = data.images[normal.index].buffer_view.?
		assert(ok)
		occlusion, has_occlusion := gltf_material.occlusion_texture.?;assert(has_occlusion)
		model_material.occlusion_buf, ok = data.images[occlusion.index].buffer_view.?
		assert(ok)
		emissive, has_emissive := gltf_material.emissive_texture.?
		if has_emissive {
			model_material.emmisive_buf, ok = data.images[emissive.index].buffer_view.?
			assert(ok)
		}
		model.materials[i] = model_material
	}

	// meshes
	for gltf_mesh, mesh_idx in data.meshes {
		gltf_ctx.mesh_name = gltf_mesh.name.?
		gltf_ctx.mesh_idx = mesh_idx
		model_mesh: Model_Mesh
		model_mesh.primitives = make([]Model_Primitive, len(gltf_mesh.primitives))
		for gltf_primitive, primitive_idx in gltf_mesh.primitives {
			gltf_ctx.primitive_idx = primitive_idx
			model_primitive: Model_Primitive
			ok: bool
			model_primitive.indices, ok = gltf_primitive.indices.?
			if !ok do panic_primitive_err(gltf_ctx, "indices")
			if gltf_primitive.mode != .Triangles do panic_primitive_err(gltf_ctx, "Triangles mode")
			model_primitive.pos = get_primitive_attr(gltf_ctx, gltf_primitive, "POSITION")
			model_primitive.uv = get_primitive_attr(gltf_ctx, gltf_primitive, "TEXCOORD_0")
			model_primitive.normal = get_primitive_attr(gltf_ctx, gltf_primitive, "NORMAL")
			model_primitive.tangent = get_primitive_attr(gltf_ctx, gltf_primitive, "TANGENT")
			model_primitive.material, ok = gltf_primitive.material.?
			if !ok do panic_primitive_err(gltf_ctx, "material")

			model_mesh.primitives[primitive_idx] = model_primitive
		}
		model.meshes[mesh_idx] = model_mesh
	}
	// nodes 
	num_lights := u32(0)
	for gltf_node in data.nodes {
		_, ok := gltf_node.extensions.(json.Object)["KHR_lights_punctual"]
		num_lights += u32(ok)
	}
	for gltf_node, i in data.nodes {
		node: Model_Node
		// node lights
		lights_ext, ok := gltf_node.extensions.(json.Object)["KHR_lights_punctual"]
		if ok {
			node.light = u32(lights_ext.(json.Object)["light"].(json.Integer))
		}
		// node meshes
		node.mesh = gltf_node.mesh
		node.pos = gltf_node.translation
		node.scale = gltf_node.scale
		node.rot = gltf_node.rotation
		node.children = slice.clone(gltf_node.children)
		model.nodes[i] = node
	} // end nodes
	model_idx := glist.insert(&r._models, model) or_return
	return
}

