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
    vec3 v0;
    vec3 v1;
    vec3 v2;
    vec3 normal;
    vec3 emission;
    vec3 color;
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

bool intersectTriangle(vec3 orig, vec3 dir, vec3 v0, vec3 v1, vec3 v2, out float t) {
    vec3 e1 = v1 - v0;
    vec3 e2 = v2 - v0;
    vec3 pvec = cross(dir, e2);
    float det = dot(e1, pvec);
    
    // Paralell
    if (abs(det) < 1e-5) return false;
    
    float invDet = 1.0 / det;
    vec3 tvec = orig - v0;
    float u = dot(tvec, pvec) * invDet;
    if (u < 0.0 || u > 1.0) return false;
    
    vec3 qvec = cross(tvec, e1);
    float v = dot(dir, qvec) * invDet;
    if (v < 0.0 || u + v > 1.0) return false;
    
    t = dot(e2, qvec) * invDet;
    return (t > 0.001);
}


bool intersectScene(vec3 orig, vec3 dir, out float minT, out int hitIdx) {
    minT = 1e30;
    hitIdx = -1;


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
                float t;
                
                if (intersectTriangle(orig, dir, triangles[triIndex].v0, triangles[triIndex].v1, triangles[triIndex].v2, t)) {
                    if (t < minT) {
                        minT = t;
                        hitIdx = triIndex;
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

vec3 Render(vec3 d) {
    vec3 L_out = vec3(0.0);
    vec3 throughput = vec3(1.0);
    vec3 currOrig = camPos;
    vec3 currDir = d;

    for (int bounce = 0; bounce < 4; bounce++) {
        float minT;
        int hitIdx;
        if (!intersectScene(currOrig, currDir, minT, hitIdx)) break;

        Triangle hitTri = triangles[hitIdx];
        vec3 hitPoint = currOrig + currDir * minT;
        vec3 N = normalize(hitTri.normal);
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
        if (intersectScene(hitPoint + N * 0.001, lightDir, shadowT, shadowIdx)) {
            if (shadowIdx != -1 && abs(shadowT - lightDist) < 0.01) {
                vec3 f_r = hitTri.color / 3.14159265; 
                float cosTheta = max(0.0, dot(N, lightDir));
                float cosTheta1 = max(0.0, dot(l_normal, -lightDir));
                L_out += (l_emit * f_r * cosTheta * cosTheta1 / (lightDist * lightDist) / pdf_light) * throughput;
            }
        }

        // Indirect and RR
        float RR = 0.8;
        if (rand() > RR) break;

        vec3 wi = sampleDiffuse(N);
        float pdf_hemi = 1.0 / (2.0 * 3.14159265); // hemisphere sample

        float nextT;
        int nextIdx;
        if (intersectScene(hitPoint + N * 0.001, wi, nextT, nextIdx)) {
            if (length(triangles[nextIdx].emission) < 0.1) {
                vec3 f_r = hitTri.color / 3.14159265;
                float cosTheta = max(0.0, dot(wi, N));
                
                throughput *= (f_r * cosTheta) / pdf_hemi / RR;
                
                currOrig = hitPoint + N * 0.001;
                currDir = wi;
            } else {
                break; // hit light
            }
        } else {
            break;
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
    if (frameCount == 0) {
        imageStore(outImage, ivec2(i, j), vec4(currentSample, 1.0));
    } else {
        vec4 lastColor = imageLoad(outImage, ivec2(i, j));
        // oldCOlor * (n/(n+1)) + NewColor * (1/(n+1))
        float weight = 1.0 / float(frameCount + 1);
        vec3 accumulated = mix(lastColor.rgb, currentSample, weight);
        imageStore(outImage, ivec2(i, j), vec4(accumulated, 1.0));
    }
    
}


