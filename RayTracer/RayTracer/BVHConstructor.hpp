#pragma once
#include <vector>
#include <algorithm>
#include <cmath>
#include "BVH.hpp"

struct NewBVHBuildNode {
    Bounds3 bounds;
    NewBVHBuildNode* left;
    NewBVHBuildNode* right;
    int splitAxis;
    int firstPrimOffset; 
    int nPrimitives;     

    NewBVHBuildNode() : left(nullptr), right(nullptr), splitAxis(0), firstPrimOffset(0), nPrimitives(0) {}
};


class BVHConstructor {
public:
    std::vector<BVHNodeGPU> bvhNodes;
    std::vector<TriangleGPU> orderedTriList;

public:
    // --- 核心入口函数 ---
    // 传入原始的乱序三角形列表，自动完成所有工作
    void build(const std::vector<TriangleGPU>& rawTriangles) {
        if (rawTriangles.empty()) return;

        // 1. 清空旧数据
        bvhNodes.clear();
        orderedTriList.clear();

        // 2. 初始化索引数组 (0, 1, 2, ...)
        // 我们移动的是这个 int 数组，而不是庞大的 TriangleGPU 对象
        std::vector<int> primitiveIndices(rawTriangles.size());
        for (int i = 0; i < primitiveIndices.size(); ++i) {
            primitiveIndices[i] = i;
        }

        // 3. 递归构建指针树
        NewBVHBuildNode* root = recursiveBuild(primitiveIndices, 0, (int)primitiveIndices.size(), rawTriangles);

        // 4. 扁平化：将指针树转为数组，并重组三角形顺序
        flattenBVH(root, rawTriangles, primitiveIndices);

        // 5. 清理临时内存
        deleteBuildTree(root);
    }

private:
    // --- 辅助函数：获取 TriangleGPU 的包围盒 ---
    Bounds3 getTriBounds(const TriangleGPU& tri) {
        Vector3f v0(tri.v0[0], tri.v0[1], tri.v0[2]);
        Vector3f v1(tri.v1[0], tri.v1[1], tri.v1[2]);
        Vector3f v2(tri.v2[0], tri.v2[1], tri.v2[2]);
        return Union(Bounds3(v0, v1), v2);
    }

    // --- 辅助函数：获取 TriangleGPU 的重心 ---
    Vector3f getTriCentroid(const TriangleGPU& tri) {
        return Vector3f(
            (tri.v0[0] + tri.v1[0] + tri.v2[0]) / 3.0f,
            (tri.v0[1] + tri.v1[1] + tri.v2[1]) / 3.0f,
            (tri.v0[2] + tri.v1[2] + tri.v2[2]) / 3.0f
        );
    }

    // --- 递归构建逻辑 (中点划分法) ---
    NewBVHBuildNode* recursiveBuild(std::vector<int>& indices, int start, int end,
        const std::vector<TriangleGPU>& rawTriangles)
    {
        NewBVHBuildNode* node = new NewBVHBuildNode();

        // 1. 计算当前节点所有三角形的总包围盒
        Bounds3 bounds;
        for (int i = start; i < end; ++i) {
            bounds = Union(bounds, getTriBounds(rawTriangles[indices[i]]));
        }
        node->bounds = bounds;

        int nPrimitives = end - start;

        // 2. 递归终止条件：如果是叶子节点 (这里设为 1 个三角形)
        if (nPrimitives == 1) {
            node->firstPrimOffset = start; // 记录在 indices 数组中的位置
            node->nPrimitives = nPrimitives;
            return node;
        }

        // 3. 计算重心包围盒，选择最长的轴进行划分
        Bounds3 centroidBounds;
        for (int i = start; i < end; ++i) {
            centroidBounds = Union(centroidBounds, getTriCentroid(rawTriangles[indices[i]]));
        }
        int dim = centroidBounds.maxExtent(); // 0=x, 1=y, 2=z

        // 4. 根据重心在选定轴上的位置进行排序 (关键步骤)
        int mid = (start + end) / 2;
        std::nth_element(indices.begin() + start,
            indices.begin() + mid,
            indices.begin() + end,
            [&](int a, int b) {
                Vector3f ca = getTriCentroid(rawTriangles[a]);
                Vector3f cb = getTriCentroid(rawTriangles[b]);
                if (dim == 0) return ca.x < cb.x;
                if (dim == 1) return ca.y < cb.y;
                return ca.z < cb.z;
            });

        // 5. 递归构建左右子树
        node->left = recursiveBuild(indices, start, mid, rawTriangles);
        node->right = recursiveBuild(indices, mid, end, rawTriangles);

        return node;
    }

    // --- 扁平化逻辑 ---
    // 深度优先遍历树，生成 bvhNodes 数组，并按叶子访问顺序填充 orderedTriList
    int flattenBVH(NewBVHBuildNode* node, const std::vector<TriangleGPU>& rawTriangles,
        const std::vector<int>& sortedIndices)
    {
        if (!node) return -1;

        // 在扁平数组中为当前节点占位
        int currIdx = (int)bvhNodes.size();
        bvhNodes.emplace_back();

        BVHNodeGPU gpuNode;
        // 填充包围盒
        gpuNode.pMin[0] = node->bounds.pMin.x; gpuNode.pMin[1] = node->bounds.pMin.y; gpuNode.pMin[2] = node->bounds.pMin.z;
        gpuNode.pMax[0] = node->bounds.pMax.x; gpuNode.pMax[1] = node->bounds.pMax.y; gpuNode.pMax[2] = node->bounds.pMax.z;

        if (node->nPrimitives > 0) {
            // --- 叶子节点 ---
            gpuNode.leftChild = -1;
            gpuNode.rightChild = -1;
            gpuNode.nPrimitives = node->nPrimitives;

            // 【关键点】：primitiveIdx 指向 orderedTriList 的当前末尾
            gpuNode.primitiveIdx = (int)orderedTriList.size();

            // 根据排序后的索引，从原始数据中取出三角形，存入 orderedTriList
            // 注意：这里我们假设每个叶子只有 1 个三角形 (对应 recursiveBuild 的终止条件)
            int triIdx = sortedIndices[node->firstPrimOffset];
            orderedTriList.push_back(rawTriangles[triIdx]);
        }
        else {
            // --- 内部节点 ---
            gpuNode.nPrimitives = 0;
            gpuNode.primitiveIdx = -1;
            // 递归处理子节点 (深度优先)
            gpuNode.leftChild = flattenBVH(node->left, rawTriangles, sortedIndices);
            gpuNode.rightChild = flattenBVH(node->right, rawTriangles, sortedIndices);
        }

        // 将构建好的节点写回数组
        bvhNodes[currIdx] = gpuNode;
        return currIdx;
    }

    // --- 内存清理 ---
    void deleteBuildTree(NewBVHBuildNode* node) {
        if (node) {
            deleteBuildTree(node->left);
            deleteBuildTree(node->right);
            delete node;
        }
    }
};