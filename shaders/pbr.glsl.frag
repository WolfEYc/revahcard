#version 460

#define PI 3.1415926538

struct Point_Light {
    vec4 pos;
    vec4 color;
};

struct Dir_Light {
    vec4 dir_to_light;
    vec4 color;
};

struct Spot_Light {
    vec4 pos;
    vec4 color;
    vec4 dir;
    float inner_cone_angle;
    float outer_cone_angle;
    vec2 _pad0;
};

struct Area_Light {
    vec4 pos;         // xyz = center position, w = unused or light intensity
    vec4 color;       // rgb = color, a = intensity or scale
    vec4 right;       // xyz = tangent vector of the rectangle, w = half-width
    vec4 up;          // xyz = bitangent vector, w = half-height
    float two_sided;  // 1.0 = light both sides, 0.0 = only front side
    vec3 _pad;        
};


layout(set=2, binding=0) uniform sampler2D diffuse_sampler;
layout(set=2, binding=1) uniform sampler2D normal_sampler;
layout(set=2, binding=2) uniform sampler2D metal_rough_sampler;
layout(set=2, binding=3) uniform sampler2D ao_sampler;
layout(set=2, binding=4) uniform sampler2D emissive_sampler;

// layout(set=2, binding=5) uniform sampler2DArrayShadow shadow_sampler; //TODO

#define LIGHT_MAX 4
layout(set=2, binding=5) readonly buffer Light_Buf {
    uint num_dir_lights;
    uint num_point_lights;
    uint num_spot_lights;
    uint num_area_lights;
    Point_Light point_lights[LIGHT_MAX];
    Dir_Light dir_lights[LIGHT_MAX];
    Spot_Light spot_lights[LIGHT_MAX];
    Area_Light area_lights[LIGHT_MAX];
};

layout(set=3, binding=0) uniform Frame_UBO {
    vec4 cam_world_pos;
    vec4 ambient_light_color;
};

layout(set=3, binding=1) uniform Draw_UBO {
    float normal_scale;
    float ao_strength;
};

layout(location=0) in vec3 in_world_pos;
layout(location=1) in mat3 in_tbn;
layout(location=2) in vec2 in_uv;
layout(location=3) in vec2 in_uv1;

layout(location=0) out vec4 out_color;

vec3 calc_normal() {
    vec3 normal = texture(normal_sampler, in_uv).xyz;
    normal = normal * 2.0 - 1.0;
    normal = normalize(in_tbn * normal); 
    return normal;
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

struct BRDF_Args {
    vec3 F0;
    vec3 radiance;
    vec3 dir_to_light;
    vec3 dir_to_cam;
    vec3 diffuse;
    vec3 normal;
    float metallic;
    float roughness;
} brdf_args;

vec3 brdf()  {
    vec3 halfway = normalize(brdf_args.dir_to_light + brdf_args.dir_to_cam);
    float cos_theta = max(dot(halfway, brdf_args.dir_to_cam), 0.0);
    vec3 F = fresnel(cos_theta, brdf_args.F0);
    float NDF = distribution_ggx(brdf_args.normal, halfway, brdf_args.roughness);
    float normal_dot_view = max(dot(brdf_args.normal, brdf_args.dir_to_cam),0.0);
    float normal_dot_light = max(dot(brdf_args.normal, brdf_args.dir_to_light), 0.0);
    float G = geometry_smith(normal_dot_view, normal_dot_light, brdf_args.roughness);

    vec3 numerator = NDF * G * F;
    float denominator = 4.0 * normal_dot_view * normal_dot_light + 0.0001;
    vec3 specular = numerator / denominator;

    vec3 kD = vec3(1.0) - F;
    kD *= 1.0 - brdf_args.metallic;
    return (kD * brdf_args.diffuse / PI + specular) * brdf_args.radiance * normal_dot_light;
}

void main() {
    brdf_args.diffuse = texture(diffuse_sampler, in_uv).rgb;
    vec3 emissive = texture(emissive_sampler, in_uv).rgb;
    brdf_args.normal = calc_normal();
    vec4 metal_rough = texture(metal_rough_sampler, in_uv);
    brdf_args.roughness = metal_rough.g;
    brdf_args.metallic = metal_rough.b;
    float ao = texture(ao_sampler, in_uv1).r;
    ao = mix(1.0, ao, ao_strength);

    brdf_args.dir_to_cam = normalize(cam_world_pos.xyz - in_world_pos);
    brdf_args.F0 = mix(vec3(0.04), brdf_args.diffuse, brdf_args.metallic); // surface reflection at 0 incidence

    vec3 color = vec3(0.0);
    for (uint i = 0; i < num_dir_lights; i++) {
        Dir_Light dir_light = dir_lights[i];

        brdf_args.radiance = dir_light.color.rgb;
        brdf_args.dir_to_light = dir_light.dir_to_light.xyz;

        color += brdf();
    }
    for (uint i = 0; i < num_point_lights; i++) {
        Point_Light point_light = point_lights[i];

        vec3 vec_to_light = point_light.pos.xyz - in_world_pos;
        float sqr_to_light = dot(vec_to_light, vec_to_light);
        float attenuation = 1.0 / sqr_to_light;
        brdf_args.radiance = point_light.color.rgb * attenuation;
        brdf_args.dir_to_light = vec_to_light * inversesqrt(sqr_to_light);

        color += brdf();
    }

    vec3 ambient = ambient_light_color.rgb * brdf_args.diffuse * ao;
    color += ambient;
    color += emissive;

    // HDR Reinhard tonemapping
    color /= color + vec3(1.0);

    out_color = vec4(color, 1.0);
}
