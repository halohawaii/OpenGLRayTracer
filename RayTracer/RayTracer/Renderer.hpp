//
// Created by goksu on 2/25/20.
//
#include "Scene.hpp"

#pragma once
struct hit_payload
{
    float tNear;
    uint32_t index;
    Vector2f uv;
    Object* hit_obj;
};

class Renderer
{
public:
    void Render(const Scene& scene);

private:
};

struct RayGPU
{
    float ox, oy, oz, _pad0;
    float dx, dy, dz, _pad1;
};
static_assert(sizeof(RayGPU) == 32);

struct CameraGPU
{
    float pos[3];
    float fov;
    float forward[3];
    float _pad0;
    float right[3];
    float _pad1;
    float up[3];
    float _pad2;
};