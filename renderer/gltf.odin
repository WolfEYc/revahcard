package renderer
import gltf "../lib/glTF2"
import "../lib/glist"
import "../lib/pool"
import "../lib/sdle"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import lal "core:math/linalg"
import "core:mem"
import "core:path/filepath"
import "core:simd"
import "core:slice"
import "core:strings"
import sdl "vendor:sdl3"
import sdli "vendor:sdl3/image"


Model :: struct {
	vert_bufs:    [Vert_Idx]sdl.GPUBufferBinding,
	index_buf:    sdl.GPUBufferBinding,
	textures:     []^sdl.GPUTexture,
	samplers:     []^sdl.GPUSampler,
	primitives:   []Model_Primitive,
	meshes:       []Model_Mesh,
	nodes:        []Model_Node,
	dir_lights:   []GPU_Dir_Light,
	spot_lights:  []GPU_Spot_Light,
	point_lights: []GPU_Point_Light,
	area_lights:  []GPU_Area_Light,
	materials:    []Model_Material,
	node_map:     map[string]u32,
}

Model_Material :: struct {
	name:         Maybe(string),
	normal_scale: f32,
	ao_strength:  f32,
	bindings:     [Mat_Idx]sdl.GPUTextureSamplerBinding,
}
Model_Accessor :: struct {
	buffer: u32,
	offset: u32,
}

Model_Mesh :: struct {
	primitive_offset: u32,
	num_primitives:   u32,
}
Vert_Idx :: enum {
	POS,
	NORMAL,
	TANGENT,
	UV,
	UV1,
}
@(rodata)
Vert_Sizes := [Vert_Idx]u32 {
	.POS ..= .NORMAL         = size_of([3]f32),
	.TANGENT = size_of([4]f32),
	.UV ..= .UV1         = size_of([2]f32),
}

@(private)
calc_vert_size :: proc() -> (size: u32) {
	for attr_size in Vert_Sizes {
		size += attr_size
	}
	return
}

VERT_SIZE := calc_vert_size()

