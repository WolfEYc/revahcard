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
import sdli "vendor:sdl3/image"


Model_Buffer :: union {
	^sdl.GPUBuffer,
	^sdl.GPUTexture,
}

Model :: struct {
	buffers:   []Model_Buffer,
	accessors: []Model_Accessor,
	meshes:    []Model_Mesh,
	nodes:     []Model_Node,
	lights:    []Model_Light,
	samplers:  []^sdl.GPUSampler,
	textures:  []sdl.GPUTextureSamplerBinding, //TODO maybe temp?
	materials: []Model_Material, //TODO
}

Model_Material :: struct {
	diffuse_tex:     u32,
	metal_rough_tex: u32,
	normal_tex:      u32,
	occlusion_tex:   u32,
	emmisive_tex:    Maybe(u32),
}

Model_Accessor :: struct {
	buffer: u32,
	offset: u32,
}

Model_Mesh :: struct {
	primitives: []Model_Primitive,
}
// indexes to accessors
Model_Primitive :: struct {
	pos:      u32,
	uv:       u32,
	uv1:      u32,
	normal:   u32,
	tangent:  u32,
	indices:  u32,
	material: u32,
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
	model.buffers = make([]Model_Buffer, len(data.buffer_views))
	model.accessors = make([]Model_Accessor, len(data.accessors))
	model.meshes = make([]Model_Mesh, len(data.meshes))
	model.nodes = make([]Model_Node, len(data.nodes))
	model.materials = make([]Model_Material, len(data.materials))


	// images
	surfaces := make([]^sdl.Surface, len(data.buffer_views), context.temp_allocator)
	for gltf_image, i in data.images {
		img_type, has_img_type := gltf_image.type.?
		assert(has_img_type)
		buf_view_idx, has_buf_view := gltf_image.buffer_view.?
		assert(has_buf_view)
		bview_is_image[buf_view_idx] = true
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
		surfaces_num_bytes += surf.h * surf.pitch
	}
	// setup transfer buf
	transfer_buffer_size := u32(0)
	buffer_sizer := make([]u32, len(data.buffer_views))
	for bview, i in data.buffer_views {
		if surfaces[i] != nil {
			surf := surfaces[i]
			buffer_sizer[i] = transfer_buffer_size
			transfer_buffer_size += u32(surf.h * surf.pitch)
		} else {
			buffer_sizer[i] = transfer_buffer_size
			transfer_buffer_size += bview.byte_length
		}
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

	// buffer views
	for bview, i in data.buffer_views {
		if surfaces[i] != nil {
			surface := surfaces[i]
			offset := buffer_sizer[i]
			width := u32(surface.w)
			height := u32(surface.h)
			len_pixels := int(surface.h * surface.pitch)
			len_pixels_u32 := u32(len_pixels)
			mem.copy(transfer_mem[offset:], surf.pixels, len_pixels)
			sdl.DestroySurface(surf)
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
				{transfer_buffer = transfer_buf},
				{texture = tex, w = width, h = height, d = 1},
				false,
			)
			model.buffers[i] = tex
			return
		}
		buffer := data.buffers[bview.buffer]
		switch buf_bytes in buffer.uri {
		case string:
			panic("external buffers not supported")
		case []byte:
			bview_bytes := raw_data(buf_bytes[:bview.byte_offset])
			mem.copy(transfer_mem[buffer_sizer[i]:], bview_bytes, int(bview.byte_length))
		}
		target, ok := bview.target.?
		if !ok {
			name := bview.name.?
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
			{usage = usage, size = bview.byte_length},
		);sdle.err(gpu_buf)
		sdl.UploadToGPUBuffer(
			r._copy_pass,
			{transfer_buffer = transfer_buf, offset = buffer_sizer[i]},
			{buffer = gpu_buf, size = bview.byte_length},
			false,
		)
		model.buffers[i] = gpu_buf
	}
	sdl.UnmapGPUTransferBuffer(r._gpu, transfer_buf)
	sdl.ReleaseGPUTransferBuffer(r._gpu, transfer_buf)


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
	for gltf_tex, i in data.textures {
		img_idx, has_img := gltf_tex.source.?;assert(has_img)
		buf_view_idx, has_buf_view := data.images[img_idx].buffer_view.?;assert(has_buf_view)

		model.textures[i].texture = model.buffers[buf_view_idx].(^sdl.GPUTexture)
		sampler_idx, has_sampler := gltf_tex.sampler.?
		model.textures[i].sampler = has_sampler ? model.samplers[sampler_idx] : r._defaut_sampler
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
		model_material.diffuse_tex, ok = data.images[diffuse_tex.index].buffer_view.?
		assert(ok)
		model_material.metal_rough_tex, ok = data.images[metal_rough_tex.index].buffer_view.?
		assert(ok)
		normal, has_normal := gltf_material.normal_texture.?;assert(has_normal)
		model_material.normal_tex, ok = data.images[normal.index].buffer_view.?
		assert(ok)
		occlusion, has_occlusion := gltf_material.occlusion_texture.?;assert(has_occlusion)
		model_material.occlusion_tex = model.textures[occlusion.index]
		assert(ok)
		emissive, has_emissive := gltf_material.emissive_texture.?
		if has_emissive {
			model_material.emmisive_tex, ok = data.images[emissive.index].buffer_view.?
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
			model_primitive.uv1 = get_primitive_attr(gltf_ctx, gltf_primitive, "TEXCOORD_1")
			model_primitive.normal = get_primitive_attr(gltf_ctx, gltf_primitive, "NORMAL")
			model_primitive.tangent = get_primitive_attr(gltf_ctx, gltf_primitive, "TANGENT")
			model_primitive.material, ok = gltf_primitive.material.?
			if !ok do panic_primitive_err(gltf_ctx, "material")

			model_mesh.primitives[primitive_idx] = model_primitive
		}
		model.meshes[mesh_idx] = model_mesh
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

