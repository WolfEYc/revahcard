#version 460

layout(set=2, binding=0) uniform sampler2D albedo_sampler;
layout(set=2, binding=1) uniform sampler2D normal_sampler;
layout(set=2, binding=2) uniform sampler2D orm_sampler;
layout(set=2, binding=3) uniform sampler2D emissive_sampler;

// vec4 for padding
struct Light {
    vec3 pos;
    float _pad;
    vec4 color;
};

layout(set=2, binding=4) readonly buffer Lights {
    Light lights[64];
};

layout(set=3, binding=0) uniform Frag_UBO {
    vec3 cam_world_pos;
    uint rendered_lights;
    vec3 ambient_light_color;
};

layout(location=0) in vec3 world_pos0;
layout(location=1) in vec2 uv0;
layout(location=2) in vec3 normal0;
layout(location=3) in vec3 tangent0;

layout(location=0) out vec4 out_color;

vec3 fresnel_schlick(float cos_theta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cos_theta, 0.0, 1.0), 5.0);
}

vec3 calc_normal() {
    vec3 normal = normalize(normal0);
    vec3 tangent = normalize(tangent0);
    tangent = normalize(tangent - dot(tangent, normal) * normal);
    vec3 bitangent = cross(tangent, normal);
    vec3 bump_map_normal = texture(normal_sampler, uv0).xyz;
    bump_map_normal = 2.0 * bump_map_normal - vec3(1.0);
    mat3 TBN = mat3(tangent, bitangent, normal);
    vec3 new_normal = TBN * bump_map_normal;
    new_normal = normalize(new_normal);
    return new_normal;
}

void main() {
    vec3 albedo = texture(albedo_sampler, uv0);
    vec3 normal = calc_normal();
    vec3 orm = texture(orm_sampler, uv0).rgb;
    vec3 dir_to_cam = normalize(cam_world_pos - world_pos0);
    float occlusion = orm.r;
    float roughness = orm.g;
    float metallic = orm.b;

    for (uint i = 0; i < rendered_lights; i++) {
        Light light = lights[i];
        vec3 vec_to_light = light.pos - world_pos0;
        float sqr_to_light = dot(vec_to_light, vec_to_light);
        float attenuation = 1.0 / sqr_to_light;
        vec3 radiance = light.color.rgb * attenuation;
        vec3 dir_to_light = vec_to_light * inversesqrt(vec_to_light);
        vec3 halfway = normalize(dir_to_light + dir_to_cam);

        // Cook-Torrance BRDF
        vec3 F0 = mix(vec3(0.04), albedo, metallic) // surface reflection at 0 incidence
        float cos_theta = max(dot(H, V), 0.0);
        vec3 F = frensel_schlick(cos_theta, F0)
        
    }

    
}
