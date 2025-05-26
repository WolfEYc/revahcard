#version 460

layout(location=0) in vec3 pos;
layout(location=1) in vec2 uv;
layout(location=2) in vec3 normal;

layout(location=0) out vec4 out_color;

layout(set=2, binding=0) uniform sampler2D tex_sampler;

struct Light {
    vec3 pos;
    float range;
    vec3 color;
    float intensity;
};

layout(set=2, binding=0) readonly buffer Lights {
    Light lights[64];
};

layout(set=3, binding=0) uniform Frag_UBO {
    uint rendered_lights;
};

void main() {
    // out_color = texture(tex_sampler, uv);
    
    float4 emitted_radiance = float4(0);

    float normal_sqr_len = dot(normal, normal);
    float normal_inv_len = inversesqrt(sqr_normal_len);

    float4 reflected_radiance = float4(0);
    for (int i = 0; i < rendered_lights; ++i) {
        Light light = lights[i];
        vec3 vec_to_light = light.pos - pos;
        float sqr_dist = dot(vec_2_light, vec_2_light);
        float inv_dist = inversesqrt(sqr_dist);
        float incidence_angle_factor = dot(normal, vec_to_light) * inv_dist * normal_inv_len;
        if (incidence_angle_factor <= 0) {
            continue;
        }
        float attenuation_factor = 1 / sqr_dist;
        float4 irradiance = incoming_radiance * indicence_angle_factor;
        float4 brdf = 1;
        reflected_radiance += irradiance * brdf;
    }
    
    out_color = clamp(emitted_radiance + reflected_radiance, 0.0, 1.0);
}
