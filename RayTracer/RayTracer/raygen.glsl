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
    float SuperSample;
    vec3 camRight;
    float _pad1;
    vec3 camUp;
};

struct Triangle {
    vec3 v0; float uv0U;
    vec3 v1; float uv0V;
    vec3 v2; float uv1U;
    vec3 n0; float uv1V;
    vec3 n1; float uv2U;
    vec3 n2; float uv2V;
    vec3 normal;
    float hasVPNormal;
    vec3 emission; float texID;
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

layout(binding = 6) uniform sampler2D u_Texture;

uniform int imageWidth;
uniform int imageHeight;
uniform int frameCount;
uniform int u_lightCount;
uniform int u_passMode;          // 0: render pass, 1: photon pass
uniform float u_causticStrength; // caustic map intensity scale

layout(rgba32f, binding = 2) uniform image2D outImage;
layout(rgba32f, binding = 7) uniform image2D causticImage;


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

vec3 sampleCosineHemisphere(vec3 N) {
    float r1 = rand();
    float r2 = rand();
    float phi = 2.0 * 3.14159265 * r1;
    float r = sqrt(r2);
    float x = r * cos(phi);
    float y = r * sin(phi);
    float z = sqrt(max(0.0, 1.0 - r2));

    vec3 up = abs(N.z) < 0.999 ? vec3(0, 0, 1) : vec3(1, 0, 0);
    vec3 tangent = normalize(cross(up, N));
    vec3 bitangent = cross(N, tangent);
    return normalize(tangent * x + bitangent * y + N * z);
}

bool worldToPixel(vec3 P, out ivec2 pix, out float viewZ) {
    vec3 rel = P - camPos;
    float z = dot(rel, camForward);
    viewZ = z;
    if (z <= 1e-4) return false;

    float aspect = float(imageWidth) / float(imageHeight);
    float scale = tan(radians(fov * 0.5));
    float x = -dot(rel, camRight) / (z * aspect * scale);
    float y =  dot(rel, camUp)    / (z * scale);

    if (abs(x) > 1.0 || abs(y) > 1.0) return false;
    int px = int((x * 0.5 + 0.5) * float(imageWidth));
    int py = int((0.5 - y * 0.5) * float(imageHeight));
    if (px < 0 || py < 0 || px >= imageWidth || py >= imageHeight) return false;
    pix = ivec2(px, py);
    return true;
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

vec3 evalBlinnPhong(Triangle tri, vec3 viewDir, vec3 lightDir, vec3 N, vec2 UV) {
    float cosAlpha = max(0.0, dot(N, lightDir));
    if (cosAlpha <= 0.0) return vec3(0.0);

    vec3 diffuse;
    if (tri.texID < 0){ // no texture
        diffuse = tri.color / 3.14159265;
    }
    else {
        // float w = 1.0 - u - v;
        // vec2 uv0 = vec2(tri.uv0U, tri.uv0V);
        // vec2 uv1 = vec2(tri.uv1U, tri.uv1V);
        // vec2 uv2 = vec2(tri.uv2U, tri.uv2V);
        // vec2 hitUV = vec2(w * uv0 + u * uv1 + v * uv2);
        // diffuse = vec3(hitUV.r, hitUV.g, 0.0);
        diffuse = texture(u_Texture, UV).rgb / 3.14159265;
    }
    

    vec3 H = normalize(viewDir + lightDir); 
    float cosN = max(0.0, dot(N, H));
    
    float normalization = (tri.specularExponent + 8.0) / (8.0 * 3.14159265);
    vec3 specular = tri.Ks * normalization * pow(cosN, tri.specularExponent);

    return (diffuse + specular);
}

float fresnel(vec3 I, vec3 N, float ior) {
    float cosi = clamp(dot(I, N), -1.0, 1.0);
    float etai = 1.0, etat = ior;
    if (cosi > 0.0) { float temp = etai; etai = etat; etat = temp; }
    
    float sint = etai / etat * sqrt(max(0.0, 1.0 - cosi * cosi));
    if (sint >= 1.0) return 1.0;

    float r0 = (etai - etat) / (etai + etat);
    r0 = r0 * r0;
    return r0 + (1.0 - r0) * pow(1.0 - abs(cosi), 5.0);
}

void photonPass(ivec2 launchPix) {
    if (frameCount == 0) {
        imageStore(causticImage, launchPix, vec4(0.0));
    }

    const int PHOTONS_PER_PIXEL = 4;
    for (int p = 0; p < PHOTONS_PER_PIXEL; ++p) {
        vec3 l_pos, l_normal, l_emit;
        float pdf_light;
        sampleLight(l_pos, l_normal, l_emit, pdf_light);
        if (pdf_light <= 0.0) continue;

        vec3 photonOrig = l_pos + l_normal * 1e-3;
        vec3 photonDir = sampleCosineHemisphere(l_normal);
        float photonCount = float(imageWidth * imageHeight * PHOTONS_PER_PIXEL);
        vec3 flux = l_emit / max(pdf_light * photonCount, 1e-5);

        bool passedDielectric = false;
        vec3 causticTint = vec3(1.0);
        for (int bounce = 0; bounce < 12; bounce++) {
            float t, u, v;
            int hitIdx;
            if (!intersectScene(photonOrig, photonDir, t, hitIdx, u, v)) break;

            Triangle hitTri = triangles[hitIdx];
            vec3 hitPoint = photonOrig + photonDir * t;
            vec3 N = normalize(hitTri.normal);
            if (dot(photonDir, N) > 0.0) N = -N;

            if (length(hitTri.emission) > 0.1) break;

            if (hitTri.texID > 0.5) {
                passedDielectric = true;
                causticTint *= clamp(hitTri.color, vec3(0.0), vec3(1.0));
                vec3 sigma = max(vec3(0.0), 1.0 - clamp(hitTri.color, vec3(0.0), vec3(1.0)));
                float tintDensity = 0.01;
                causticTint *= exp(-sigma * tintDensity * t);

                float ior = 2.417;
                float kr = fresnel(photonDir, N, ior);
                if (rand() < kr) {
                    photonDir = reflect(photonDir, N);
                } else {
                    float eta = (dot(photonDir, N) < 0.0) ? (1.0 / ior) : ior;
                    vec3 wt = refract(photonDir, N, eta);
                    photonDir = (length(wt) < 0.01) ? reflect(photonDir, N) : wt;
                }
                photonOrig = hitPoint + photonDir * 1e-3;
                continue;
            }

            if (passedDielectric) {
                ivec2 splatPix;
                float viewZ;
                if (worldToPixel(hitPoint, splatPix, viewZ)) {
                    float refDepth = 800.0;
                    float perspectiveComp = clamp((refDepth * refDepth) / max(viewZ * viewZ, 1e-3), 0.25, 64.0);
                    vec4 oldV = imageLoad(causticImage, splatPix);
                    imageStore(causticImage, splatPix, vec4(oldV.rgb + flux * causticTint * perspectiveComp, 1.0));
                }
            }
            break;
        }
    }
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
            vec3 finalColor;
            vec3 horizonColor = vec3(0.6); 

            if (currDir.y > 0.0) {
                float t = pow(currDir.y, 0.3); 
                vec3 zenithColor = vec3(0.1, 0.2, 0.8);
                finalColor = mix(horizonColor, zenithColor, t);
            } 
            else {
                float t = pow(abs(currDir.y), 0.3); 
                vec3 groundColor = vec3(0.1, 0.2, 0.2) * 0.5;
                finalColor = mix(horizonColor, groundColor, t);
            }

            // --- 核心修改 ---
            // 无论 bounce 是多少，都要把天空色乘上当前的能量权重(throughput)并加到输出里
            L_out += finalColor * throughput;
            break; // 这条路径结束了，退出 for 循环
        }

        Triangle hitTri = triangles[hitIdx];
        vec3 hitPoint = currOrig + currDir * minT;
        vec3 hitColor = hitTri.color * 20;

        //lerp normal
        vec3 N;
        if (hitTri.hasVPNormal > 0.5) { //
            float w = 1.0 - u - v;
            N = normalize(hitTri.n0 * w + hitTri.n1 * u + hitTri.n2 * v);
        } else {
            N = normalize(hitTri.normal);
        }

        // vec3 N = normalize(hitTri.normal);
        // if (dot(currDir, N) > 0.0) N = -N;
        bool into = dot(currDir, N) < 0.0;
        vec3 nl = into ? N : -N;

        if (!into && hitTri.texID > 0.5) {

            // 计算吸收系数。你可以直接用 1.0 - hitTri.color 来定义吸收率
            // 颜色越深，sigma 越大
            vec3 sigma = 1.0 - hitColor; 
            float density = 0.1; // 控制玻璃颜色的浓度
            
            // 比尔定律公式
            throughput.r *= exp(-sigma.r * density * minT);
            throughput.g *= exp(-sigma.g * density * minT);
            throughput.b *= exp(-sigma.b * density * minT);

        }

        

        vec2 UV;
        float w = 1.0 - u - v;
        vec2 uv0 = vec2(hitTri.uv0U, hitTri.uv0V);
        vec2 uv1 = vec2(hitTri.uv1U, hitTri.uv1V);
        vec2 uv2 = vec2(hitTri.uv2U, hitTri.uv2V);
        vec2 hitUV = vec2(w * uv0 + u * uv1 + v * uv2);

        // 击中光源：任意 bounce 都要累加 emission * throughput（路径贡献）
        if (length(hitTri.emission) > 0.1) {
            L_out += hitTri.emission * throughput;
            break;
        }

        /*
        // NEE
        if (hitTri.texID < 0.5){
            vec3 l_pos, l_normal, l_emit;
            float pdf_light;
            sampleLight(l_pos, l_normal, l_emit, pdf_light);
    
            vec3 lightDir = normalize(l_pos - hitPoint);
            float lightDist = length(l_pos - hitPoint);
            float shadowT;
            int shadowIdx;
            
            // no block
            if (intersectScene(hitPoint + nl * 0.001, lightDir, shadowT, shadowIdx, u, v)) {
                if (shadowIdx != -1 && abs(shadowT - lightDist) < 0.01 && u_lightCount > 0 && pdf_light > 0.0) {
                    
                    vec3 viewDir = -d;
                    vec3 f_r = evalBlinnPhong(hitTri, viewDir, lightDir, nl, hitUV);
                    float cosTheta = max(0.0, dot(nl, lightDir));
                    float cosTheta1 = max(0.0, dot(l_normal, -lightDir));
                    // L_out += min(vec3(200.0), (l_emit * f_r * cosTheta * cosTheta1 / (lightDist * lightDist) / pdf_light) * throughput);
                    L_out += (l_emit * f_r * cosTheta * cosTheta1 / (lightDist * lightDist) / pdf_light) * throughput;
    
                }
            }
        }
        */

        // --- 修改后的 NEE 部分 ---
        if (hitTri.texID < 0.5) { // 仅非透明物体（如地面）接收直接光阴影
            vec3 l_pos, l_normal, l_emit;
            float pdf_light;
            sampleLight(l_pos, l_normal, l_emit, pdf_light);

            vec3 lightDir = normalize(l_pos - hitPoint);
            float lightDist = length(l_pos - hitPoint);

            vec3 shadowWeight = vec3(1.0); // 初始光强
            vec3 shadowOrig = hitPoint + nl * 1e-3; // 使用定向法线 nl 偏移
            float distLeft = lightDist;

            // 穿透循环：允许光线穿过钻石的前后脸
            for (int s_bounce = 0; s_bounce < 4; s_bounce++) {
                float sT, sU, sV;
                int sIdx;
                if (intersectScene(shadowOrig, lightDir, sT, sIdx, sU, sV) && sT < (distLeft - 1e-3)) {
                    Triangle sTri = triangles[sIdx];
                    if (sTri.texID > 0.5) {
                        // --- 比尔定律模拟 ---
                        // 钻石很亮，吸收系数 sigma 较小。1.0 - color 得到吸收率
                        vec3 sigma = 1.0 - sTri.color; 
                        float shadowDensity = 0.01; // 钻石建议设低一点，保持晶莹感

                        // 这里的 sT 是光线在透明物体内部（或到下一个交点）的距离
                        shadowWeight *= exp(-sigma * shadowDensity * sT);

                        // 伪造汇聚效果：如果是钻石，稍微补偿一点亮度
                        shadowWeight *= 3; 
                        shadowWeight = vec3(0.0) + sTri.color * shadowWeight;

                        // 推进射线起点，继续探测
                        shadowOrig = shadowOrig + lightDir * (sT + 1e-3);
                        distLeft -= (sT + 1e-3);
                    } else {
                        // 撞击到不透明物体，阴影彻底变黑
                        shadowWeight = vec3(0.0);
                        break;
                    }
                } else {
                    break; // 到达光源
                }
            }

            if (length(shadowWeight) > 0.0) {
                vec3 f_r = evalBlinnPhong(hitTri, -d, lightDir, nl, hitUV);
                float cosTheta = max(0.0, dot(nl, lightDir));
                float cosTheta1 = max(0.0, dot(l_normal, -lightDir));
                // 应用带颜色的 shadowWeight
                L_out += (l_emit * f_r * cosTheta * cosTheta1 / (lightDist * lightDist) / pdf_light) * throughput * shadowWeight;
            }
        }

        // Indirect and RR
        float RR = 0.8;
        if (rand() > RR) break;

        vec3 wi;
        float pdf;
        if (hitTri.texID > 0.5){
            float ior = 2.417; 
            float kr = fresnel(currDir, nl, ior);

            if (rand() < kr) {
                wi = reflect(currDir, nl);
            } else {
                float eta = into ? (1.0 / ior) : ior;
                wi = refract(currDir, nl, eta);
                // 处理全反射
                if (length(wi) < 0.01) wi = reflect(currDir, nl);
            }
            // throughput *= hitColor / RR;
            throughput *= 1.0 / RR;
        }
        else{
            if (hitTri.specularExponent > 1000.0) {
                wi = reflect(currDir, nl); 
                pdf = 1.0;
                throughput *= hitTri.Ks / RR;
            } else {
                wi = sampleDiffuse(nl);
                pdf = 1.0 / (2.0 * 3.14159265); 

                vec3 f_r = evalBlinnPhong(hitTri, -currDir, wi, nl, hitUV);
                float cosTheta = max(0.0, dot(wi, nl));
                throughput *= (f_r * cosTheta) / pdf / RR;
            }
        }

        currOrig = hitPoint + wi * 0.001;
        currDir = wi;
        
    }
    return L_out;
}

