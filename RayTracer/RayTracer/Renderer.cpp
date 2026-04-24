//
// Created by goksu on 2/25/20.
//
#define _CRT_SECURE_NO_WARNINGS
#include <fstream>
#include "Scene.hpp"
#include "Renderer.hpp"
#include <thread>
#include <mutex>
#include <glad/glad.h>
#include <GLFW/glfw3.h>
#include <iostream>
#include <sstream>
#include <chrono>
#include "BVHConstructor.hpp"
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#include "imgui.h"
#include "imgui_impl_glfw.h"
#include "imgui_impl_opengl3.h"

inline float deg2rad(const float& deg) { return deg * M_PI / 180.0; }

const float EPSILON = 0.001;

static float cameraYaw = 0.0f;
static float cameraPitch = 0.0f;

std::mutex mtx;

GLuint loadTexture(const char* path) {
    int width, height, nrChannels;
    unsigned char* data = stbi_load(path, &width, &height, &nrChannels, 0);

    GLuint textureID;
    glGenTextures(1, &textureID);
    glBindTexture(GL_TEXTURE_2D, textureID);

    // 设置纹理参数
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

    // 上传数据
    GLenum format = (nrChannels == 4) ? GL_RGBA : GL_RGB;
    glTexImage2D(GL_TEXTURE_2D, 0, format, width, height, 0, format, GL_UNSIGNED_BYTE, data);
    glGenerateMipmap(GL_TEXTURE_2D);

    stbi_image_free(data);
    return textureID;
}

void processInput(GLFWwindow* window, CameraGPU& cam, int& frameCount, bool& isExit, bool imguiWantsKeyboard) {
    if (imguiWantsKeyboard) return;
    float moveSpeed = 5.0f;
    float rotateSpeed = 0.5f;
    bool moved = false;

    if (glfwGetKey(window, GLFW_KEY_A) == GLFW_PRESS) {
        cam.pos[0] += cam.right[0] * moveSpeed;
        cam.pos[1] += cam.right[1] * moveSpeed;
        cam.pos[2] += cam.right[2] * moveSpeed;
        moved = true;
    }
    if (glfwGetKey(window, GLFW_KEY_D) == GLFW_PRESS) {
        cam.pos[0] -= cam.right[0] * moveSpeed;
        cam.pos[1] -= cam.right[1] * moveSpeed;
        cam.pos[2] -= cam.right[2] * moveSpeed;
        moved = true;
    }
    if (glfwGetKey(window, GLFW_KEY_S) == GLFW_PRESS) {
        cam.pos[0] -= cam.forward[0] * moveSpeed;
        cam.pos[1] -= cam.forward[1] * moveSpeed;
        cam.pos[2] -= cam.forward[2] * moveSpeed;
        moved = true;
    }
    if (glfwGetKey(window, GLFW_KEY_W) == GLFW_PRESS) {
        cam.pos[0] += cam.forward[0] * moveSpeed;
        cam.pos[1] += cam.forward[1] * moveSpeed;
        cam.pos[2] += cam.forward[2] * moveSpeed;
        moved = true;
    }
    if (glfwGetKey(window, GLFW_KEY_SPACE) == GLFW_PRESS) {
        cam.pos[0] += cam.up[0] * moveSpeed;
        cam.pos[1] += cam.up[1] * moveSpeed;
        cam.pos[2] += cam.up[2] * moveSpeed;
        moved = true;
    }
    if (glfwGetKey(window, GLFW_KEY_LEFT_CONTROL) == GLFW_PRESS) {
        cam.pos[0] += -cam.up[0] * moveSpeed;
        cam.pos[1] += -cam.up[1] * moveSpeed;
        cam.pos[2] += -cam.up[2] * moveSpeed;
        moved = true;
    }
    if (glfwGetKey(window, GLFW_KEY_LEFT) == GLFW_PRESS) {
        cameraYaw += rotateSpeed * M_PI / 180.0;
        moved = true;
    }
    if (glfwGetKey(window, GLFW_KEY_RIGHT) == GLFW_PRESS) {
        cameraYaw -= rotateSpeed * M_PI / 180.0;
        moved = true;
    }
    if (glfwGetKey(window, GLFW_KEY_UP) == GLFW_PRESS) {
        cameraPitch += rotateSpeed * M_PI / 180.0;
        if (cameraPitch > 1.55f) cameraPitch = 1.55f;
        moved = true;
    }
    if (glfwGetKey(window, GLFW_KEY_DOWN) == GLFW_PRESS) {
        cameraPitch -= rotateSpeed * M_PI / 180.0;
        if (cameraPitch < -1.55f) cameraPitch = -1.55f;
        moved = true;
    }
    if (glfwGetKey(window, GLFW_KEY_ESCAPE) == GLFW_PRESS) {
        isExit = true;
    }


    if (moved) {
        frameCount = 0;

        float cp = cos(cameraPitch);
        float sp = sin(cameraPitch);
        float cy = cos(cameraYaw);
        float sy = sin(cameraYaw);

        cam.forward[0] = sy * cp;
        cam.forward[1] = sp;
        cam.forward[2] = cy * cp;

        // right = normalize(cross(worldUp, forward))
        float worldUpX = 0.0f, worldUpY = 1.0f, worldUpZ = 0.0f;
        cam.right[0] = worldUpY * cam.forward[2] - worldUpZ * cam.forward[1];
        cam.right[1] = worldUpZ * cam.forward[0] - worldUpX * cam.forward[2];
        cam.right[2] = worldUpX * cam.forward[1] - worldUpY * cam.forward[0];

        float rightMag = sqrt(cam.right[0] * cam.right[0] + cam.right[1] * cam.right[1] + cam.right[2] * cam.right[2]);
        if (rightMag > 1e-6f) {
            cam.right[0] /= rightMag;
            cam.right[1] /= rightMag;
            cam.right[2] /= rightMag;
        }

        // up = normalize(cross(forward, right))
        cam.up[0] = cam.forward[1] * cam.right[2] - cam.forward[2] * cam.right[1];
        cam.up[1] = cam.forward[2] * cam.right[0] - cam.forward[0] * cam.right[2];
        cam.up[2] = cam.forward[0] * cam.right[1] - cam.forward[1] * cam.right[0];
    }
}

