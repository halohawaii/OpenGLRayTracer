#pragma once
#include <iostream>
#include <cmath>
#include <random>

#undef M_PI
#define M_PI 3.141592653589793f

extern const float  EPSILON;
const float kInfinity = std::numeric_limits<float>::max();

inline float clamp(const float &lo, const float &hi, const float &v)
{ return std::max(lo, std::min(hi, v)); }

inline  bool solveQuadratic(const float &a, const float &b, const float &c, float &x0, float &x1)
{
    float discr = b * b - 4 * a * c;
    if (discr < 0) return false;
    else if (discr == 0) x0 = x1 = - 0.5 * b / a;
    else {
        float q = (b > 0) ?
                  -0.5 * (b + sqrt(discr)) :
                  -0.5 * (b - sqrt(discr));
        x0 = q / a;
        x1 = c / q;
    }
    if (x0 > x1) std::swap(x0, x1);
    return true;
}

inline float get_random_float()
{
    static std::random_device dev;
    static std::mt19937 rng(dev());
    static std::uniform_real_distribution<float> dist(0.f, 1.f); // distribution in range [0，1]

    return dist(rng);
}

inline void UpdateProgress(float progress)
{
    int barWidth = 70;

    std::cout << "[";
    int pos = barWidth * progress;
    for (int i = 0; i < barWidth; ++i) {
        if (i < pos) std::cout << "=";
        else if (i == pos) std::cout << ">";
        else std::cout << " ";
    }
    std::cout << "] " << int(progress * 100.0) << " %\r";
    std::cout.flush();
};


struct TriangleGPU {
    float v0[3], pad0;
    float v1[3], pad1;
    float v2[3], pad2;
    float n0[3], pad3;
    float n1[3], pad4;
    float n2[3], pad5;
    float normal[3], hasVPNormal;   // 新增：面法线
    float emission[3], pad6; // 新增：自发光（光源识别）
    float color[3], pad7;    // 物体颜色

    float Ks[3], specularExponent;
};

struct BVHNodeGPU {
    float pMin[3];
    int leftChild;      // 如果 >= 0，是左子节点的数组下标；如果 < 0，代表是叶子
    float pMax[3];
    int rightChild;     // 如果 >= 0，是右子节点的数组下标；
    int nPrimitives;    // 该节点包含的三角形数量（0表示中间节点）
    int primitiveIdx;   // 如果是叶子，存储该三角形在 triList 中的索引
    float area;         // 用于重要性采样
    int _pad;           // 对齐填充
    float _final_pads[4]; // (Block 4)
};