// indexes to accessors
Vert_Link :: struct {
	offset:   u32,
	accessor: u32,
}
Model_Primitive :: struct {
	vert_offset:    i32,
	indices_offset: u32,
	num_indices:    u32,
	material:       u32,
}
Light_Key :: struct {
	idx:  int,
	type: Light_Type,
}
Model_Node :: struct {
	mat:      mat4,
	mesh:     Maybe(u32),
	light:    Maybe(Light_Key),
	children: []u32,
}
Mat_Idx :: enum {
	DIFFUSE,
	NORMAL,
	METAL_ROUGH,
	OCCLUSION,
	EMISSIVE,
	SHADOW,
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
accessor_elem_size :: proc(accessor: gltf.Accessor) -> (size: u32) {
	component_size: u32
	switch accessor.component_type {
	case .Unsigned_Byte, .Byte:
		component_size = 1
	case .Unsigned_Short, .Short:
		component_size = 2
	case .Unsigned_Int, .Float:
		component_size = 4
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
	return component_size * container_size
}
accessor_size :: proc(accessor: gltf.Accessor) -> (size: u32) {
	return accessor_elem_size(accessor) * accessor.count
}
copy_accessor :: proc(dst: [^]byte, data: ^gltf.Data, accessor: gltf.Accessor) {
	assert(
		accessor.buffer_view != nil,
		"buf_iter_make: selected accessor doesn't have buffer_view",
	)

	buffer_view := data.buffer_views[accessor.buffer_view.?]
	if _, ok := accessor.sparse.?; ok {
		assert(false, "Sparse not supported")
	}

	start_byte := accessor.byte_offset + buffer_view.byte_offset
	uri := data.buffers[buffer_view.buffer].uri

	stride, has_stride := buffer_view.byte_stride.?
	switch v in uri {
	case string:
		assert(false, "URI is string")
	case []byte:
		src := raw_data(v[start_byte:])
		if !has_stride {
			size := accessor_size(accessor)
			mem.copy_non_overlapping(dst, src, int(size))
		} else {
			elem_size := accessor_elem_size(accessor)
			elem_size_int := int(elem_size)
			for i := u32(0); i < accessor.count; i += 1 {
				dst_idx := i * elem_size
				src_idx := i * stride
				mem.copy_non_overlapping(dst[dst_idx:], src[src_idx:], elem_size_int)
			}
		}
	}
}

parse_light_type :: proc(light_type_str: string) -> (light_type: Light_Type) {
	switch light_type_str {
	case "directional":
		light_type = .DIR
	case "point":
		light_type = .POINT
	case "spot":
		light_type = .SPOT
	case "area":
		light_type = .AREA
	}
	return
}

load_gltf :: proc(
	r: ^Renderer,
	file_name: string,
) -> (
	model_idx: glist.Glist_Idx,
	err: runtime.Allocator_Error,
) {
	assert(r._copy_pass != nil)
	assert(r._copy_cmd_buf != nil)
	temp_mem := runtime.default_temp_allocator_temp_begin()
	defer runtime.default_temp_allocator_temp_end(temp_mem)
	gltf_ctx: GLTF_Ctx
	gltf_ctx.file_name = file_name
	log.infof("loading model: %s", file_name)

	file_path := filepath.join({model_dist_dir, file_name}, context.temp_allocator)
	data, load_err := gltf.load_from_file(file_path)
	if load_err != nil {
		log.panicf("err loading model %s, reason: %v", file_name, load_err)
	}
	defer gltf.unload(data)
	model: Model
	model.textures = make([]^sdl.GPUTexture, len(data.images))
	model.samplers = make([]^sdl.GPUSampler, len(data.samplers))
	model.meshes = make([]Model_Mesh, len(data.meshes))
	model.nodes = make([]Model_Node, len(data.nodes))
	model.materials = make([]Model_Material, len(data.materials))
	model.node_map = make_map_cap(map[string]u32, len(data.nodes))

	images: {
		if len(data.images) == 0 do break images
		tex_trans_size := u32(0)
		surfaces := make([]^sdl.Surface, len(data.images), context.temp_allocator)
		for gltf_image, i in data.images {
			buf_view_idx, has_buf_view := gltf_image.buffer_view.?
			uri: gltf.Uri
			offset: u32
			length: u32
			if has_buf_view {
				buf_view := data.buffer_views[buf_view_idx]
				uri = data.buffers[buf_view.buffer].uri
				offset = buf_view.byte_offset
				length = buf_view.byte_length
			} else {
				uri = gltf_image.uri
			}
			disk_surface: ^sdl.Surface
			switch mem in uri {
			case string:
				img_path := filepath.join(
					{dist_dir, model_dir, mem},
					context.temp_allocator,
				) or_return
				img_path_cstr := strings.clone_to_cstring(img_path, context.temp_allocator)
				disk_surface = sdli.Load(img_path_cstr)
			case []byte:
				mem_buf_view := raw_data(mem[offset:])
				io_stream := sdl.IOFromMem(mem_buf_view, uint(len(mem)))
				disk_surface = sdli.Load_IO(io_stream, true);sdle.err(disk_surface)
			}
			palette := sdl.GetSurfacePalette(disk_surface)
			surf := sdl.ConvertSurfaceAndColorspace(
				disk_surface,
				.RGBA32,
				palette,
				.SRGB_LINEAR,
				0,
			);sdle.err(surf)
			sdl.DestroySurface(disk_surface)
			surfaces[i] = surf
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
			mem.copy_non_overlapping(tex_transfer_mem[offset:], surf.pixels, size)
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
				{transfer_buffer = tex_trans_buf, offset = offset_u32, pixels_per_row = width},
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
		switch gltf_sampler.wrapS {
		case .Repeat:
			sampler_info.address_mode_u = .REPEAT
		case .Clamp_To_Edge:
			sampler_info.address_mode_u = .CLAMP_TO_EDGE
		case .Mirrored_Repeat:
			sampler_info.address_mode_u = .MIRRORED_REPEAT
		}
		switch gltf_sampler.wrapT {
		case .Repeat:
			sampler_info.address_mode_v = .REPEAT
		case .Clamp_To_Edge:
			sampler_info.address_mode_v = .CLAMP_TO_EDGE
		case .Mirrored_Repeat:
			sampler_info.address_mode_v = .MIRRORED_REPEAT
		}
		gpu_sampler := sdl.CreateGPUSampler(r._gpu, sampler_info);sdle.err(gpu_sampler)
		model.samplers[i] = gpu_sampler
	}

	textures := make([]sdl.GPUTextureSamplerBinding, len(data.textures), context.temp_allocator)
	for gltf_tex, i in data.textures {
		img_idx, has_img := gltf_tex.source.?;assert(has_img)

		textures[i].texture = model.textures[img_idx]
		sampler_idx, has_sampler := gltf_tex.sampler.?
		textures[i].sampler = has_sampler ? model.samplers[sampler_idx] : r._defaut_sampler
	}

	//lights
	has_lights := slice.contains(data.extensions_used, "KHR_lights_punctual")
	light_keyer: []Light_Key
	if has_lights {
		lights_ext_value, has_lights_ext :=
			data.extensions.(json.Object)["KHR_lights_punctual"];assert(has_lights_ext)
		lights_ext_arr, has_lights_arr :=
			lights_ext_value.(json.Object)["lights"];assert(has_lights_arr)

		lights_arr := lights_ext_arr.(json.Array)
		lights_sizer: [Light_Type]int
		light_keyer = make([]Light_Key, len(lights_arr), context.temp_allocator)
		for json_obj_light, i in lights_arr {
			json_light := json_obj_light.(json.Object)
			light_type_str := json_light["type"].(json.String)
			light_type := parse_light_type(light_type_str)
			light_keyer[i] = Light_Key {
				idx  = lights_sizer[light_type],
				type = light_type,
			}
			lights_sizer[light_type] += 1
		}
		model.point_lights = make([]GPU_Point_Light, lights_sizer[.POINT])
		model.dir_lights = make([]GPU_Dir_Light, lights_sizer[.DIR])
		model.spot_lights = make([]GPU_Spot_Light, lights_sizer[.SPOT])
		model.area_lights = make([]GPU_Area_Light, lights_sizer[.AREA])
		mem.zero_item(&lights_sizer)
		for json_obj_light, i in lights_arr {
			json_light := json_obj_light.(json.Object)
			light_type_str := json_light["type"].(json.String)
			light_type := parse_light_type(light_type_str)
			color: [4]f32 = 1.0
			spectral_mult :: [4]f32{3, 10, 1, 1}
			max_lumens_per_watt :: 683.0
			maybe_color, has_color := json_light["color"]
			if has_color {
				light_color := maybe_color.(json.Array)
				for channel, i in light_color {
					color[i] = f32(channel.(json.Float))
				}
			}
			spectral_sensitivity := lal.dot(color, spectral_mult) / 14.0
			intensity_candelas := f32(json_light["intensity"].(json.Float))
			intensity := intensity_candelas / (max_lumens_per_watt * spectral_sensitivity)
			// log.infof("light %d has base color %v", i, color)
			color *= intensity
			switch light_type {
			case .DIR:
				model.dir_lights[lights_sizer[.DIR]] = GPU_Dir_Light {
					color = color,
				}
				lights_sizer[.DIR] += 1
			case .POINT:
				model.point_lights[lights_sizer[.POINT]] = GPU_Point_Light {
					color      = color,
				}
				lights_sizer[.POINT] += 1
			case .SPOT:
				model.spot_lights[lights_sizer[.SPOT]] = GPU_Spot_Light {
					color      = color,
				}
				lights_sizer[.SPOT] += 1
			case .AREA:
				model.area_lights[lights_sizer[.AREA]] = GPU_Area_Light {
					color      = color,
				}
				lights_sizer[.AREA] += 1
			}
			// log.infof("light %d has color * intensity %v", i, color)
		}
	}

	// materials
	for gltf_material, i in data.materials {
		model_material: Model_Material
		model_material.name = gltf_material.name
		base_info, has_base := gltf_material.metallic_roughness.?
		model_material.bindings[.SHADOW] = r._shadow_binding
		if has_base {
			diffuse_tex, has_diffuse := base_info.base_color_texture.?
			model_material.bindings[.DIFFUSE] =
				has_diffuse ? textures[diffuse_tex.index] : load_pixel_f32(r, base_info.base_color_factor)
			metal_rough, has_metal_rough := base_info.metallic_roughness_texture.?
			if has_metal_rough {
				model_material.bindings[.METAL_ROUGH] = textures[metal_rough.index]
			} else {
				pixel := [4]f32{0, base_info.roughness_factor, base_info.metallic_factor, 1.0}
				model_material.bindings[.METAL_ROUGH] = load_pixel_f32(r, pixel)
			}
		} else {
			model_material.bindings[.DIFFUSE] = r._default_diffuse_binding
			model_material.bindings[.METAL_ROUGH] = r._default_orm_binding
		}

		normal, has_normal := gltf_material.normal_texture.?
		if has_normal {
			log.infof("mat=%d has normal tex_index=%d", i, normal.index)
			model_material.bindings[.NORMAL] = textures[normal.index]
			model_material.normal_scale = normal.scale
		} else {
			log.infof("mat=%d no normal :(", i)
			model_material.bindings[.NORMAL] = r._default_normal_binding
			model_material.normal_scale = 1.0
		}
		occlusion, has_occlusion := gltf_material.occlusion_texture.?
		if has_occlusion {
			model_material.bindings[.OCCLUSION] = textures[occlusion.index]
			model_material.ao_strength = occlusion.strength
		} else {
			model_material.bindings[.OCCLUSION] = r._default_orm_binding
			model_material.ao_strength = 1.0
		}
		emissive, has_emissive := gltf_material.emissive_texture.?
		if has_emissive {
			model_material.bindings[.EMISSIVE] = textures[emissive.index]
		} else {
			pixel: [4]f32
			pixel.rgb = gltf_material.emissive_factor
			pixel.a = 1.0
			model_material.bindings[.EMISSIVE] = load_pixel_f32(r, pixel)
		}


		model.materials[i] = model_material
	}

	meshes: {
		vert_counter: u32 = 0
		idx_counter: u32 = 0
		num_primitives := 0

		for gltf_mesh, mesh_idx in data.meshes {
			gltf_ctx.mesh_name = gltf_mesh.name.?
			gltf_ctx.mesh_idx = mesh_idx
			for gltf_primitive, primitive_idx in gltf_mesh.primitives {
				gltf_ctx.primitive_idx = primitive_idx
				if gltf_primitive.mode != .Triangles do panic_primitive_err(gltf_ctx, "Triangles mode")

				ok: bool
				indices_idx: u32
				indices_idx, ok = gltf_primitive.indices.?
				if !ok do panic_primitive_err(gltf_ctx, "indices")
				indices_accessor := data.accessors[indices_idx]
				idx_counter += indices_accessor.count

				pos_accessor_idx := get_primitive_attr(gltf_ctx, gltf_primitive, "POSITION")
				pos_accessor := data.accessors[pos_accessor_idx]
				vert_counter += pos_accessor.count
				num_primitives += 1
			}
		}
		idxs_size := idx_counter * size_of(u16)

		verts_size := vert_counter * VERT_SIZE
		// log.infof("fart=%d", verts_size)
		// assert(1 == 2)
		tbuf_size := idxs_size + verts_size
		props := sdl.CreateProperties();sdle.err(props)
		defer sdl.DestroyProperties(props)
		tbuf_name := fmt.ctprintf("%s_transfer_buf", file_name)
		ok := sdl.SetStringProperty(
			props,
			sdl.PROP_GPU_TRANSFERBUFFER_CREATE_NAME_STRING,
			tbuf_name,
		);sdle.err(ok)
		transfer_buf := sdl.CreateGPUTransferBuffer(
			r._gpu,
			{usage = .UPLOAD, size = tbuf_size, props = props},
		);sdle.err(transfer_buf)
		defer sdl.ReleaseGPUTransferBuffer(r._gpu, transfer_buf)

		transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(
			r._gpu,
			transfer_buf,
			false,
		);sdle.err(transfer_mem)

		vert_offsets: [Vert_Idx]u32
		vert_offset := idxs_size
		#unroll for vert_idx in Vert_Idx {
			vert_offsets[vert_idx] = vert_offset
			vert_offset += Vert_Sizes[vert_idx] * vert_counter
		}

		idx_counter = 0
		vert_counter = 0
		model.primitives = make([]Model_Primitive, num_primitives) or_return
		primitive_offset: u32 = 0

		for gltf_mesh, mesh_idx in data.meshes {
			gltf_ctx.mesh_name = gltf_mesh.name.?
			gltf_ctx.mesh_idx = mesh_idx
			model.meshes[mesh_idx] = Model_Mesh {
				num_primitives   = u32(len(gltf_mesh.primitives)),
				primitive_offset = primitive_offset,
			}

			for gltf_primitive, primitive_idx in gltf_mesh.primitives {
				gltf_ctx.primitive_idx = primitive_idx
				model_primitive: Model_Primitive

				ok: bool
				indices_idx: u32
				indices_idx, _ = gltf_primitive.indices.?
				attrs: [Vert_Idx]i32
				attrs[.POS] = i32(get_primitive_attr(gltf_ctx, gltf_primitive, "POSITION"))
				normal_accessor, has_normal := gltf_primitive.attributes["NORMAL"]
				attrs[.NORMAL] = has_normal ? i32(normal_accessor) : -1
				tangent_accessor, has_tangent := gltf_primitive.attributes["TANGENT"]
				attrs[.TANGENT] = has_tangent ? i32(tangent_accessor) : -1
				uv0_accessor, has_uv0_accessor := gltf_primitive.attributes["TEXCOORD_0"]
				attrs[.UV] = has_uv0_accessor ? i32(uv0_accessor) : -1
				uv1_accessor, has_uv1_accessor := gltf_primitive.attributes["TEXCOORD_1"]
				attrs[.UV1] = has_uv1_accessor ? i32(uv1_accessor) : attrs[.UV]
				model_primitive.material, ok = gltf_primitive.material.?
				if !ok do panic_primitive_err(gltf_ctx, "material")


				idx_offset := idx_counter * size_of(u16)
				idx_accessor := data.accessors[indices_idx]
				copy_accessor(transfer_mem[idx_offset:], data, idx_accessor)
				model_primitive.indices_offset = idx_counter
				model_primitive.num_indices = idx_accessor.count
				idx_counter += idx_accessor.count

				#unroll for vert_idx in Vert_Idx {
					accessor_idx := attrs[vert_idx]
					if accessor_idx != -1 {
						vert_offset := vert_offsets[vert_idx] + vert_counter * Vert_Sizes[vert_idx]
						vert_accessor := data.accessors[accessor_idx]
						copy_accessor(transfer_mem[vert_offset:], data, vert_accessor)
					}
				}
				pos_accessor := data.accessors[attrs[.POS]]
				if !has_normal || !has_tangent {
					idxs := (transmute([^]u16)transfer_mem[idx_offset:])[:idx_accessor.count]
					pos_offset := vert_offsets[.POS] + vert_counter * Vert_Sizes[.POS]
					pos := (transmute([^][3]f32)transfer_mem[pos_offset:])[:pos_accessor.count]
					normal_offset := vert_offsets[.NORMAL] + vert_counter * Vert_Sizes[.NORMAL]
					normals := (transmute([^][3]f32)transfer_mem[normal_offset:])[:pos_accessor.count]
					if !has_normal {
						log.infof("generating normals for mesh: %v", gltf_mesh.name)
						generate_normals(normals, idxs, pos)
					}
					if !has_tangent {
						tangent_offset :=
							vert_offsets[.TANGENT] + vert_counter * Vert_Sizes[.TANGENT]
						dst := (transmute([^][4]f32)transfer_mem[tangent_offset:])[:pos_accessor.count]
						if has_uv0_accessor {
							uv_offset := vert_offsets[.UV] + vert_counter * Vert_Sizes[.UV]
							uvs := (transmute([^][2]f32)transfer_mem[uv_offset:])[:pos_accessor.count]
							log.infof("generating tangents for mesh: %v", gltf_mesh.name)
							generate_tangents(dst, idxs, pos, uvs)
						} else {
							log.infof("generating arbitrary tangents for mesh: %v", gltf_mesh.name)
							generate_arbitrary_tangents(dst, normals)
						}
					}
				}

				model_primitive.vert_offset = i32(vert_counter)
				vert_counter += pos_accessor.count

				model.primitives[primitive_offset] = model_primitive
				primitive_offset += 1
			}
		}
		sdl.UnmapGPUTransferBuffer(r._gpu, transfer_buf)

		upload_indices: {
			props := sdl.CreateProperties();sdle.err(props)
			buf_name := fmt.ctprintf("%s_indices_buf", file_name)
			sdl.SetStringProperty(props, sdl.PROP_GPU_BUFFER_CREATE_NAME_STRING, buf_name)
			index_buf := sdl.CreateGPUBuffer(
				r._gpu,
				{usage = {.INDEX}, size = idxs_size, props = props},
			);sdle.err(index_buf)
			sdl.UploadToGPUBuffer(
				r._copy_pass,
				{transfer_buffer = transfer_buf},
				{buffer = index_buf, size = idxs_size},
				false,
			)
			model.index_buf = sdl.GPUBufferBinding {
				buffer = index_buf,
			}
		}
		#unroll for vert_idx in Vert_Idx {
			props := sdl.CreateProperties();sdle.err(props)
			buf_name := fmt.ctprintf("%s_%v_buf", file_name, vert_idx)
			sdl.SetStringProperty(props, sdl.PROP_GPU_BUFFER_CREATE_NAME_STRING, buf_name)
			size := vert_counter * Vert_Sizes[vert_idx]
			vert_buf := sdl.CreateGPUBuffer(
				r._gpu,
				{usage = {.VERTEX}, size = size, props = props},
			);sdle.err(vert_buf)
			sdl.UploadToGPUBuffer(
				r._copy_pass,
				{transfer_buffer = transfer_buf, offset = vert_offsets[vert_idx]},
				{buffer = vert_buf, size = size},
				false,
			)
			model.vert_bufs[vert_idx] = sdl.GPUBufferBinding {
				buffer = vert_buf,
			}
		}
	}
	// nodes 
	for gltf_node, i in data.nodes {
		node: Model_Node
		// node lights

		node_exts, has_exts := gltf_node.extensions.(json.Object)
		if has_lights && has_exts {
			lights_ext, ok := node_exts["KHR_lights_punctual"]
			if ok {
				light_idx := u32(lights_ext.(json.Object)["light"].(json.Float))
				node.light = light_keyer[light_idx]
				// log.infof("node %d has light %d", i, node.light)
			}
		}
		// node meshes
		if gltf_node.mat == lal.MATRIX4F32_IDENTITY {
			node.mat = lal.matrix4_from_trs(
				gltf_node.translation,
				gltf_node.rotation,
				gltf_node.scale,
			)
		} else {
			node.mat = gltf_node.mat
		}
		node.mesh = gltf_node.mesh
		node.children = slice.clone(gltf_node.children)
		// log.infof("node %d has children %v", i, node.children)
		model.nodes[i] = node
		name, has_name := gltf_node.name.?
		if has_name {
			name = strings.clone(name)
			model.node_map[name] = u32(i)
		}
	}

	model_idx = glist.insert(&r.models, model) or_return
	r.model_map[file_name] = model_idx
	return
}


