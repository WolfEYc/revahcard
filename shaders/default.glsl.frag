#version 460

layout(set=2, binding=0) uniform sampler2D base_sampler;
layout(set=2, binding=1) uniform sampler2D emissive_sampler;

struct Light {
    vec3 pos;
    float range;
    vec3 color;
    float intensity;
};

layout(set=2, binding=2) readonly buffer Lights {
    Light lights[64];
};

layout(set=3, binding=0) uniform Frag_UBO {
    uint rendered_lights;
};

layout(location=0) in vec3 pos;
layout(location=1) in vec2 uv;
layout(location=2) in vec3 normal;

layout(location=0) out vec4 out_color;

void main() {
    // out_color = texture(tex_sampler, uv);
    
    vec3 emitted_radiance = texture(emissive_sampler, uv).xyz;

    vec3 surface_normal = normalize(normal);

    vec3 reflected_radiance = vec3(0);
    for (int i = 0; i < rendered_lights; ++i) {
        Light light = lights[i];
        vec3 vec_to_light = light.pos - pos;
        float dist_to_light = length(vec_to_light);
        vec3 dir_to_light = vec_to_light / dist_to_light;
        float angle_factor = dot(dir_to_light, surface_normal);
        if (angle_factor <= 0) {
            continue;
        }
        float attenuation_factor = 1 / (dist_to_light * dist_to_light);
        vec3 incoming_radiance = light.color * light.intensity;
        vec3 irradiance = incoming_radiance * angle_factor * attenuation_factor;
        vec3 brdf = vec3(1);
        reflected_radiance += irradiance * brdf;
    }
    vec3 radiance = clamp(emitted_radiance + reflected_radiance, 0, 1);
    vec4 base_color = texture(base_sampler, uv);
    out_color = base_color * vec4(radiance, 1);
}
