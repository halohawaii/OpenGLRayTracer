#version 430

layout(local_size_x = 8, local_size_y = 8) in;

struct Ray
{
    vec3 origin;
    float _pad0;
    vec3 direction;
    float _pad1;
};

layout(std430, binding = 1)
buffer Rays
{
    Ray rays[];
};

layout(std140, binding = 0) uniform Camera
{
    vec3 camPos;
    float fov;
    vec3 camForward;
    float _pad0;
    vec3 camRight;
    float _pad1;
    vec3 camUp;
};

struct Triangle {
    vec3 v0; float _p0;
    vec3 v1; float _p1;
    vec3 v2; float _p2;
    vec3 n0; float _p3;
    vec3 n1; float _p4;
    vec3 n2; float _p5;
    vec3 normal;
    float hasVPNormal;
    vec3 emission; float _p6;
    vec3 color;  float _p7;
    vec3 Ks;
    float specularExponent;
};

layout(std430, binding = 3) buffer MeshBuffer {
    Triangle triangles[];
};

struct BVHNode {
    vec3 pMin;
    int leftChild;  
    
    vec3 pMax;
    int rightChild; 
    
    int nPrimitives;
    int primitiveIdx;
    int area;      
    int _pad;
    vec4 _final_pads;
};

layout(std430, binding = 4) buffer BVHBuffer {
    BVHNode nodes[];
};

layout(std430, binding = 5) buffer LightIndexBuffer {
    int lightIndices[]; // light triangles
};

uniform int imageWidth;
uniform int imageHeight;
uniform int frameCount;
uniform int u_lightCount;

layout(rgba32f, binding = 2) uniform image2D outImage;