generate_tangents :: proc(dst: [][4]f32, idxs: []u16, pos: [][3]f32, uvs: [][2]f32) {
	for i := 0; i < len(idxs); i += 3 {
		idx1 := idxs[i]
		idx2 := idxs[i + 1]
		idx3 := idxs[i + 2]

		pos1 := pos[idx1]
		pos2 := pos[idx2]
		pos3 := pos[idx3]
		// log.infof("idx=%d pos1=%v", i, pos1)
		// log.infof("idx=%d pos2=%v", i, pos2)
		// log.infof("idx=%d pos3=%v", i, pos3)

		uv1 := uvs[idx1]
		uv2 := uvs[idx2]
		uv3 := uvs[idx3]
		// log.infof("idx=%d uv1=%v", i, uv1)
		// log.infof("idx=%d uv2=%v", i, uv2)
		// log.infof("idx=%d uv3=%v", i, uv3)

		edge1 := pos2 - pos1
		edge2 := pos3 - pos1
		delta_uv1 := uv2 - uv1
		delta_uv2 := uv3 - uv1

		f := 1.0 / (delta_uv1.x * delta_uv2.y - delta_uv2.x * delta_uv1.y)
		// log.infof("idx=%d f=%.2f", i, f)
		tangent := f * (delta_uv2.y * edge1 - delta_uv1.y * edge2)

		dst[idx1].xyz = tangent
		dst[idx1].w = 1.0
		dst[idx2].xyz = tangent
		dst[idx2].w = 1.0
		dst[idx3].xyz = tangent
		dst[idx3].w = 1.0
		// log.infof("idx=%d tangent=%v", i, tangent)
	}
}

