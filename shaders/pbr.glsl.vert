#version 460

layout(set=0, binding=0) readonly buffer Mvp_Buffer {
    mat4 ms[4096]; // model matrices
    // mat4 ns[4096]; // normal matrices
};

layout(set=1, binding=0) uniform Vert_UBO {
    mat4 vp;
};

layout(location=0) in vec3 pos;
layout(location=1) in vec2 uv;
layout(location=2) in vec2 uv1;
layout(location=3) in vec3 normal;
layout(location=4) in vec3 tangent;

layout(location=0) out vec3 out_pos;
layout(location=1) out vec2 out_uv;
layout(location=2) out vec2 out_uv1;
layout(location=3) out vec3 out_normal;
layout(location=4) out vec3 out_tangent;

void main() {
    mat4 m = ms[gl_InstanceIndex];
    vec4 world_pos = m * vec4(pos, 1);
    gl_Position = vp * world_pos;
    out_pos = world_pos.xyz;
    out_uv = uv;
    // mat4 n = ns[gl_InstanceIndex];
    out_normal = (m * vec4(normal, 0.0)).xyz;
    out_tangent = (m * vec4(tangent, 0.0)).xyz;
}
