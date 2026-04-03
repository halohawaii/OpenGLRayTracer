
#include "Renderer.hpp"
#include "Scene.hpp"
#include "Triangle.hpp"
#include "Sphere.hpp"
#include "Vector.hpp"
#include "global.hpp"
#include <chrono>


int main(int argc, char** argv)
{

    Scene scene(768, 768);

    Material* redWood = new Material(WOOD, Vector3f(0.0f), Vector3f(1.0f, 0.0f, 0.0f));
    //red->Kd = Vector3f(0.63f, 0.065f, 0.05f);
    Material* greenPlastic = new Material(DIFFUSE, Vector3f(0.0f), Vector3f(0.1f, 1.0f, 0.1f));
    //green->Kd = Vector3f(0.14f, 0.45f, 0.091f);
    Material* whiteWood = new Material(WOOD, Vector3f(0.0f), Vector3f(1.0f, 1.0f, 1.0f));
    Material* blackWood = new Material(DIFFUSE, Vector3f(0.0f), Vector3f(0.02f, 0.02f, 0.02f));
    //white->Kd = Vector3f(0.725f, 0.71f, 0.68f);
    Material* whiteMirror = new Material(MIRROR, Vector3f(0.0f), Vector3f(1.0f, 1.0f, 1.0f));
    //blue->Kd = Vector3f(0.0f, 0.5f, 1.0f);
    Material* bluePlastic = new Material(DIFFUSE, Vector3f(0.0f), Vector3f(0.2f, 0.1f, 1.0f));
    Material* blueGlass = new Material(MIRROR, Vector3f(0.0f), Vector3f(0.1f, 0.1f, 0.9f));
    Material* yellowGlass = new Material(MIRROR, Vector3f(0.0f), Vector3f(0.9f, 0.9f, 0.1f));
    Material* redDiamond = new Material(MIRROR, Vector3f(0.0f), Vector3f(0.9f, 0.1f, 0.1f));
    Material* light = new Material(DIFFUSE, (8.0f * Vector3f(0.747f+0.058f, 0.747f+0.258f, 0.747f) * 2 + 15.60f * Vector3f(0.740f+0.287f,0.740f+0.160f,0.740f) * 2 + 18.40f *Vector3f(0.737f+0.642f,0.737f+0.159f,0.737f) * 2));
    light->Kd = Vector3f(0.65f);

    std::string rootPath = "D:/711/OpenGLRayTracer/RayTracer/RayTracer/";
    MeshTriangle floor(rootPath + "models/cornellbox/floor.obj", blackWood, false);
    MeshTriangle ball1(rootPath + "models/cornellbox/ball1.obj", whiteMirror, true);
    MeshTriangle ball2(rootPath + "models/cornellbox/ball2.obj", bluePlastic, true);
    MeshTriangle left(rootPath + "models/cornellbox/left.obj", redWood);
    MeshTriangle right(rootPath + "models/cornellbox/right.obj", greenPlastic);
    MeshTriangle shortbox(rootPath + "models/cornellbox/shortbox2.obj", blueGlass, false, 1);
    //MeshTriangle bunny(rootPath + "models/bunny/bunny3.obj", yellowGlass, true, 1);
    MeshTriangle diamond(rootPath + "models/diamond/diamond.obj", redDiamond, false, 1);
    MeshTriangle light_(rootPath + "models/cornellbox/light3.obj", light);

    scene.Add(&floor);
    scene.Add(&ball1);
    //scene.Add(&ball2);
    scene.Add(&left);
    scene.Add(&right);
    scene.Add(&shortbox);
    //scene.Add(&bunny);
    scene.Add(&diamond);
    scene.Add(&light_);

    scene.buildBVH();
    //scene.flattenBVH(scene.bvh->root);

    Renderer r;

    auto start = std::chrono::system_clock::now();
    r.Render(scene);
    auto stop = std::chrono::system_clock::now();

    std::cout << "Render complete: \n";
    std::cout << "Time taken: " << std::chrono::duration_cast<std::chrono::hours>(stop - start).count() << " hours\n";
    std::cout << "          : " << std::chrono::duration_cast<std::chrono::minutes>(stop - start).count() << " minutes\n";
    std::cout << "          : " << std::chrono::duration_cast<std::chrono::seconds>(stop - start).count() << " seconds\n";
    std::cout << "          : " << std::chrono::duration_cast<std::chrono::milliseconds>(stop - start).count();

    return 0;
}