uint seed;
uint pcg_hash() {
    uint state = seed;
    seed = seed * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float rand() { 
    return float(pcg_hash() >> 9u) * 0.00000011920929;
}

// AABB
bool IntersectAABB(vec3 orig, vec3 invDir, vec3 pMin, vec3 pMax, float t_min, float t_max) {
    vec3 t0 = (pMin - orig) * invDir;
    vec3 t1 = (pMax - orig) * invDir;
    
    // negative
    vec3 tmin_v = min(t0, t1);
    vec3 tmax_v = max(t0, t1);
    
    float tenter = max(max(tmin_v.x, tmin_v.y), tmin_v.z);
    float texit = min(min(tmax_v.x, tmax_v.y), tmax_v.z);
    
    // tenter <= texit pass through
    // texit >= t_min positive dir
    // tenter <= t_max front of intersect
    return tenter <= texit && texit >= t_min && tenter <= t_max;
}

bool intersectTriangle(vec3 orig, vec3 dir, vec3 v0, vec3 v1, vec3 v2, out float t, out float u, out float v) {
    vec3 e1 = v1 - v0;
    vec3 e2 = v2 - v0;
    vec3 pvec = cross(dir, e2);
    float det = dot(e1, pvec);
    
    // Paralell
    if (abs(det) < 1e-5) return false;
    
    float invDet = 1.0 / det;
    vec3 tvec = orig - v0;
    u = dot(tvec, pvec) * invDet;
    if (u < 0.0 || u > 1.0) return false;
    
    vec3 qvec = cross(tvec, e1);
    v = dot(dir, qvec) * invDet;
    if (v < 0.0 || u + v > 1.0) return false;
    
    t = dot(e2, qvec) * invDet;
    return (t > 0.001);
}


bool intersectScene(vec3 orig, vec3 dir, out float minT, out int hitIdx, out float u_out, out float v_out) {
    minT = 1e30;
    hitIdx = -1;
    u_out = 0.0;
    v_out = 0.0;

    vec3 invDir = 1.0 / dir;
    int stack[16];
    int ptr = 0;

    stack[ptr++] = 0;

    while (ptr > 0) {
        // pop stack
        int nodeIdx = stack[--ptr];
        BVHNode node = nodes[nodeIdx];
        

        if (!IntersectAABB(orig, invDir, node.pMin, node.pMax, 0.001, minT)) {
            continue;
        }
        

        if (node.nPrimitives > 0) {

            for (int i = 0; i < node.nPrimitives; i++) {
                int triIndex = node.primitiveIdx + i;
                float t, u, v;
                
                if (intersectTriangle(orig, dir, triangles[triIndex].v0, triangles[triIndex].v1, triangles[triIndex].v2, t, u, v)) {
                    if (t < minT) {
                        minT = t;
                        hitIdx = triIndex;
                        u_out = u;
                        v_out = v;
                    }
                }
            }
        } 
        else {
            if (node.leftChild != -1)  stack[ptr++] = node.leftChild;
            if (node.rightChild != -1) stack[ptr++] = node.rightChild;
        }
    }

/*
    for (int k = 0; k < triangles.length(); k++) {
        float t;
        if (intersectTriangle(orig, dir, triangles[k].v0, triangles[k].v1, triangles[k].v2, t)) {
            if (t < minT) {
                minT = t;
                hitIdx = k;
            }
        }
    }
*/
    return (hitIdx != -1);
}

vec3 sampleDiffuse(vec3 N) {
    float x1 = rand();
    float x2 = rand();
    
    float z = abs(1.0 - 2.0 * x1);
    float r = sqrt(max(0.0, 1.0 - z * z));
    float phi = 2.0 * 3.14159265 * x2;
    
    vec3 localRay = vec3(r * cos(phi), r * sin(phi), z);
    
    // toWorld  tangent space
    vec3 up = abs(N.z) < 0.999 ? vec3(0, 0, 1) : vec3(1, 0, 0);
    vec3 tangent = normalize(cross(up, N));
    vec3 bitangent = cross(N, tangent);
    
    return normalize(tangent * localRay.x + bitangent * localRay.y + N * localRay.z);
}

void sampleLight(out vec3 pos, out vec3 normal, out vec3 emit, out float pdf) {

    if (u_lightCount <= 0 || lightIndices[0] == -1) {
        pdf = 0.0; 
        return;
    }

    float total_emit_area = 0.0;

    // emissive triangles area
    for (int i = 0; i < u_lightCount; i++) {
        int idx = lightIndices[i];
        vec3 e1 = triangles[idx].v1 - triangles[idx].v0;
        vec3 e2 = triangles[idx].v2 - triangles[idx].v0;
        total_emit_area += length(cross(e1, e2)) * 0.5;
    }

    // sample by area portion
    float p = rand() * total_emit_area;
    float curr_area_sum = 0.0;
    int targetTriIdx = lightIndices[0];

    for (int i = 0; i < u_lightCount; i++) {
        int idx = lightIndices[i];
        vec3 e1 = triangles[idx].v1 - triangles[idx].v0;
        vec3 e2 = triangles[idx].v2 - triangles[idx].v0;
        curr_area_sum += length(cross(e1, e2)) * 0.5;
        if (p <= curr_area_sum) {
            targetTriIdx = idx;
            break;
        }
    }

    // objects[k]->Sample(pos, pdf)
    Triangle t = triangles[targetTriIdx];
    float r1 = sqrt(rand());
    float r2 = rand();
    pos = t.v0 * (1.0 - r1) + t.v1 * (r1 * (1.0 - r2)) + t.v2 * (r1 * r2);
    normal = normalize(t.normal);
    emit = t.emission;
    pdf = 1.0 / total_emit_area;
}

vec3 evalPhong(Triangle tri, vec3 viewDir, vec3 lightDir, vec3 N) {
    float cosAlpha = max(0.0, dot(N, lightDir));
    if (cosAlpha <= 0.0) return vec3(0.0);

    // 1. 漫反射部分 (Lambertian)
    vec3 diffuse = tri.color / 3.14159265;

    // 2. 镜面反射部分 (Phong)
    // viewDir 是从交点射向相机的方向
    // lightDir 是从交点射向光源的方向
    vec3 R = reflect(-lightDir, N); 
    float cosBeta = max(0.0, dot(R, viewDir));
    
    // 能量守恒系数：(ns + 2) / 2pi
    float normalization = (tri.specularExponent + 2.0) / (2.0 * 3.14159265);
    vec3 specular = tri.Ks * normalization * pow(cosBeta, tri.specularExponent);

    return (diffuse + specular);
}

vec3 Render(vec3 d) {
    vec3 L_out = vec3(0.0);
    vec3 throughput = vec3(1.0);
    vec3 currOrig = camPos;
    vec3 currDir = d;

    for (int bounce = 0; bounce < 20; bounce++) {
        float minT, u, v;
        int hitIdx;
        if (!intersectScene(currOrig, currDir, minT, hitIdx, u, v))
        {
            if (bounce == 0){
                // vec3 skyColor = vec3(0.1, 0.2, 0.8);
                // return skyColor;
                vec3 finalColor;

                // 定义地平线颜色（连接天空和地面的缝合线）
                vec3 horizonColor = vec3(0.6); // 浅灰色，制造“雾霭”感

                if (currDir.y > 0.0) {
                    // --- 天空部分 ---
                    // pow(..., 0.8) 是为了让蓝色集中在头顶，地平线保持较宽的亮色
                    float t = pow(currDir.y, 0.3); 
                    vec3 zenithColor = vec3(0.1, 0.2, 0.8); // 头顶深蓝
                    finalColor = mix(horizonColor, zenithColor, t);
                } 
                else {
                    // --- 地面部分（方案一对应逻辑）---
                    // 使用 abs() 因为向下射时 y 是负数
                    float t = pow(abs(currDir.y), 0.3); 
                    vec3 groundColor = vec3(0.1, 0.2, 0.2) * 0.5; // 脚底深黑（无限深渊感）
                    finalColor = mix(horizonColor, groundColor, t);
                }

                // 如果觉得背景太亮抢了主体风头，可以在这里整体乘一个系数
                return finalColor;
            }
            
            break;
        } 

        Triangle hitTri = triangles[hitIdx];
        vec3 hitPoint = currOrig + currDir * minT;

        //lerp normal
        vec3 N;
        if (hitTri.hasVPNormal > 0.5) { //
            float w = 1.0 - u - v;
            // 顶点法线插值公式
            N = normalize(hitTri.n0 * w + hitTri.n1 * u + hitTri.n2 * v);
        } else {
            N = normalize(hitTri.normal); // 回退到面法线
        }


        // vec3 N = normalize(hitTri.normal);
        if (dot(currDir, N) > 0.0) N = -N;

        // bounce to light source
        if (length(hitTri.emission) > 0.1) {
            if (bounce == 0) L_out += hitTri.emission;
            break;
        }

        // NEE
        vec3 l_pos, l_normal, l_emit;
        float pdf_light;
        sampleLight(l_pos, l_normal, l_emit, pdf_light);

        vec3 lightDir = normalize(l_pos - hitPoint);
        float lightDist = length(l_pos - hitPoint);
        float shadowT;
        int shadowIdx;
        
        // no block
        if (intersectScene(hitPoint + N * 0.001, lightDir, shadowT, shadowIdx, u, v)) {
            if (shadowIdx != -1 && abs(shadowT - lightDist) < 0.01) {
                /*
                vec3 f_r = hitTri.color / 3.14159265; 
                float cosTheta = max(0.0, dot(N, lightDir));
                float cosTheta1 = max(0.0, dot(l_normal, -lightDir));
                L_out += (l_emit * f_r * cosTheta * cosTheta1 / (lightDist * lightDist) / pdf_light) * throughput;
                */
                vec3 viewDir = -d;
                vec3 f_r = evalPhong(hitTri, viewDir, lightDir, N);
                float cosTheta = max(0.0, dot(N, lightDir));
                float cosTheta1 = max(0.0, dot(l_normal, -lightDir));
                L_out += min(vec3(20.0), (l_emit * f_r * cosTheta * cosTheta1 / (lightDist * lightDist) / pdf_light) * throughput);
            }
        }

        // Indirect and RR
        float RR = 0.8;
        if (rand() > RR) break;

        vec3 wi;
        float pdf;
        if (hitTri.specularExponent > 1000.0) {
            // 镜面反射：wi 就是完美的反射向量
            wi = reflect(currDir, N); 
            pdf = 1.0; // 镜面反射是确定性的，PDF 设为 1
        } else {
            // 漫反射：继续用你原来的随机采样
            wi = sampleDiffuse(N);
            pdf = 1.0 / (2.0 * 3.14159265); 
        }

        vec3 f_r = evalPhong(hitTri, -currDir, wi, N);
        float cosTheta = max(0.0, dot(wi, N)); 
        if (hitTri.specularExponent > 1000.0) 
        {
            throughput *= hitTri.Ks / RR;
        }
        else 
        {
            throughput *= (f_r * cosTheta) / pdf / RR;
        }

        currOrig = hitPoint + N * 0.001;
        currDir = wi;
        // vec3 wi = sampleDiffuse(N);
        // float pdf_hemi = 1.0 / (2.0 * 3.14159265); // hemisphere sample
        // float pdf_hemi = dot(wi, N) / 3.14159265;

        float nextT;
        int nextIdx;
        if (intersectScene(hitPoint + N * 0.001, wi, nextT, nextIdx, u, v)) {
            if (length(triangles[nextIdx].emission) < 0.1) {
                // vec3 f_r = hitTri.color / 3.14159265;
                
            } else {
                L_out += triangles[nextIdx].emission * throughput;
                break; // hit light
            }
        } else {
            // 射线弹跳后射向了天空
            // float t_sky = 0.5 * (wi.y + 1.0);
            // vec3 skyColor = mix(vec3(1.0), vec3(0.5, 0.7, 1.0), t_sky) * 0.5;
            float t_sky = max(0.0, wi.y); // 只取上半球 [cite: 191]
            // 使用 pow(t, 2.0) 让地平线处更亮，头顶蓝色更深邃
            vec3 skyColorTop = vec3(0.1, 0.2, 0.8); // 调深蓝色
            vec3 horizonColor = vec3(0.8);
            vec3 finalSky = mix(horizonColor, skyColorTop, pow(t_sky, 0.7)) * 0.4; 

            // 如果 wi.y < 0，说明射向了“地面以下”，给一个暗色，防止球底太白
            if (wi.y < 0.0) 
            {
                float groundT = pow(abs(wi.y), 0.6); // 0.6 次方是为了拉开层次

                // 从地平线的浅灰(0.3) 渐变到 脚底的深黑(0.02)
                vec3 horizonGray = vec3(0.3); 
                vec3 deepGround = vec3(0.02);

                finalSky = mix(horizonGray, deepGround, groundT);
            }

            // 这行会让球面上映照出漂亮的蓝天
            L_out += finalSky * throughput;
            break; // 路径结束
        }
    }
    return L_out;
}

void main()
{
    uint i = gl_GlobalInvocationID.x;
    uint j = gl_GlobalInvocationID.y;

    if (i >= imageWidth || j >= imageHeight)
        return;

    seed = uint(i * 1973 + j * 9277 + 1 * 26699) | 1u;

    uint idx = j * imageWidth + i;



    float minT = 1e30;      
    vec3 hitColor = vec3(0); // BG
    bool hitAnything = false;

    
    seed = uint(i * 1973 + j * 9277 + frameCount * 26699) | 1u;
    float aspect = float(imageWidth) / float(imageHeight);
    float scale = tan(radians(fov * 0.5));
    float x = (2.0 * (float(i) + 0.5) / float(imageWidth) - 1.0)
              * aspect * scale;
    float y = (1.0 - 2.0 * (float(j) + 0.5) / float(imageHeight))
              * scale;
    vec3 dir = normalize(vec3(-x, y, 1.0));
    vec3 currentSample = Render(dir);
    vec3 finalColor = pow(currentSample, vec3(1.0 / 2.2));
    if (frameCount == 0) {
        imageStore(outImage, ivec2(i, j), vec4(finalColor, 1.0));
    } else {
        vec4 lastColor = imageLoad(outImage, ivec2(i, j));
        // oldCOlor * (n/(n+1)) + NewColor * (1/(n+1))
        float weight = 1.0 / float(frameCount + 1);
        vec3 accumulated = mix(lastColor.rgb, finalColor, weight);
        imageStore(outImage, ivec2(i, j), vec4(accumulated, 1.0));
    }
    
}


