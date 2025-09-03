#version 460

layout(location=0) flat in int instance_idx;

layout(location=0) out int out_color;

void main() {
    out_color = instance_idx;
}