void main()
{
    uint i = gl_GlobalInvocationID.x;
    uint j = gl_GlobalInvocationID.y;

    if (i >= imageWidth || j >= imageHeight)
        return;

    if (u_passMode == 1) {
        seed = uint(i * 9119 + j * 31337 + frameCount * 6971 + 17) | 1u;
        photonPass(ivec2(int(i), int(j)));
        return;
    }

    seed = uint(i * 1973 + j * 9277 + 1 * 26699) | 1u;

    uint idx = j * imageWidth + i;



    float minT = 1e30;      
    // vec3 hitColor = vec3(0); // BG
    bool hitAnything = false;

    
    seed = uint(i * 1973 + j * 9277 + frameCount * 26699) | 1u;
    float aspect = float(imageWidth) / float(imageHeight);
    float scale = tan(radians(fov * 0.5));

    vec3 currentSample = vec3(0);

    if (SuperSample > 0.5)
    {
        for (int k = 0; k < 4; k++){
            float x = (2.0 * (float(i) + mod(k, 2) / 2 + 0.25) / float(imageWidth) - 1.0)
                      * aspect * scale;
            float y = (1.0 - 2.0 * (float(j) + (k / 2) / 2.0 + 0.25) / float(imageHeight))
                      * scale;
            // vec3 dir = normalize(vec3(-x, y, 1.0));
            vec3 dir = normalize(-x * camRight + y * camUp + camForward);
            currentSample += Render(dir);
        }
        currentSample /= 4;
    }
    else{
        float x = (2.0 * (float(i) + rand()) / float(imageWidth) - 1.0)
                * aspect * scale;
        float y = (1.0 - 2.0 * (float(j) + rand()) / float(imageHeight))
                  * scale;
        vec3 dir = normalize(-x * camRight + y * camUp + camForward);
        currentSample = Render(dir);
    }

    vec3 causticAvg = imageLoad(causticImage, ivec2(i, j)).rgb / max(float(frameCount + 1), 1.0);
    // Lift caustic mid/low values so patterns are easier to see
    vec3 causticBoosted = pow(max(causticAvg, vec3(0.0)), vec3(0.75));
    // Reduce saturation while preserving brightness contrast
    float causticLuma = dot(causticBoosted, vec3(0.2126, 0.7152, 0.0722));
    vec3 causticDesat = mix(vec3(causticLuma), causticBoosted, 0.55);
    currentSample += causticDesat * u_causticStrength;

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


