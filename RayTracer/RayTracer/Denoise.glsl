#version 430
layout(local_size_x = 8, local_size_y = 8) in;

layout(rgba32f, binding = 2) uniform image2D noisyColor; // 
layout(rgba32f, binding = 6) uniform image2D gNormal;   // 
layout(r32f, binding = 7) uniform image2D gDepth;    // 
layout(rgba32f, binding = 0) uniform image2D finalImage; // 

uniform int width;
uniform int height;

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (p.x >= width || p.y >= height) return;

    vec3 centerCol = imageLoad(noisyColor, p).rgb;
    vec3 centerNorm = imageLoad(gNormal, p).rgb * 2.0 - 1.0;
    float centerDepth = imageLoad(gDepth, p).r;

    vec3 sumCol = vec3(0.0);
    float sumW = 0.0;

    int r = 3;
    for (int x = -r; x <= r; x++) {
        for (int y = -r; y <= r; y++) {
            ivec2 q = p + ivec2(x, y);
            if (q.x < 0 || q.x >= width || q.y < 0 || q.y >= height) continue;

            vec3 qCol = imageLoad(noisyColor, q).rgb;
            vec3 qNorm = imageLoad(gNormal, q).rgb * 2.0 - 1.0;
            float qDepth = imageLoad(gDepth, q).r;

            
            float w_s = exp(-(x * x + y * y) / (2.0 * r * r));

            
            float w_n = pow(max(0.0, dot(centerNorm, qNorm)), 64.0);

            
            float w_d = exp(-abs(centerDepth - qDepth) / 0.1);

            float weight = w_s * w_n * w_d;
            sumCol += qCol * weight;
            sumW += weight;
        }
    }

    imageStore(finalImage, p, vec4(sumCol / max(sumW, 0.00001), 1.0));
}