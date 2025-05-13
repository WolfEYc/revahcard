#version 460

layout(set=1, binding=0) uniform Mvp_Ubo {
    mat4 mvps[64];
};

layout(location=0) in vec3 pos;
layout(location=1) in vec2 uv;

layout(location=0) out vec2 out_uv;

void main() {
    mat4 mvp = mvps[gl_InstanceIndex];
    gl_Position = mvp * vec4(pos, 1);
    out_uv = uv;
}
