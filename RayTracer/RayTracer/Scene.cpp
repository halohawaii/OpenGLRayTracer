//
// Created by Göksu Güvendiren on 2019-05-14.
//
//#define EPSILON 0.0001f
#include "Scene.hpp"


void Scene::buildBVH() {
    printf(" - Generating BVH...\n\n");
    this->bvh = new BVHAccel(objects, 1, BVHAccel::SplitMethod::NAIVE);
}

Intersection Scene::intersect(const Ray &ray) const
{
    return this->bvh->Intersect(ray);
}

void Scene::sampleLight(Intersection &pos, float &pdf) const
{
    float emit_area_sum = 0;
    for (uint32_t k = 0; k < objects.size(); ++k) {
        if (objects[k]->hasEmit()){
            emit_area_sum += objects[k]->getArea();
        }
    }
    float p = get_random_float() * emit_area_sum;
    emit_area_sum = 0;
    for (uint32_t k = 0; k < objects.size(); ++k) {
        if (objects[k]->hasEmit()){
            emit_area_sum += objects[k]->getArea();
            if (p <= emit_area_sum){
                objects[k]->Sample(pos, pdf);
                break;
            }
        }
    }
}

bool Scene::trace(
        const Ray &ray,
        const std::vector<Object*> &objects,
        float &tNear, uint32_t &index, Object **hitObject)
{
    *hitObject = nullptr;
    for (uint32_t k = 0; k < objects.size(); ++k) {
        float tNearK = kInfinity;
        uint32_t indexK;
        Vector2f uvK;
        if (objects[k]->intersect(ray, tNearK, indexK) && tNearK < tNear) {
            *hitObject = objects[k];
            tNear = tNearK;
            index = indexK;
        }
    }


    return (*hitObject != nullptr);
}

// Implementation of Path Tracing
Vector3f Scene::castRay(const Ray &ray, int depth) const
{
    // TO DO Implement Path Tracing Algorithm here

    Vector3f DirectColor = {0, 0, 0};
    Vector3f IndirectColor = { 0, 0, 0 };

    Intersection inter = intersect(ray); // hit intersection

    if (!inter.happened)
    {
        return {0, 0, 0};
    }

    if (inter.m->hasEmission())
    {
        if (depth == 0)
        {
            return inter.m->getEmission();
        }
        else
        {
            return {0, 0, 0};
        }
    }

    Intersection light_pos;
    float pdf_light = 0.0f;
    sampleLight(light_pos, pdf_light);

    Vector3f lightPos = light_pos.coords;
    Vector3f objPos = inter.coords;
    Vector3f lightDir = (objPos - lightPos).normalized();
    Vector3f N = inter.normal.normalized();
    Vector3f lightNormal = light_pos.normal.normalized();

    //  Check block
    Ray light_to_obj(lightPos, lightDir);
    Intersection lightScene = intersect(light_to_obj);
    float lightObjDis = (objPos - lightPos).norm();
    float lightObjDis2 = dotProduct(objPos - lightPos, objPos - lightPos);
    
    if (lightScene.happened && lightObjDis - lightScene.distance < EPSILON) //no block
    {
        Vector3f lightIntensity = light_pos.emit;
        Vector3f f_r = inter.m->eval(ray.direction, -lightDir, N);
        float cosTheta = dotProduct(-lightDir, N);
        float cosTheta1 = dotProduct(lightDir, lightNormal);
        DirectColor = lightIntensity * f_r * cosTheta * cosTheta1 / lightObjDis2 / pdf_light;
    }
    
    float ksi = get_random_float();
    if (ksi < RussianRoulette)
    {
        Vector3f wi = inter.m->sample(ray.direction, N).normalized();
        Ray r(objPos, wi);
        Intersection ObjScene = intersect(r);
        if (ObjScene.happened && !ObjScene.m->hasEmission())
        {
            Vector3f f_r = inter.m->eval(ray.direction, wi, N);
            float cosTheta = dotProduct(wi, N);
            float pdf_hemi = inter.m->pdf(ray.direction, wi, N);
            IndirectColor = castRay(r, depth + 1) * f_r * cosTheta / pdf_hemi / RussianRoulette;
        }
    }
    return DirectColor;
}