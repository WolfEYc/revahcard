#version 460

layout(set=0, binding=0) readonly buffer Mvp_Buffer {
    mat4 m[4096];
};

layout(set=1, binding=0) uniform Vert_UBO {
    mat4 vp;
};

layout(location=0) in vec3 pos;
layout(location=1) in vec2 uv;
layout(location=2) in vec3 normal; //TODO gimme from CPU

layout(location=0) out vec3 out_pos;
layout(location=1) out vec2 out_uv;
layout(location=2) out vec3 out_normal;

void main() {
    vec4 world_pos = m[gl_InstanceIndex] * vec4(pos, 1);
    gl_Position = vp * world_pos;
    out_uv = uv;
    out_pos = world_pos.xyz;
}
