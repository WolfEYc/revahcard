#version 460

layout(set=2, binding=0) uniform sampler2D diffuse_sampler;
layout(set=2, binding=1) uniform sampler2D specular_shiny_sampler;
layout(set=2, binding=2) uniform sampler2D emissive_sampler;

struct Light {
    vec3 pos;
    float sqr_range;
    vec3 color;
    float intensity;
};

layout(set=2, binding=3) readonly buffer Lights {
    Light lights[64];
};

layout(set=3, binding=0) uniform Frag_UBO {
    vec3 view_pos;
    uint rendered_lights;
    vec3 ambient_light_color;
};

layout(location=0) in vec3 pos;
layout(location=1) in vec2 uv;
layout(location=2) in vec3 normal;

layout(location=0) out vec4 out_color;

void main() {
    vec3 diffuse = texture(diffuse_sampler, uv).rgb;
    vec4 specular_shiny = texture(specular_shiny_sampler, uv);
    float shinyness = specular_shiny.a;
    vec3 specular_color = specular_shiny.rgb;

    vec3 surface_normal = normalize(normal);
    vec3 dir_to_view = normalize(view_pos - pos);
    vec3 reflected_radiance = diffuse * ambient_light_color;
    for (int i = 0; i < rendered_lights; ++i) {
        Light light = lights[i];
        vec3 vec_to_light = light.pos - pos;
        float sqr_dist_light = dot(vec_to_light, vec_to_light);
        float inv_sqr_dist_light = inversesqrt(sqr_dist_light);
        vec3 dir_to_light = vec_to_light * inv_sqr_dist_light;
        float angle_factor = dot(dir_to_light, surface_normal);
        if (angle_factor <= 0 || sqr_dist_light > light.sqr_range) {
            continue;
        }
        float attenuation_factor = 1 / (sqr_dist_light + 1);
        vec3 incoming_radiance = light.color * light.intensity;
        vec3 irradiance = incoming_radiance * angle_factor * attenuation_factor;

        // blinn phong brdf
        vec3 halfway_dir = normalize(dir_to_light + dir_to_view);
        float specular_dot = max(0, dot(halfway_dir, surface_normal));
        float specular_factor = pow(specular_dot, 100 * shinyness);
        vec3 specular_reflection = specular_color * specular_factor;
        vec3 brdf = clamp(diffuse + specular_reflection, 0, 1);

        reflected_radiance += irradiance * brdf;
    }
    vec3 emitted_radiance = texture(emissive_sampler, uv).rgb;
    vec3 radiance = clamp(emitted_radiance + reflected_radiance, 0, 1);
    out_color = vec4(radiance, 1);
}
