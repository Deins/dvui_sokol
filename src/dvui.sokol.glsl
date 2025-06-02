// get shader compiler (prebuilt executable in releases or compile from C++ source): https://github.com/floooh/sokol-tools/blob/master/docs/sokol-shdc.md
// can be compiled to zig with: ./sokol-shdc -i dvui.sokol.glsl -o dvui.sokol.glsl.zig -f sokol_zig --slang glsl430:glsl300es:hlsl5:metal_macos:wgsl
// some of the target `--slang` options can be skipped if not needed or more added. Default should cover most platforms.

@vs vs
// flip_vert_y didn't work on windows, had to implement on my own, not sure about fixup_clipspace, but for now skipping it
// TODO: test glsl & web targets
// @glsl_options flip_vert_y
// @glsl_options fixup_clipspace

layout(location=0) in vec2 in_pos;
layout(location=1) in vec4 in_col;
layout(location=2) in vec2 in_uv;

layout(set = 0, binding = 1) uniform UBO {
    vec2 framebuffer_size;
};

out vec4 col;
out vec2 uv;

void main() {
    vec2 p = in_pos;
    // scale from screen space coordinates to clip space coordinates
    p *= 2.0 / framebuffer_size;
    p -= vec2(1, 1);
    // flip y coordinate, culling direction in app therefore will also be flipped
    p.y = -p.y; 
    
    gl_Position = vec4(p, 0.0, 1.0);
    col = in_col;
    uv = in_uv;
}
@end

@fs fs
in vec4 col;
in vec2 uv;
out vec4 frag_color;

layout(binding=0) uniform sampler in_sampler;
layout(binding=0) uniform texture2D in_texture;

void main() {
    frag_color = texture(sampler2D(in_texture, in_sampler), uv);
    frag_color *= col;
}
@end

@program sokol vs fs