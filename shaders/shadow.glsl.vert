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

void main() {
    gl_Position = vp * ms[gl_InstanceIndex] * vec4(pos, 1.0);    
}