generate_arbitrary_tangents :: proc(dst: [][4]f32, normals: [][3]f32) {
	for i := 0; i < len(normals); i += 1 {
		normal := lal.normalize(normals[i])
		arbitrary := abs(normal.y) < 0.999 ? [3]f32{0, 1, 0} : [3]f32{1, 0, 0}
		tangent := lal.normalize(lal.cross(arbitrary, normal))
		dst[i].xyz = tangent
		dst[i].w = 1.0
	}
}

// smooth shaded
generate_normals :: proc(dst: [][3]f32, idxs: []u16, pos: [][3]f32) {
	mem.set(raw_data(dst), 0, len(dst) * size_of([3]f32))

	for i := 0; i < len(idxs); i += 3 {
		idx1 := idxs[i]
		idx2 := idxs[i + 1]
		idx3 := idxs[i + 2]

		pos1 := pos[idx1]
		pos2 := pos[idx2]
		pos3 := pos[idx3]
		// log.infof("idx=%d pos1=%v", i, pos1)
		// log.infof("idx=%d pos2=%v", i, pos2)
		// log.infof("idx=%d pos3=%v", i, pos3)

		// log.infof("idx=%d uv1=%v", i, uv1)
		// log.infof("idx=%d uv2=%v", i, uv2)
		// log.infof("idx=%d uv3=%v", i, uv3)

		edge1 := pos2 - pos1
		edge2 := pos3 - pos1
		face_normal := lal.normalize(lal.cross(edge1, edge2))
		dst[idx1] += face_normal
		dst[idx2] += face_normal
		dst[idx3] += face_normal
	}
	for normal, i in dst {
		dst[i] = lal.normalize(normal)
	}
}

