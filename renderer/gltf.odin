package renderer
import gltf "../lib/glTF2"
import "../lib/glist"
import "../lib/pool"
import "../lib/sdle"
import "base:runtime"
import "core:encoding/json"
import "core:log"
import "core:mem"
import "core:simd"
import "core:slice"
import sdl "vendor:sdl3"
import sdli "vendor:sdl3/image"


Model :: struct {
	buffers:   []^sdl.GPUBuffer,
	textures:  []^sdl.GPUTexture,
	samplers:  []^sdl.GPUSampler,
	meshes:    []Model_Mesh,
	nodes:     []Model_Node,
	lights:    []Model_Light,
	materials: []Model_Material,
	node_map:  map[string]u32, //TODO
}

Model_Material :: struct {
	name:         Maybe(string),
	normal_scale: f32,
	ao_strength:  f32,
	bindings:     [5]sdl.GPUTextureSamplerBinding,
}
Model_Accessor :: struct {
	buffer: u32,
	offset: u32,
}

Model_Mesh :: struct {
	primitives: []Model_Primitive,
}
Vert_Idx :: enum {
	POS,
	UV,
	UV1,
	NORMAL,
	TANGENT,
}
// indexes to accessors
Model_Primitive :: struct {
	vert_bufs:    [5]sdl.GPUBufferBinding,
	indices:      sdl.GPUBufferBinding,
	indices_type: sdl.GPUIndexElementSize,
	num_indices:  u32,
	material:     u32,
}
Model_Node :: struct {
	pos:      [3]f32,
	scale:    [3]f32,
	rot:      quaternion128,
	mesh:     Maybe(u32),
	light:    Maybe(u32),
	children: []u32,
}
Model_Light :: struct {
	color: [4]f32,
}
Mat_Idx :: enum {
	DIFFUSE,
	NORMAL,
	METAL_ROUGH,
	OCCLUSION,
	EMISSIVE,
}


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
accessor_size :: proc(accessor: gltf.Accessor) -> (size: u32) {
	component_size: u32
	switch accessor.component_type {
	case .Unsigned_Byte, .Byte:
		size = 1
	case .Unsigned_Short, .Short:
		size = 2
	case .Unsigned_Int, .Float:
		size = 4
	}
	container_size: u32
	switch accessor.type {
	case .Scalar:
		container_size = 1
	case .Vector2:
		container_size = 2
	case .Vector3:
		container_size = 3
	case .Vector4, .Matrix2:
		container_size = 4
	case .Matrix3:
		container_size = 9
	case .Matrix4:
		container_size = 16
	}
	size = component_size * container_size * accessor.count
	return
}
accessor_raw :: proc(data: ^gltf.Data, accessor: gltf.Accessor) -> rawptr {
	assert(
		accessor.buffer_view != nil,
		"buf_iter_make: selected accessor doesn't have buffer_view",
	)

	buffer_view := data.buffer_views[accessor.buffer_view.?]

	if _, ok := accessor.sparse.?; ok {
		assert(false, "Sparse not supported")
		return nil
	}

	if _, ok := buffer_view.byte_stride.?; ok {
		assert(false, "Cannot use a stride")
		return nil
	}

	start_byte := accessor.byte_offset + buffer_view.byte_offset
	uri := data.buffers[buffer_view.buffer].uri

	switch v in uri {
	case string:
		assert(false, "URI is string")
		return nil
	case []byte:
		return &v[start_byte]
	}
	return nil
}
load_gltf :: proc(r: ^Renderer, file_name: string) -> (err: runtime.Allocator_Error) {
	assert(r._copy_pass != nil)
	assert(r._copy_cmd_buf != nil)
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)
	gltf_ctx: GLTF_Ctx
	gltf_ctx.file_name = file_name
	log.infof("loading model: %s", file_name)

	data, load_err := gltf.load_from_file(file_name)
	if load_err != nil {
		log.panicf("err loading model %s, reason: %v", file_name, load_err)
	}
	defer gltf.unload(data)
	model: Model
	model.buffers = make([]^sdl.GPUBuffer, len(data.accessors))
	model.textures = make([]^sdl.GPUTexture, len(data.images))
	model.samplers = make([]^sdl.GPUSampler, len(data.samplers))
	model.meshes = make([]Model_Mesh, len(data.meshes))
	model.nodes = make([]Model_Node, len(data.nodes))
	model.materials = make([]Model_Material, len(data.materials))

	{
		// textures
		tex_trans_size := u32(0)
		surfaces := make([]^sdl.Surface, len(data.images), context.temp_allocator)
		for gltf_image, i in data.images {
			img_type, has_img_type := gltf_image.type.?
			assert(has_img_type)
			buf_view_idx, has_buf_view := gltf_image.buffer_view.?
			assert(has_buf_view)
			buf_view := data.buffer_views[buf_view_idx]
			mem_buf_view: rawptr
			switch mem in data.buffers[buf_view.buffer].uri {
			case string:
				panic("external buffers not supported")
			case []byte:
				mem_buf_view = raw_data(mem[buf_view.byte_offset:])
			}
			io_stream := sdl.IOFromMem(mem_buf_view, uint(buf_view.byte_length))
			disk_surface := sdli.Load_IO(io_stream, true);sdle.err(disk_surface)
			palette := sdl.GetSurfacePalette(disk_surface)
			surf := sdl.ConvertSurfaceAndColorspace(
				disk_surface,
				.RGBA32,
				palette,
				.SRGB_LINEAR,
				0,
			);sdle.err(surf)
			sdl.DestroySurface(disk_surface)
			surfaces[buf_view_idx] = surf
			tex_trans_size += u32(surf.h * surf.pitch)
		}

		tex_trans_buf := sdl.CreateGPUTransferBuffer(
			r._gpu,
			{usage = .UPLOAD, size = tex_trans_size},
		);sdle.err(tex_trans_buf)
		tex_transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(
			r._gpu,
			tex_trans_buf,
			false,
		);sdle.err(tex_transfer_mem)
		offset := 0
		for surf in surfaces {
			size := int(surf.h * surf.pitch)
			mem.copy(tex_transfer_mem[offset:], surf.pixels, size)
			offset += size
		}
		sdl.UnmapGPUTransferBuffer(r._gpu, tex_trans_buf)
		offset_u32 := u32(0)
		for surf, i in surfaces {
			width := u32(surf.w)
			height := u32(surf.h)
			pitch := u32(surf.pitch)
			tex := sdl.CreateGPUTexture(
				r._gpu,
				{
					type = .D2,
					format = .R8G8B8A8_UNORM,
					usage = {.SAMPLER},
					width = width,
					height = height,
					layer_count_or_depth = 1,
					num_levels = 1,
				},
			);sdle.err(tex)
			sdl.UploadToGPUTexture(
				r._copy_pass,
				{transfer_buffer = tex_trans_buf, offset = offset_u32, pixels_per_row = pitch},
				{texture = tex, w = width, h = height, d = 1},
				false,
			)
			model.textures[i] = tex
			offset_u32 += u32(surf.h * surf.pitch)
			sdl.DestroySurface(surf)
		}
		sdl.ReleaseGPUTransferBuffer(r._gpu, tex_trans_buf)
	}

	// samplers
	for gltf_sampler, i in data.samplers {
		sampler_info: sdl.GPUSamplerCreateInfo
		min_filter, has_min_filter := gltf_sampler.min_filter.?
		if has_min_filter {
			switch min_filter {
			case .Linear:
				sampler_info.min_filter = .LINEAR
			case .Nearest:
				sampler_info.min_filter = .NEAREST
			case .Nearest_MipMap_Nearest:
				sampler_info.min_filter = .NEAREST
				sampler_info.mipmap_mode = .NEAREST
			case .Linear_MipMap_Nearest:
				sampler_info.min_filter = .LINEAR
				sampler_info.mipmap_mode = .NEAREST
			case .Nearest_MipMap_Linear:
				sampler_info.min_filter = .NEAREST
				sampler_info.mipmap_mode = .LINEAR
			case .Linear_MipMap_Linear:
				sampler_info.min_filter = .LINEAR
				sampler_info.mipmap_mode = .LINEAR
			}
		}
		mag_filter, has_max_filter := gltf_sampler.mag_filter.?
		if has_max_filter {
			switch mag_filter {
			case .Linear:
				sampler_info.mag_filter = .LINEAR
			case .Nearest:
				sampler_info.mag_filter = .NEAREST
			}
		}
		sampler_info.address_mode_u = sdl.GPUSamplerAddressMode(gltf_sampler.wrapS)
		sampler_info.address_mode_v = sdl.GPUSamplerAddressMode(gltf_sampler.wrapT)
		gpu_sampler := sdl.CreateGPUSampler(r._gpu, sampler_info);sdle.err(gpu_sampler)
		model.samplers[i] = gpu_sampler
	}

	// textures
	textures := make([]sdl.GPUTextureSamplerBinding, len(data.textures), context.temp_allocator)
	for gltf_tex, i in data.textures {
		img_idx, has_img := gltf_tex.source.?;assert(has_img)

		textures[i].texture = model.textures[img_idx]
		sampler_idx, has_sampler := gltf_tex.sampler.?
		textures[i].sampler = has_sampler ? model.samplers[sampler_idx] : r._defaut_sampler
	}

	//lights

	lights_ext_value, has_lights_ext := data.extensions.(json.Object)["KHR_lights_punctual"]
	if has_lights_ext {
		lights_arr := lights_ext_value.(json.Array)
		model.lights = make([]Model_Light, len(lights_arr))
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
		model_material.name = gltf_material.name
		base_info, has_base := gltf_material.metallic_roughness.?
		if has_base {
			diffuse_tex, has_diffuse := base_info.base_color_texture.?
			model_material.bindings[Mat_Idx.DIFFUSE] =
				has_diffuse ? textures[diffuse_tex.index] : load_pixel_f32(r, base_info.base_color_factor)
			metal_rough, has_metal_rough := base_info.metallic_roughness_texture.?
			if has_metal_rough {
				model_material.bindings[Mat_Idx.METAL_ROUGH] = textures[metal_rough.index]
			} else {
				pixel := [4]f32{0, base_info.roughness_factor, base_info.metallic_factor, 1.0}
				model_material.bindings[Mat_Idx.METAL_ROUGH] = load_pixel_f32(r, pixel)
			}
		} else {
			model_material.bindings[Mat_Idx.DIFFUSE] = r._default_diffuse_binding
			model_material.bindings[Mat_Idx.METAL_ROUGH] = r._default_orm_binding
		}

		normal, has_normal := gltf_material.normal_texture.?
		if has_normal {
			model_material.bindings[Mat_Idx.NORMAL] = textures[normal.index]
			model_material.normal_scale = normal.scale
		} else {
			model_material.bindings[Mat_Idx.NORMAL] = r._default_normal_binding
			model_material.normal_scale = 1.0
		}
		occlusion, has_occlusion := gltf_material.occlusion_texture.?
		if has_normal {
			model_material.bindings[Mat_Idx.OCCLUSION] = textures[occlusion.index]
			model_material.ao_strength = occlusion.strength
		} else {
			model_material.bindings[Mat_Idx.OCCLUSION] = r._default_orm_binding
			model_material.ao_strength = 1.0
		}
		emissive, has_emissive := gltf_material.emissive_texture.?
		model_material.bindings[Mat_Idx.EMISSIVE] =
			has_emissive ? textures[emissive.index] : r._default_emissive_binding

		model.materials[i] = model_material
	}

	{
		// accessors
		transfer_buffer_size := u32(0)
		buffer_offseter := make([]u32, len(data.accessors), context.temp_allocator)
		buffer_sizer := make([]u32, len(data.accessors), context.temp_allocator)
		for accessor, i in data.accessors {
			buffer_offseter[i] = transfer_buffer_size
			buffer_sizer[i] = accessor_size(accessor)
			transfer_buffer_size += buffer_sizer[i]
		}
		transfer_buf := sdl.CreateGPUTransferBuffer(
			r._gpu,
			{usage = .UPLOAD, size = transfer_buffer_size},
		);sdle.err(transfer_buf)

		transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(
			r._gpu,
			transfer_buf,
			false,
		);sdle.err(transfer_mem)
		for accessor, i in data.accessors {
			src := accessor_raw(data, accessor)
			size := buffer_sizer[i]
			offset := buffer_offseter[i]
			mem.copy(transfer_mem[offset:], src, int(size))
		}
		sdl.UnmapGPUTransferBuffer(r._gpu, transfer_buf)

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
				indices_idx: u32
				indices_idx, ok = gltf_primitive.indices.?
				if !ok do panic_primitive_err(gltf_ctx, "indices")
				if gltf_primitive.mode != .Triangles do panic_primitive_err(gltf_ctx, "Triangles mode")
				idxs: [5]u32
				idxs[Vert_Idx.POS] = get_primitive_attr(gltf_ctx, gltf_primitive, "POSITION")
				idxs[Vert_Idx.UV] = get_primitive_attr(gltf_ctx, gltf_primitive, "TEXCOORD_0")
				idxs[Vert_Idx.UV1] = get_primitive_attr(gltf_ctx, gltf_primitive, "TEXCOORD_1") // TODO make nullable
				idxs[Vert_Idx.NORMAL] = get_primitive_attr(gltf_ctx, gltf_primitive, "NORMAL")
				idxs[Vert_Idx.TANGENT] = get_primitive_attr(gltf_ctx, gltf_primitive, "TANGENT")
				model_primitive.material, ok = gltf_primitive.material.?
				if !ok do panic_primitive_err(gltf_ctx, "material")

				#unroll for i in 0 ..< len(idxs) {
					buf_idx := idxs[i]
					buffer := model.buffers[buf_idx]
					if buffer == nil {
						accessor := data.accessors[buf_idx]
						offset := buffer_offseter[buf_idx]
						size := buffer_sizer[buf_idx]
						buffer = sdl.CreateGPUBuffer(
							r._gpu,
							{usage = {.VERTEX}, size = size},
						);sdle.err(buffer)
						sdl.UploadToGPUBuffer(
							r._copy_pass,
							{transfer_buffer = transfer_buf, offset = offset},
							{buffer = buffer, size = size},
							false,
						)
						model.buffers[buf_idx] = buffer
					}
					model_primitive.vert_bufs[i] = sdl.GPUBufferBinding {
						buffer = buffer,
					}
				}

				indices_accessor := data.accessors[indices_idx]
				buffer := model.buffers[indices_idx]
				if buffer == nil {
					offset := buffer_offseter[indices_idx]
					size := buffer_sizer[indices_idx]
					buffer = sdl.CreateGPUBuffer(
						r._gpu,
						{usage = {.INDEX}, size = size},
					);sdle.err(buffer)
					sdl.UploadToGPUBuffer(
						r._copy_pass,
						{transfer_buffer = transfer_buf, offset = offset},
						{buffer = buffer, size = size},
						false,
					)
					model.buffers[indices_idx] = buffer
				}
				#partial switch indices_accessor.component_type {
				case .Unsigned_Short:
					model_primitive.indices_type = ._16BIT
				case .Unsigned_Int:
					model_primitive.indices_type = ._32BIT
				case:
					log.panicf(
						"unexpected gltf indicies component type encountered, %v",
						indices_accessor.component_type,
					)
				}
				model_primitive.indices = sdl.GPUBufferBinding {
					buffer = buffer,
				}
				model_primitive.num_indices = indices_accessor.count
				model_mesh.primitives[primitive_idx] = model_primitive
			}
			model.meshes[mesh_idx] = model_mesh
		}
		sdl.ReleaseGPUTransferBuffer(r._gpu, transfer_buf)
	}
	// nodes 
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