// ================= Shader Compiling =================
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

// ================= File Reading =================
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

static std::vector<TriangleGPU> AssembleAllTriangles(const Scene& s)
{
    std::vector<TriangleGPU> res;
    for (auto& obj : s.objects) {
        obj->AssembleTriangles(res);
        //res.insert(res.end(), tris.begin(), tris.end());
    }
    return res;
}

// The main render function. This where we iterate over all pixels in the image,
// generate primary rays and cast these rays into the scene. The content of the
// framebuffer is saved to a file.
void Renderer::Render(const Scene& scene)
{
    CameraGPU cam{};
    cam.pos[0] = 278.f;
    cam.pos[1] = 273.f;
    cam.pos[2] = -800.f;

    cam.fov = scene.fov;

    cam.forward[0] = 0;
    cam.forward[1] = 0;
    cam.forward[2] = 1;

    cam.right[0] = 1;
    cam.right[1] = 0;
    cam.right[2] = 0;

    cam.up[0] = 0;
    cam.up[1] = 1;
    cam.up[2] = 0;

    cam.SuperSample = 0; //SS

    // --- ImGui parameter state ---
    float param_causticStrength  = 4.0f;
    float param_lightIntensity   = 1.0f;
    float param_ior              = 2.417f;
    int   param_photonsPerPixel  = 4;
    float param_russianRoulette  = 0.8f;
    int   param_maxPhotonBounces = 12;
    int   param_maxRayBounces    = 20;
    // Initialized to -1 to force upload on first frame
    float sent_causticStrength  = -1.0f;
    float sent_lightIntensity   = -1.0f;
    float sent_ior              = -1.0f;
    int   sent_photonsPerPixel  = -1;
    float sent_russianRoulette  = -1.0f;
    int   sent_maxPhotonBounces = -1;
    int   sent_maxRayBounces    = -1;

    std::vector<Vector3f> framebuffer(scene.width * scene.height);

    // ---------- Initialize GLFW ----------
    if (!glfwInit())
        return;

    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 4);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);

    GLFWwindow* window = glfwCreateWindow(scene.width, scene.height, "Compute Shader Test", nullptr, nullptr);
    if (!window)
    {
        glfwTerminate();
        return;
    }

    glfwMakeContextCurrent(window);

    // ---------- Initialize GLAD ----------
    if (!gladLoadGLLoader((GLADloadproc)glfwGetProcAddress))
    {
        std::cerr << "Failed to initialize GLAD" << std::endl;
        return;
    }

    // ---------- Initialize ImGui ----------
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::StyleColorsDark();
    ImGui_ImplGlfw_InitForOpenGL(window, true);
    ImGui_ImplOpenGL3_Init("#version 430");

    GLuint cameraUBO;
    glGenBuffers(1, &cameraUBO);
    glBindBuffer(GL_UNIFORM_BUFFER, cameraUBO);
    glBufferData(GL_UNIFORM_BUFFER,
        sizeof(CameraGPU),
        &cam,
        GL_STATIC_DRAW);

    glBindBufferBase(GL_UNIFORM_BUFFER, 0, cameraUBO);


    GLuint raySSBO;
    glGenBuffers(1, &raySSBO);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, raySSBO);
    glBufferData(GL_SHADER_STORAGE_BUFFER,
        scene.width * scene.height * sizeof(RayGPU),
        nullptr,
        GL_DYNAMIC_COPY);

    glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, raySSBO);

    GLuint outputTexture;
    glGenTextures(1, &outputTexture);
    glBindTexture(GL_TEXTURE_2D, outputTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR); 
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA32F, scene.width, scene.height);

    glBindImageTexture(2, outputTexture, 0, GL_FALSE, 0, GL_READ_WRITE, GL_RGBA32F);

    GLuint causticTexture;
    glGenTextures(1, &causticTexture);
    glBindTexture(GL_TEXTURE_2D, causticTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA32F, scene.width, scene.height);
    glBindImageTexture(7, causticTexture, 0, GL_FALSE, 0, GL_READ_WRITE, GL_RGBA32F);

    std::vector<TriangleGPU> triList = AssembleAllTriangles(scene);

    /*std::vector<BVHNodeGPU> bvhNodes;
    std::vector<TriangleGPU> orderedTriList;
    scene.flattenBVH(scene.bvh->root, bvhNodes, orderedTriList);*/

    BVHConstructor bvhBuilder;
    bvhBuilder.build(triList);
    std::vector<BVHNodeGPU>& finalNodes = bvhBuilder.bvhNodes;
    std::vector<TriangleGPU>& finalTriangles = bvhBuilder.orderedTriList;

    GLuint srcFBO;
    glGenFramebuffers(1, &srcFBO);
    glBindFramebuffer(GL_FRAMEBUFFER, srcFBO);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, outputTexture, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
        std::cout << "FBO Error!" << std::endl;
    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    GLuint meshSSBO;
    glGenBuffers(1, &meshSSBO);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, meshSSBO);
    glBufferData(GL_SHADER_STORAGE_BUFFER, finalTriangles.size() * sizeof(TriangleGPU), finalTriangles.data(), GL_STATIC_DRAW);
    glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 3, meshSSBO);

    GLuint bvhSSBO;
    glGenBuffers(1, &bvhSSBO);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, bvhSSBO);
    glBufferData(GL_SHADER_STORAGE_BUFFER, finalNodes.size() * sizeof(BVHNodeGPU), finalNodes.data(), GL_STATIC_DRAW);
    glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 4, bvhSSBO);

    //Light source
    std::vector<int> lightIndices;
    for (int i = 0; i < (int)finalTriangles.size(); ++i) {
        if (finalTriangles[i].emission[0] > 0.001f ||
            finalTriangles[i].emission[1] > 0.001f ||
            finalTriangles[i].emission[2] > 0.001f) {
            lightIndices.push_back(i);
        }
    }
    if (lightIndices.empty()) lightIndices.push_back(-1);
    GLuint lightSSBO;
    glGenBuffers(1, &lightSSBO);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, lightSSBO);
    glBufferData(GL_SHADER_STORAGE_BUFFER, lightIndices.size() * sizeof(int), lightIndices.data(), GL_STATIC_DRAW);
    glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 5, lightSSBO);

    // Textures
    GLuint floorTex = loadTexture("./textures/T_Floor2_D.png");


    // ---------- Read Compute Shader ----------
    std::string csSource = LoadTextFile("raygen.glsl");
    if (csSource.empty())
        return;

    GLuint rayGenProgram = CompileComputeShader(csSource.c_str());

    glUseProgram(rayGenProgram);
    GLint frameCountLoc       = glGetUniformLocation(rayGenProgram, "frameCount");
    GLint passModeLoc         = glGetUniformLocation(rayGenProgram, "u_passMode");
    GLint causticStrengthLoc  = glGetUniformLocation(rayGenProgram, "u_causticStrength");
    GLint lightIntensityLoc   = glGetUniformLocation(rayGenProgram, "u_lightIntensity");
    GLint iorLoc              = glGetUniformLocation(rayGenProgram, "u_ior");
    GLint rrLoc               = glGetUniformLocation(rayGenProgram, "u_russianRoulette");
    GLint photonsPerPixelLoc  = glGetUniformLocation(rayGenProgram, "u_photonsPerPixel");
    GLint maxPhotonBouncesLoc = glGetUniformLocation(rayGenProgram, "u_maxPhotonBounces");
    GLint maxRayBouncesLoc    = glGetUniformLocation(rayGenProgram, "u_maxRayBounces");
    glUniform1i(glGetUniformLocation(rayGenProgram, "imageWidth"),   scene.width);
    glUniform1i(glGetUniformLocation(rayGenProgram, "imageHeight"),  scene.height);
    glUniform1i(glGetUniformLocation(rayGenProgram, "u_lightCount"), (int)lightIndices.size());

    auto start = std::chrono::system_clock::now();
    int spp = 1024;
    int currentFrame = 0;
    bool esc = false;
    while (!glfwWindowShouldClose(window))
    {
        glfwPollEvents();

        // --- ImGui new frame ---
        ImGui_ImplOpenGL3_NewFrame();
        ImGui_ImplGlfw_NewFrame();
        ImGui::NewFrame();
        ImGuiIO& io = ImGui::GetIO();

        processInput(window, cam, currentFrame, esc, io.WantCaptureKeyboard);
        if (esc)
        {
            break;
        }

        // --- Detect parameter changes and upload uniforms ---
        glUseProgram(rayGenProgram);
        bool paramsChanged = false;
        if (param_causticStrength  != sent_causticStrength)  { glUniform1f(causticStrengthLoc,  param_causticStrength);  sent_causticStrength  = param_causticStrength;  paramsChanged = true; }
        if (param_lightIntensity   != sent_lightIntensity)   { glUniform1f(lightIntensityLoc,   param_lightIntensity);   sent_lightIntensity   = param_lightIntensity;   paramsChanged = true; }
        if (param_ior              != sent_ior)              { glUniform1f(iorLoc,              param_ior);              sent_ior              = param_ior;              paramsChanged = true; }
        if (param_russianRoulette  != sent_russianRoulette)  { glUniform1f(rrLoc,               param_russianRoulette);  sent_russianRoulette  = param_russianRoulette;  paramsChanged = true; }
        if (param_photonsPerPixel  != sent_photonsPerPixel)  { glUniform1i(photonsPerPixelLoc,  param_photonsPerPixel);  sent_photonsPerPixel  = param_photonsPerPixel;  paramsChanged = true; }
        if (param_maxPhotonBounces != sent_maxPhotonBounces) { glUniform1i(maxPhotonBouncesLoc, param_maxPhotonBounces); sent_maxPhotonBounces = param_maxPhotonBounces; paramsChanged = true; }
        if (param_maxRayBounces    != sent_maxRayBounces)    { glUniform1i(maxRayBouncesLoc,    param_maxRayBounces);    sent_maxRayBounces    = param_maxRayBounces;    paramsChanged = true; }
        if (paramsChanged) currentFrame = 0;

        // --- ImGui panel ---
        ImGui::SetNextWindowPos(ImVec2(10, 10), ImGuiCond_Once);
        ImGui::SetNextWindowSize(ImVec2(400, 250), ImGuiCond_Once);
        ImGui::Begin("Path Tracer Controls");
        ImGui::Text("SPP: %d / %d", currentFrame, spp);
        ImGui::Separator();
        ImGui::SliderFloat("Caustic Strength", &param_causticStrength,  0.0f, 10.0f);
        ImGui::SliderFloat("Light Intensity",  &param_lightIntensity,   0.0f, 5.0f);
        ImGui::SliderFloat("IOR",              &param_ior,               1.0f, 3.0f);
        ImGui::SliderInt  ("Photons/Pixel",    &param_photonsPerPixel,   1,    16);
        ImGui::SliderFloat("Russian Roulette", &param_russianRoulette,   0.5f, 1.0f);
        ImGui::SliderInt  ("Max Photon Depth", &param_maxPhotonBounces,  1,    30);
        ImGui::SliderInt  ("Max Ray Depth",    &param_maxRayBounces,     1,    30);
        ImGui::Separator();
        if (ImGui::Button("Reset Accumulation")) currentFrame = 0;
        ImGui::End();
        ImGui::Render();

        if (currentFrame < spp)
        {
            if (currentFrame == 0) {
                glBindBuffer(GL_UNIFORM_BUFFER, cameraUBO);
                glBufferSubData(GL_UNIFORM_BUFFER, 0, sizeof(CameraGPU), &cam);
            }

            glUniform1i(frameCountLoc, currentFrame);

            glActiveTexture(GL_TEXTURE6);
            glBindTexture(GL_TEXTURE_2D, floorTex);

            glUniform1i(glGetUniformLocation(rayGenProgram, "u_Texture"), 6);

            glUniform1i(passModeLoc, 1);
            glDispatchCompute(
                (scene.width + 7) / 8,
                (scene.height + 7) / 8,
                1
            );
            glMemoryBarrier(GL_SHADER_IMAGE_ACCESS_BARRIER_BIT | GL_SHADER_STORAGE_BARRIER_BIT);

            glUniform1i(passModeLoc, 0);
            glDispatchCompute(
                (scene.width + 7) / 8,
                (scene.height + 7) / 8,
                1
            );

            glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);

            currentFrame++;

            if (currentFrame % 10 == 0) {
                std::cout << "Progress: " << currentFrame << "/" << spp << " SPP" << std::endl;
            }
        }

        glBindFramebuffer(GL_READ_FRAMEBUFFER, srcFBO);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);

        glBlitFramebuffer(0, 0, scene.width, scene.height,
            0, scene.height, scene.width, 0,
            GL_COLOR_BUFFER_BIT, GL_NEAREST);

        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());

        glfwSwapBuffers(window);
    }

    ImGui_ImplOpenGL3_Shutdown();
    ImGui_ImplGlfw_Shutdown();
    ImGui::DestroyContext();
    auto stop = std::chrono::system_clock::now();
    std::cout << "Render Time: " << std::chrono::duration_cast<std::chrono::milliseconds>(stop - start).count() << "milliseconds\n\n";

    /*glDispatchCompute(
        (scene.width + 7) / 8,
        (scene.height + 7) / 8,
        1
    );

    glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);*/

    std::vector<float> gpuData(scene.width * scene.height * 4);
    glBindTexture(GL_TEXTURE_2D, outputTexture);
    glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_FLOAT, gpuData.data());
    for (uint32_t i = 0; i < scene.width * scene.height; ++i) {
        framebuffer[i].x = gpuData[i * 4 + 0];
        framebuffer[i].y = gpuData[i * 4 + 1];
        framebuffer[i].z = gpuData[i * 4 + 2];
    }

    glBindBuffer(GL_SHADER_STORAGE_BUFFER, raySSBO);
    RayGPU* rays = (RayGPU*)glMapBuffer(GL_SHADER_STORAGE_BUFFER, GL_READ_ONLY);

    int cx = scene.width / 2;
    int cy = scene.height / 2;
    RayGPU& r = rays[cy * scene.width + cx];

    std::cout << "Dir = "
        << r.dx << ", "
        << r.dy << ", "
        << r.dz << ", "
        << r._pad0 << std::endl;

    glUnmapBuffer(GL_SHADER_STORAGE_BUFFER);

    
    /*
    float scale = tan(deg2rad(scene.fov * 0.5));
    float imageAspectRatio = scene.width / (float)scene.height;
    Vector3f eye_pos(278, 273, -800);
    int m = 0;

    // change the spp value to change sample ammount
    int spp = 64;
    std::cout << "SPP: " << spp << "\n";

    const int thred = 20;
    int times = scene.height / thred;
    std::thread th[thred];
    int process = 0;

    auto castRayMultiThread = [&](uint32_t y_min, uint32_t y_max) {
        for (uint32_t j = y_min; j < y_max; j++)
        {
            int m = j * scene.width;
            for (uint32_t i = 0; i < scene.width; i++)
            {
                float x = (2 * (i + 0.5) / (float)scene.width - 1) *
                    imageAspectRatio * scale;
                float y = (1 - 2 * (j + 0.5) / (float)scene.height) * scale;

                Vector3f dir = normalize(Vector3f(-x, y, 1));
                for (int k = 0; k < spp; k++) {
                    framebuffer[m] += scene.castRay(Ray(eye_pos, dir), 0) / spp;
                }
                m++;
            }
            mtx.lock();
            process++;
            UpdateProgress(1.0 * process / scene.height);
            mtx.unlock();
        }
    };

    for (int i = 0; i < thred; i++)
    {
        th[i] = std::thread(castRayMultiThread, i * times, (i + 1) * times);
    }

    for (int i = 0; i < thred; i++) 
    {
        th[i].join();
    }*/
    /*
    for (uint32_t j = 0; j < scene.height; ++j) {
        for (uint32_t i = 0; i < scene.width; ++i) {
            // generate primary ray direction
            float x = (2 * (i + 0.5) / (float)scene.width - 1) *
                      imageAspectRatio * scale;
            float y = (1 - 2 * (j + 0.5) / (float)scene.height) * scale;

            Vector3f dir = normalize(Vector3f(-x, y, 1));
            for (int k = 0; k < spp; k++){
                framebuffer[m] += scene.castRay(Ray(eye_pos, dir), 0) / spp;  
            }
            m++;
        }
        UpdateProgress(j / (float)scene.height);
    }
    UpdateProgress(1.f);
    */
    // save framebuffer to file
    FILE* fp = fopen("binary.ppm", "wb");
    (void)fprintf(fp, "P6\n%d %d\n255\n", scene.width, scene.height);
    for (auto i = 0; i < scene.height * scene.width; ++i) {
        static unsigned char color[3];
        color[0] = (unsigned char)(255 * std::pow(clamp(0, 1, framebuffer[i].x), 0.6f));
        color[1] = (unsigned char)(255 * std::pow(clamp(0, 1, framebuffer[i].y), 0.6f));
        color[2] = (unsigned char)(255 * std::pow(clamp(0, 1, framebuffer[i].z), 0.6f));
        fwrite(color, 1, 3, fp);
    }
    fclose(fp);

    //while (!glfwWindowShouldClose(window))
    //{
    //    glBindFramebuffer(GL_READ_FRAMEBUFFER, srcFBO);
    //    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
    //    glBlitFramebuffer(0, 0, scene.width, scene.height,
    //        0, scene.height, scene.width, 0,
    //        GL_COLOR_BUFFER_BIT, GL_NEAREST);

    //    glfwSwapBuffers(window);
    //    glfwPollEvents();
    //}
}


