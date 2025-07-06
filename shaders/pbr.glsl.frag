#version 460

#define PI 3.1415926538

layout(set=2, binding=0) uniform sampler2D diffuse_sampler;
layout(set=2, binding=1) uniform sampler2D normal_sampler;
layout(set=2, binding=2) uniform sampler2D metal_rough_sampler;
layout(set=2, binding=3) uniform sampler2D ao_sampler;
layout(set=2, binding=4) uniform sampler2D emissive_sampler;

struct Point_Light {
    vec4 pos;
    vec4 color;
};

layout(set=2, binding=5) readonly buffer Point_Lights {
    vec3 _lightpad0;
    uint num_point_lights;
    Point_Light point_lights[4];
};

layout(set=3, binding=0) uniform Frame_UBO {
    vec4 cam_world_pos;
    vec4 ambient_light_color;
    vec4 dir_to_sun;
    vec4 sun_color;
};

layout(set=3, binding=1) uniform Draw_UBO {
    float normal_scale;
    float ao_strength;
};

layout(location=0) in vec3 in_world_pos;
layout(location=1) in vec2 in_uv;
layout(location=2) in vec2 in_uv1;
layout(location=3) in vec3 in_normal;
layout(location=4) in vec3 in_tangent;

layout(location=0) out vec4 out_color;

vec3 calc_normal() {
    vec3 normal = normalize(in_normal);
    vec3 tangent = normalize(in_tangent);
    tangent = normalize(tangent - dot(tangent, normal) * normal);
    vec3 bitangent = cross(tangent, normal);
    vec3 bump_map_normal = texture(normal_sampler, in_uv).xyz * 2.0 - 1.0;
    bump_map_normal.xy *= normal_scale;
    mat3 TBN = mat3(tangent, bitangent, normal);
    vec3 new_normal = TBN * bump_map_normal;
    new_normal = normalize(new_normal);
    return new_normal;
}

vec3 fresnel(float cos_theta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cos_theta, 0.0, 1.0), 5.0);
}

float distribution_ggx(vec3 normal, vec3 halfway, float roughness) {
    float sqr_roughness = roughness * roughness;
    float quad_roughness = sqr_roughness * sqr_roughness;
    float normal_dot_halfway = max(dot(normal, halfway), 0.0);
    float sqr_normal_dot_halfway = normal_dot_halfway * normal_dot_halfway;

    float denom = sqr_normal_dot_halfway * (quad_roughness - 1.0) + 1.0;
    denom = PI * denom * denom;
    return quad_roughness / denom;
}

float geometry_schlick_ggx(float normal_dot_view, float roughness) {
    float r = roughness + 1.0;
    float sqr_r = r * r;
    float k = sqr_r / 8.0;
    float denom = normal_dot_view * (1.0 - k) + k;
    return normal_dot_view / denom;
}

float geometry_smith(float normal_dot_view, float normal_dot_light, float roughness) {
    float ggx2 = geometry_schlick_ggx(normal_dot_view, roughness);
    float ggx1 = geometry_schlick_ggx(normal_dot_light, roughness);

    return ggx1 * ggx2;
}

vec3 brdf(vec3 F0, vec3 radiance, vec3 dir_to_light, vec3 dir_to_cam) {
    vec3 halfway = normalize(dir_to_light + dir_to_cam);
    float cos_theta = max(dot(halfway, dir_to_cam), 0.0);
    vec3 F = fresnel(cos_theta, F0);
    float NDF = distribution_ggx(normal, halfway, roughness);
    float normal_dot_view = max(dot(normal, dir_to_cam),0.0);
    float normal_dot_light = max(dot(normal, dir_to_light), 0.0);
    float G = geometry_smith(normal_dot_view, normal_dot_light, roughness);

    vec3 numerator = NDF * G * F;
    float denominator = 4.0 * normal_dot_view * normal_dot_light + 0.0001;
    vec3 specular = numerator / denominator;

    vec3 kD = vec3(1.0) - F;
    kD *= 1.0 - metallic;
    return (kD * diffuse / PI + specular) * radiance * normal_dot_light;
}

void main() {
    vec3 diffuse = texture(diffuse_sampler, in_uv).rgb;
    vec3 emissive = texture(emissive_sampler, in_uv).rgb;
    vec3 normal = calc_normal();
    vec4 metal_rough = texture(metal_rough_sampler, in_uv);
    float ao = texture(ao_sampler, in_uv1).r;
    ao = mix(1.0, ao, ao_strength);
    float roughness = metal_rough.g;
    float metallic = metal_rough.b;

    vec3 dir_to_cam = normalize(cam_world_pos.xyz - in_world_pos);
    vec3 F0 = mix(vec3(0.04), diffuse, metallic); // surface reflection at 0 incidence

    vec3 color = brdf(F0, sun_color.rgb, dir_to_sun.xyz, dir_to_cam);
    for (uint i = 0; i < num_point_lights; i++) {
        Light point_light = point_lights[i];

        vec3 vec_to_light = light.pos.xyz - in_world_pos;
        float sqr_to_light = dot(vec_to_light, vec_to_light);
        float attenuation = 1.0 / sqr_to_light;
        vec3 radiance = light.color.rgb * attenuation;
        vec3 dir_to_light = vec_to_light * inversesqrt(sqr_to_light);

        color += brdf(F0, radiance, dir_to_light, dir_to_cam);
    }

    vec3 ambient = ambient_light_color.rgb * diffuse * ao;
    color += ambient;
    color += emissive;

    // HDR Reinhard tonemapping
    color /= color + vec3(1.0);    

    out_color = vec4(color, 1.0);
}
