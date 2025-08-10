#version 460

#define MAX_TRANSFORMS 4096

layout(set=0, binding=0) readonly buffer Mvp_Buffer {
    mat4 ms[MAX_TRANSFORMS]; // model matrices
    mat4 ns[MAX_TRANSFORMS]; // normal matrices
};

layout(set=1, binding=0) uniform Vert_UBO {
    mat4 vp;
    mat4 shadow_vp;
};

layout(location=0) in vec3 pos;
layout(location=1) in vec3 normal;
layout(location=2) in vec4 tangent;
layout(location=3) in vec2 uv;
layout(location=4) in vec2 uv1;

layout(location=0) out vec3 out_pos;
layout(location=1) out vec4 out_shadow_pos;
layout(location=2) out vec2 out_uv;
layout(location=3) out vec2 out_uv1;
layout(location=4) out mat3 out_tbn;


void main() {
    mat4 model_mat = ms[gl_InstanceIndex];
    vec4 world_pos = model_mat * vec4(pos, 1.0);
    gl_Position = vp * world_pos;
    out_pos = world_pos.xyz;
    out_shadow_pos = shadow_vp * world_pos;
    out_uv = uv;
    out_uv1 = uv1;
    mat4 normal_mat = ns[gl_InstanceIndex];
    vec3 T = normalize((normal_mat * vec4(tangent.xyz, 0.0)).xyz);
    vec3 N = normalize((normal_mat * vec4(normal, 0.0)).xyz);
    T = normalize(T - dot(T, N) * N);
    vec3 B = cross(N, T) * tangent.w;
    out_tbn = mat3(T, B, N);
}
