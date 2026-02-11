
#include "Renderer.hpp"
#include "Scene.hpp"
#include "Triangle.hpp"
#include "Sphere.hpp"
#include "Vector.hpp"
#include "global.hpp"
#include <chrono>

// In the main function of the program, we create the scene (create objects and
// lights) as well as set the options for the render (image width and height,
// maximum recursion depth, field-of-view, etc.). We then call the render
// function().
int main(int argc, char** argv)
{

    // Change the definition here to change resolution
    Scene scene(784, 784);

    Material* red = new Material(DIFFUSE, Vector3f(0.0f));
    red->Kd = Vector3f(0.63f, 0.065f, 0.05f);
    Material* green = new Material(DIFFUSE, Vector3f(0.0f));
    green->Kd = Vector3f(0.14f, 0.45f, 0.091f);
    Material* white = new Material(DIFFUSE, Vector3f(0.0f));
    white->Kd = Vector3f(0.725f, 0.71f, 0.68f);
    Material* blue = new Material(DIFFUSE, Vector3f(0.0f));
    blue->Kd = Vector3f(0.0f, 0.5f, 1.0f);
    Material* light = new Material(DIFFUSE, (8.0f * Vector3f(0.747f+0.058f, 0.747f+0.258f, 0.747f) + 15.6f * Vector3f(0.740f+0.287f,0.740f+0.160f,0.740f) + 18.4f *Vector3f(0.737f+0.642f,0.737f+0.159f,0.737f)));
    light->Kd = Vector3f(0.65f);

    std::string rootPath = "D:/711/OpenGLRayTracer/RayTracer/RayTracer/";
    MeshTriangle floor(rootPath + "models/cornellbox/floor.obj", white);
    MeshTriangle ball1 (rootPath + "models/bunny/bunny2.obj", white);
    MeshTriangle ball2(rootPath + "models/cornellbox/ball2.obj", white);
    MeshTriangle left(rootPath + "models/cornellbox/left.obj", red);
    MeshTriangle right(rootPath + "models/cornellbox/right.obj", green);
    MeshTriangle shortbox(rootPath + "models/cornellbox/shortbox.obj", white);
    MeshTriangle light_(rootPath + "models/cornellbox/light.obj", light);

    scene.Add(&floor);
    scene.Add(&ball1);
    scene.Add(&ball2);
    scene.Add(&left);
    scene.Add(&right);
    scene.Add(&shortbox);
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



/*
#include <glad/glad.h>
#include <GLFW/glfw3.h>

#include <iostream>
#include <fstream>
#include <sstream>
#include <vector>
#include <string>

// ================= 文件读取 =================
std::string LoadTextFile(const std::string& path)
{
    std::ifstream file(path);
    if (!file.is_open())
    {
        std::cerr << "Failed to open file: " << path << std::endl;
        return "";
    }

    std::stringstream buffer;
    buffer << file.rdbuf();
    return buffer.str();
}

// ================= Shader 编译 =================
GLuint CompileComputeShader(const char* source)
{
    GLuint shader = glCreateShader(GL_COMPUTE_SHADER);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);

    GLint success;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &success);
    if (!success)
    {
        char log[1024];
        glGetShaderInfoLog(shader, 1024, nullptr, log);
        std::cerr << "Compute shader compile error:\n" << log << std::endl;
    }

    GLuint program = glCreateProgram();
    glAttachShader(program, shader);
    glLinkProgram(program);

    glGetProgramiv(program, GL_LINK_STATUS, &success);
    if (!success)
    {
        char log[1024];
        glGetProgramInfoLog(program, 1024, nullptr, log);
        std::cerr << "Program link error:\n" << log << std::endl;
    }

    glDeleteShader(shader);
    return program;
}

// ================= 主程序 =================
int main()
{
    // ---------- 初始化 GLFW ----------
    if (!glfwInit())
        return -1;

    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 4);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);

    GLFWwindow* window = glfwCreateWindow(640, 480, "Compute Shader Test", nullptr, nullptr);
    if (!window)
    {
        glfwTerminate();
        return -1;
    }

    glfwMakeContextCurrent(window);

    // ---------- 初始化 GLAD ----------
    if (!gladLoadGLLoader((GLADloadproc)glfwGetProcAddress))
    {
        std::cerr << "Failed to initialize GLAD" << std::endl;
        return -1;
    }

    // ---------- 读取 Compute Shader ----------
    std::string csSource = LoadTextFile("test.hlsl");
    if (csSource.empty())
        return -1;

    GLuint program = CompileComputeShader(csSource.c_str());

    // ---------- 创建 SSBO ----------
    const int count = 16;
    std::vector<float> data(count, 0.0f);

    GLuint ssbo;
    glGenBuffers(1, &ssbo);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
    glBufferData(GL_SHADER_STORAGE_BUFFER,
        sizeof(float) * count,
        data.data(),
        GL_DYNAMIC_COPY);

    glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, ssbo);

    // ---------- 执行 Compute Shader ----------
    glUseProgram(program);
    glDispatchCompute(count, 1, 1);

    // 同步，保证 GPU 写完
    glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);

    // ---------- 读回数据 ----------
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
    float* ptr = (float*)glMapBuffer(GL_SHADER_STORAGE_BUFFER, GL_READ_ONLY);

    std::cout << "Result:" << std::endl;
    for (int i = 0; i < count; ++i)
        std::cout << ptr[i] << " ";

    std::cout << std::endl;

    glUnmapBuffer(GL_SHADER_STORAGE_BUFFER);

    // ---------- 清理 ----------
    glDeleteBuffers(1, &ssbo);
    glDeleteProgram(program);

    glfwDestroyWindow(window);
    glfwTerminate();

    return 0;
}
*/