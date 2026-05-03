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
    vec3 color;  float materialType;
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
uniform float u_lightIntensity;  // global light intensity multiplier
uniform float u_ior;
uniform float u_russianRoulette;
uniform int   u_photonsPerPixel;
uniform int   u_maxPhotonBounces;
uniform int   u_maxRayBounces;
uniform int   u_toneMappingMode; // 0: gamma only, 1: ACES, 2: Reinhard
uniform float u_exposure;        // pre-tone-map exposure multiplier

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

const int MAT_DIFFUSE = 0;
const int MAT_WOOD    = 1;
const int MAT_METAL   = 2;
const int MAT_MIRROR  = 3;
const int BVH_STACK_SIZE = 64;

vec3 samplePhongLobe(vec3 axisDir, float shininess) {
    float r1 = rand();
    float r2 = rand();
    float phi = 2.0 * 3.14159265 * r1;
    float cosTheta = pow(max(1e-6, r2), 1.0 / (shininess + 1.0));
    float sinTheta = sqrt(max(0.0, 1.0 - cosTheta * cosTheta));

    vec3 w = normalize(axisDir);
    vec3 up = (abs(w.z) < 0.999) ? vec3(0, 0, 1) : vec3(1, 0, 0);
    vec3 u = normalize(cross(up, w));
    vec3 v = cross(w, u);

    return normalize(u * (cos(phi) * sinTheta) + v * (sin(phi) * sinTheta) + w * cosTheta);
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
    if (nodes.length() == 0 || triangles.length() == 0) {
        return false;
    }

    vec3 invDir = 1.0 / dir;
    int stack[BVH_STACK_SIZE];
    int ptr = 0;

    stack[ptr++] = 0;

    while (ptr > 0) {
        // pop stack
        int nodeIdx = stack[--ptr];
        if (nodeIdx < 0 || nodeIdx >= nodes.length()) {
            continue;
        }
        BVHNode node = nodes[nodeIdx];
        

        if (!IntersectAABB(orig, invDir, node.pMin, node.pMax, 0.001, minT)) {
            continue;
        }
        

        if (node.nPrimitives > 0) {

            for (int i = 0; i < node.nPrimitives; i++) {
                int triIndex = node.primitiveIdx + i;
                if (triIndex < 0 || triIndex >= triangles.length()) {
                    continue;
                }
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
            if (node.leftChild != -1 && ptr < BVH_STACK_SIZE) {
                stack[ptr++] = node.leftChild;
            }
            if (node.rightChild != -1 && ptr < BVH_STACK_SIZE) {
                stack[ptr++] = node.rightChild;
            }
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

void splatCaustic(ivec2 centerPix, vec3 energy)
{
    const int R = 2;
    const float sigma = 1.25;
    float weightSum = 0.0;

    for (int dy = -R; dy <= R; ++dy) {
        for (int dx = -R; dx <= R; ++dx) {
            float r2 = float(dx * dx + dy * dy);
            weightSum += exp(-r2 / (2.0 * sigma * sigma));
        }
    }

    for (int dy = -R; dy <= R; ++dy) {
        for (int dx = -R; dx <= R; ++dx) {
            ivec2 p = centerPix + ivec2(dx, dy);
            if (p.x < 0 || p.y < 0 || p.x >= imageWidth || p.y >= imageHeight) continue;

            float r2 = float(dx * dx + dy * dy);
            float w = exp(-r2 / (2.0 * sigma * sigma)) / max(weightSum, 1e-6);

            vec4 oldV = imageLoad(causticImage, p);
            imageStore(causticImage, p, vec4(oldV.rgb + energy * w, 1.0));
        }
    }
}

vec3 readFilteredCaustic(ivec2 pix)
{
    vec3 sum = vec3(0.0);
    float wsum = 0.0;

    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            ivec2 p = pix + ivec2(dx, dy);
            if (p.x < 0 || p.y < 0 || p.x >= imageWidth || p.y >= imageHeight) continue;

            float w = (dx == 0 && dy == 0) ? 4.0 : ((dx == 0 || dy == 0) ? 2.0 : 1.0);
            sum += imageLoad(causticImage, p).rgb * w;
            wsum += w;
        }
    }

    return sum / max(wsum, 1e-6);
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
        if (idx < 0 || idx >= triangles.length()) continue;
        vec3 e1 = triangles[idx].v1 - triangles[idx].v0;
        vec3 e2 = triangles[idx].v2 - triangles[idx].v0;
        total_emit_area += length(cross(e1, e2)) * 0.5;
    }
    if (total_emit_area <= 0.0) {
        pdf = 0.0;
        return;
    }

    // sample by area portion
    float p = rand() * total_emit_area;
    float curr_area_sum = 0.0;
    int targetTriIdx = lightIndices[0];

    for (int i = 0; i < u_lightCount; i++) {
        int idx = lightIndices[i];
        if (idx < 0 || idx >= triangles.length()) continue;
        vec3 e1 = triangles[idx].v1 - triangles[idx].v0;
        vec3 e2 = triangles[idx].v2 - triangles[idx].v0;
        curr_area_sum += length(cross(e1, e2)) * 0.5;
        if (p <= curr_area_sum) {
            targetTriIdx = idx;
            break;
        }
    }
    if (targetTriIdx < 0 || targetTriIdx >= triangles.length()) {
        pdf = 0.0;
        return;
    }

    // objects[k]->Sample(pos, pdf)
    Triangle t = triangles[targetTriIdx];
    float r1 = sqrt(rand());
    float r2 = rand();
    pos = t.v0 * (1.0 - r1) + t.v1 * (r1 * (1.0 - r2)) + t.v2 * (r1 * r2);
    normal = normalize(t.normal);
    emit = t.emission * u_lightIntensity;
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

    for (int p = 0; p < u_photonsPerPixel; ++p) {
        vec3 l_pos, l_normal, l_emit;
        float pdf_light;
        sampleLight(l_pos, l_normal, l_emit, pdf_light);
        if (pdf_light <= 0.0) continue;

        vec3 photonOrig = l_pos + l_normal * 1e-3;
        vec3 photonDir = sampleCosineHemisphere(l_normal);
        float photonCount = float(imageWidth * imageHeight * u_photonsPerPixel);
        vec3 flux = l_emit / max(pdf_light * photonCount, 1e-5);

        bool passedDielectric = false;
        vec3 causticTint = vec3(1.0);
        for (int bounce = 0; bounce < u_maxPhotonBounces; bounce++) {
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

                float ior = u_ior;
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
                    float perspectiveComp = clamp((refDepth * refDepth) / max(viewZ * viewZ, 1e-3), 0.5, 8.0);
                    splatCaustic(splatPix, flux * causticTint * perspectiveComp);
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

    for (int bounce = 0; bounce < u_maxRayBounces; bounce++) {
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

            L_out += finalColor * throughput;
            break;
        }

        Triangle hitTri = triangles[hitIdx];
        vec3 hitPoint = currOrig + currDir * minT;
        // vec3 hitColor = hitTri.color * 20;
        vec3 hitColor = hitTri.color;

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

            vec3 sigma = 1.0 - hitColor; 
            float density = 0.0;
            
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

        if (length(hitTri.emission) > 0.1) {
            L_out += hitTri.emission * u_lightIntensity * throughput;
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

        if (hitTri.texID < 0.5) {
            vec3 l_pos, l_normal, l_emit;
            float pdf_light;
            sampleLight(l_pos, l_normal, l_emit, pdf_light);

            vec3 lightDir = normalize(l_pos - hitPoint);
            float lightDist = length(l_pos - hitPoint);

            vec3 shadowWeight = vec3(1.0);
            vec3 shadowOrig = hitPoint + nl * 1e-3;
            float distLeft = lightDist;

            for (int s_bounce = 0; s_bounce < 4; s_bounce++) {
                float sT, sU, sV;
                int sIdx;
                if (intersectScene(shadowOrig, lightDir, sT, sIdx, sU, sV) && sT < (distLeft - 1e-3)) {
                    Triangle sTri = triangles[sIdx];
                    if (sTri.texID > 0.5) {
                        vec3 sigma = 1.0 - sTri.color; 
                        float shadowDensity = 0.01;

                        shadowWeight *= exp(-sigma * shadowDensity * sT);

                        shadowWeight *= 3; 
                        shadowWeight = vec3(0.0) + sTri.color * shadowWeight;

                        shadowOrig = shadowOrig + lightDir * (sT + 1e-3);
                        distLeft -= (sT + 1e-3);
                    } else {
                        shadowWeight = vec3(0.0);
                        break;
                    }
                } else {
                    break;
                }
            }

            if (length(shadowWeight) > 0.0) {
                vec3 f_r = evalBlinnPhong(hitTri, -d, lightDir, nl, hitUV);
                float cosTheta = max(0.0, dot(nl, lightDir));
                float cosTheta1 = max(0.0, dot(l_normal, -lightDir));
                L_out += (l_emit * f_r * cosTheta * cosTheta1 / (lightDist * lightDist) / pdf_light) * throughput * shadowWeight;
            }
        }

        // Indirect and RR
        float RR = u_russianRoulette;
        if (rand() > RR) break;

        vec3 wi;
        float pdf;
        int materialType = int(hitTri.materialType + 0.5);
        if (hitTri.texID > 0.5){
            float ior = u_ior;
            float kr = fresnel(currDir, nl, ior);

            if (rand() < kr) {
                wi = reflect(currDir, nl);
            } else {
                float eta = into ? (1.0 / ior) : ior;
                wi = refract(currDir, nl, eta);
                if (length(wi) < 0.01) wi = reflect(currDir, nl);
            }
            // throughput *= hitColor / RR;
            throughput *= 1.0 / RR;
        }
        else{
            if (materialType == MAT_METAL) {
                vec3 idealReflect = reflect(currDir, nl);
                float shininess = max(4.0, hitTri.specularExponent);
                wi = samplePhongLobe(idealReflect, shininess);
                if (dot(wi, nl) <= 0.0) wi = idealReflect;
                pdf = 1.0;

                vec3 baseTint = clamp(hitColor * 2.0, vec3(0.0), vec3(1.0));
                vec3 metallicF0 = mix(hitTri.Ks, baseTint, 0.5);
                throughput *= metallicF0 / RR;
            } else if (materialType == MAT_MIRROR || hitTri.specularExponent > 1000.0) {
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

// --- Tone mapping operators ---
vec3 toneMapACES(vec3 x) {
    // Narkowicz 2015 ACES approximation
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

vec3 toneMapReinhard(vec3 x) {
    return x / (x + vec3(1.0));
}

vec3 applyToneMapping(vec3 hdr) {
    hdr *= u_exposure;
    if (u_toneMappingMode == 1) return toneMapACES(hdr);
    if (u_toneMappingMode == 2) return toneMapReinhard(hdr);
    return clamp(hdr, 0.0, 1.0); // mode 0: linear clamp
}

float luma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

// Stable bloom: keep it strong but avoid aggressive feedback artifacts.
vec3 computeGlow(ivec2 centerPix) {
    const float glowThreshold = 0.65;
    const float glowIntensity = 0.95;
    const float glowTintMix = 0.55;
    const float nearRadius = 5.0;
    const float farRadius = 12.0;

    vec3 sumNear = vec3(0.0);
    float wsumNear = 0.0;
    for (int y = -5; y <= 5; ++y) {
        for (int x = -5; x <= 5; ++x) {
            ivec2 p = centerPix + ivec2(x, y);
            if (p.x < 0 || p.y < 0 || p.x >= imageWidth || p.y >= imageHeight) continue;

            float r2 = float(x * x + y * y);
            if (r2 > nearRadius * nearRadius) continue;
            float w = exp(-r2 * 0.11);
            vec4 src = imageLoad(outImage, p);
            vec3 c = src.rgb;
            float diamondMask = src.a;
            float softMask = smoothstep(0.10, 0.90, diamondMask);
            float b = max(luma(c) - glowThreshold, 0.0) * softMask;
            if (b > 0.0) {
                vec3 boosted = mix(vec3(b), c * b, glowTintMix);
                sumNear += boosted * w;
                wsumNear += w;
            }
        }
    }

    vec3 sumFar = vec3(0.0);
    float wsumFar = 0.0;
    for (int y = -12; y <= 12; ++y) {
        for (int x = -12; x <= 12; ++x) {
            ivec2 p = centerPix + ivec2(x, y);
            if (p.x < 0 || p.y < 0 || p.x >= imageWidth || p.y >= imageHeight) continue;

            float r2 = float(x * x + y * y);
            if (r2 > farRadius * farRadius) continue;
            float w = exp(-r2 * 0.025);
            vec4 src = imageLoad(outImage, p);
            vec3 c = src.rgb;
            float diamondMask = src.a;
            float softMask = smoothstep(0.10, 0.90, diamondMask);
            float b = max(luma(c) - (glowThreshold + 0.05), 0.0) * softMask;
            if (b > 0.0) {
                vec3 boosted = mix(vec3(b), c * b, 0.65);
                sumFar += boosted * w;
                wsumFar += w;
            }
        }
    }

    vec3 nearBloom = (wsumNear > 1e-6) ? (sumNear / wsumNear) : vec3(0.0);
    vec3 farBloom = (wsumFar > 1e-6) ? (sumFar / wsumFar) : vec3(0.0);

    // Add a controlled star streak (cross + diagonals).
    const ivec2 dirs[8] = ivec2[](
        ivec2(1, 0), ivec2(-1, 0), ivec2(0, 1), ivec2(0, -1),
        ivec2(1, 1), ivec2(-1, -1), ivec2(1, -1), ivec2(-1, 1)
    );
    vec3 streak = vec3(0.0);
    float sw = 0.0;
    for (int d = 0; d < 8; ++d) {
        for (int s = 1; s <= 8; ++s) {
            ivec2 p = centerPix + dirs[d] * s;
            if (p.x < 0 || p.y < 0 || p.x >= imageWidth || p.y >= imageHeight) break;
            float w = pow(1.0 - float(s) / 8.0, 2.0);
            vec4 src = imageLoad(outImage, p);
            vec3 c = src.rgb;
            float diamondMask = src.a;
            float softMask = smoothstep(0.10, 0.90, diamondMask);
            float b = max(luma(c) - (glowThreshold + 0.08), 0.0) * softMask;
            if (b > 0.0) {
                streak += c * b * w;
                sw += w;
            }
        }
    }
    if (sw > 1e-6) streak /= sw;

    vec3 glow = nearBloom * 0.9 + farBloom * 1.05 + streak * 0.95;
    glow *= glowIntensity;
    glow *= vec3(0.90, 0.97, 1.12);
    return min(glow, vec3(1.4));
}

float primaryDiamondMask(vec3 dir) {
    float t, u, v;
    int hitIdx;
    if (!intersectScene(camPos, dir, t, hitIdx, u, v)) return 0.0;
    Triangle hitTri = triangles[hitIdx];
    return (hitTri.texID > 0.5) ? 1.0 : 0.0;
}

vec3 primaryRayDir(float px, float py) {
    float aspect = float(imageWidth) / float(imageHeight);
    float scale = tan(radians(fov * 0.5));
    float x = (2.0 * px / float(imageWidth) - 1.0) * aspect * scale;
    float y = (1.0 - 2.0 * py / float(imageHeight)) * scale;
    return normalize(-x * camRight + y * camUp + camForward);
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
    float diamondMask = 0.0;

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
            diamondMask += primaryDiamondMask(dir);
        }
        currentSample /= 4;
        diamondMask /= 4.0;
    }
    else{
        float x = (2.0 * (float(i) + rand()) / float(imageWidth) - 1.0)
                * aspect * scale;
        float y = (1.0 - 2.0 * (float(j) + rand()) / float(imageHeight))
                  * scale;
        vec3 dir = normalize(-x * camRight + y * camUp + camForward);
        currentSample = Render(dir);
        // Use deterministic center ray for mask to avoid frame-to-frame dotted artifacts.
        vec3 stableMaskDir = primaryRayDir(float(i) + 0.5, float(j) + 0.5);
        diamondMask = primaryDiamondMask(stableMaskDir);
    }

    vec3 causticAvg = readFilteredCaustic(ivec2(i, j)) / max(float(frameCount + 1), 1.0);
    // Lift caustic mid/low values so patterns are easier to see
    vec3 causticBoosted = pow(max(causticAvg, vec3(0.0)), vec3(0.75));
    // Reduce saturation while preserving brightness contrast
    float causticLuma = dot(causticBoosted, vec3(0.2126, 0.7152, 0.0722));
    vec3 causticDesat = mix(vec3(causticLuma), causticBoosted, 0.55);
    currentSample += causticDesat * u_causticStrength;

    vec3 mapped = applyToneMapping(currentSample);
    vec3 finalColor = pow(mapped, vec3(1.0 / 2.2));
    if (frameCount > 0) {
        finalColor += computeGlow(ivec2(i, j));
        finalColor = clamp(finalColor, 0.0, 1.0);
    }
    if (frameCount == 0) {
        imageStore(outImage, ivec2(i, j), vec4(finalColor, diamondMask));
    } else {
        vec4 lastColor = imageLoad(outImage, ivec2(i, j));
        // oldCOlor * (n/(n+1)) + NewColor * (1/(n+1))
        float weight = 1.0 / float(frameCount + 1);
        vec3 accumulated = mix(lastColor.rgb, finalColor, weight);
        float accumulatedMask = mix(lastColor.a, diamondMask, 0.15);
        imageStore(outImage, ivec2(i, j), vec4(accumulated, accumulatedMask));
    }
    
}


