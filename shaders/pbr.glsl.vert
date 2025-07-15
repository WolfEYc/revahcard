#version 460

#define MAX_TRANSFORMS 4096

layout(set=0, binding=0) readonly buffer Mvp_Buffer {
    mat4 ms[MAX_TRANSFORMS]; // model matrices
    mat4 ns[MAX_TRANSFORMS]; // normal matrices
};

layout(set=1, binding=0) uniform Vert_UBO {
    mat4 vp;
};

layout(location=0) in vec3 pos;
layout(location=1) in vec3 normal;
layout(location=2) in vec2 uv;
layout(location=3) in vec2 uv1;

layout(location=0) out vec3 out_pos;
layout(location=1) out vec3 out_normal;
layout(location=2) out vec2 out_uv;
layout(location=3) out vec2 out_uv1;


void main() {
    mat4 m = ms[gl_InstanceIndex];
    vec4 world_pos = m * vec4(pos, 1.0);
    gl_Position = vp * world_pos;
    out_pos = world_pos.xyz;
    mat4 n = ns[gl_InstanceIndex];
    out_normal = normalize((n * vec4(normal, 0.0)).xyz);
    out_uv = uv;
    out_uv1 = uv1;
}
