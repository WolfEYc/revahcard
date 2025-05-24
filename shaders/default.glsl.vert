#version 460

layout(set=0, binding=0) buffer Mvp_Buffer {
    mat4 mvps[65536];
};

layout(location=0) in vec3 pos;
layout(location=1) in vec2 uv;

layout(location=0) out vec2 out_uv;

void main() {
    gl_Position = mvps[gl_InstanceIndex] * vec4(pos, 1);
    out_uv = uv;
}
