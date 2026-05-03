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
    void build(const std::vector<TriangleGPU>& rawTriangles) {
        if (rawTriangles.empty()) return;

        bvhNodes.clear();
        orderedTriList.clear();

        std::vector<int> primitiveIndices(rawTriangles.size());
        for (int i = 0; i < primitiveIndices.size(); ++i) {
            primitiveIndices[i] = i;
        }

        NewBVHBuildNode* root = recursiveBuild(primitiveIndices, 0, (int)primitiveIndices.size(), rawTriangles);

        flattenBVH(root, rawTriangles, primitiveIndices);

        deleteBuildTree(root);
    }

private:
    Bounds3 getTriBounds(const TriangleGPU& tri) {
        Vector3f v0(tri.v0[0], tri.v0[1], tri.v0[2]);
        Vector3f v1(tri.v1[0], tri.v1[1], tri.v1[2]);
        Vector3f v2(tri.v2[0], tri.v2[1], tri.v2[2]);
        return Union(Bounds3(v0, v1), v2);
    }

    Vector3f getTriCentroid(const TriangleGPU& tri) {
        return Vector3f(
            (tri.v0[0] + tri.v1[0] + tri.v2[0]) / 3.0f,
            (tri.v0[1] + tri.v1[1] + tri.v2[1]) / 3.0f,
            (tri.v0[2] + tri.v1[2] + tri.v2[2]) / 3.0f
        );
    }

    NewBVHBuildNode* recursiveBuild(std::vector<int>& indices, int start, int end,
        const std::vector<TriangleGPU>& rawTriangles)
    {
        NewBVHBuildNode* node = new NewBVHBuildNode();

        Bounds3 bounds;
        for (int i = start; i < end; ++i) {
            bounds = Union(bounds, getTriBounds(rawTriangles[indices[i]]));
        }
        node->bounds = bounds;

        int nPrimitives = end - start;

        if (nPrimitives == 1) {
            node->firstPrimOffset = start;
            node->nPrimitives = nPrimitives;
            return node;
        }

        Bounds3 centroidBounds;
        for (int i = start; i < end; ++i) {
            centroidBounds = Union(centroidBounds, getTriCentroid(rawTriangles[indices[i]]));
        }
        int dim = centroidBounds.maxExtent();

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

        node->left = recursiveBuild(indices, start, mid, rawTriangles);
        node->right = recursiveBuild(indices, mid, end, rawTriangles);

        return node;
    }

    int flattenBVH(NewBVHBuildNode* node, const std::vector<TriangleGPU>& rawTriangles,
        const std::vector<int>& sortedIndices)
    {
        if (!node) return -1;

        int currIdx = (int)bvhNodes.size();
        bvhNodes.emplace_back();

        BVHNodeGPU gpuNode;
        gpuNode.pMin[0] = node->bounds.pMin.x; gpuNode.pMin[1] = node->bounds.pMin.y; gpuNode.pMin[2] = node->bounds.pMin.z;
        gpuNode.pMax[0] = node->bounds.pMax.x; gpuNode.pMax[1] = node->bounds.pMax.y; gpuNode.pMax[2] = node->bounds.pMax.z;

        if (node->nPrimitives > 0) {
            gpuNode.leftChild = -1;
            gpuNode.rightChild = -1;
            gpuNode.nPrimitives = node->nPrimitives;

            gpuNode.primitiveIdx = (int)orderedTriList.size();

            int triIdx = sortedIndices[node->firstPrimOffset];
            orderedTriList.push_back(rawTriangles[triIdx]);
        }
        else {
            gpuNode.nPrimitives = 0;
            gpuNode.primitiveIdx = -1;
            gpuNode.leftChild = flattenBVH(node->left, rawTriangles, sortedIndices);
            gpuNode.rightChild = flattenBVH(node->right, rawTriangles, sortedIndices);
        }

        bvhNodes[currIdx] = gpuNode;
        return currIdx;
    }

    void deleteBuildTree(NewBVHBuildNode* node) {
        if (node) {
            deleteBuildTree(node->left);
            deleteBuildTree(node->right);
            delete node;
        }
    }
};