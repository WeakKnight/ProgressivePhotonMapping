#pragma once
__exported import Types;
#include "Utils/Math/MathConstants.slangh"
__exported import Utils.Sampling.SampleGenerator;
__exported import Utils.Sampling.AliasTable;
__exported import Utils.Geometry.GeometryHelpers;
__exported import Utils.Math.MathHelpers;
__exported import Scene.Scene;
__exported import Scene.RaytracingInline;
__exported import ShadingDataLoader;
__exported import Rendering.Lights.EnvMapSampler;
__exported import Rendering.Lights.EmissiveLightSampler;
__exported import Rendering.Lights.EmissiveLightSamplerHelpers;

uint visiblePointPositionToPointer(uint2 pixel, PhotonMappingParams params)
{
    return pixel.x + pixel.y * params.frameDim.x;
}

bool traceShadowRay(float3 origin, float3 dir, float distance)
{
    Ray ray;
    ray.origin = origin;
    ray.dir = dir;
    ray.tMin = 0.0f;
    ray.tMax = distance;

    return traceSceneVisibilityRay<1>(ray, RAY_FLAG_NONE, 0xff);
}

bool traceScatterRay(float3 origin, float3 dir, out HitInfo hit, out float hitT)
{
    Ray ray;
    ray.origin = origin;
    ray.dir = dir;
    ray.tMin = 0.0f;
    ray.tMax = 1.0e38f;

    return traceSceneRay<1>(ray, hit, hitT, RAY_FLAG_NONE, 0xff);
}

float3 evalEmissiveLighting(ShadingData sd, inout SampleGenerator sg, EmissiveLightSampler emissiveSampler)
{
    TriangleLightSample tls;
    if (emissiveSampler.sampleLight(sd.posW, sd.N, true, sg, tls))
    {
        ITextureSampler lod = ExplicitLodTextureSampler(0.f);
        IBSDF bsdf = gScene.materials.getBSDF(sd, lod);

        float3 lightPos = computeRayOrigin(tls.posW, tls.normalW);
        float3 shadingOrigin = computeRayOrigin(sd.posW, dot(sd.faceN, lightPos - sd.posW) >= 0 ? sd.faceN : -sd.faceN);
        float3 toLight = lightPos - shadingOrigin;
        float lightDistance = length(toLight);
        float3 L = normalize(toLight);

        const uint lobes = bsdf.getLobes(sd);
        const bool hasReflection = lobes & uint(LobeType::Reflection);
        const bool hasTransmission = lobes & uint(LobeType::Transmission);
        if (dot(L, sd.N) <= kMinCosTheta && !hasTransmission)
        {
            return 0.0f;
        }
        if (dot(L, sd.N) >= -kMinCosTheta && !hasReflection) 
        {
            return float3(0.f);
        }

        bool visible = traceShadowRay(shadingOrigin, L, lightDistance);
        if (!visible)
        {
            return float3(0.f);
        }

        return bsdf.eval(sd, L) * tls.Le / tls.pdf;
    }
    
    return 0.0f;
}

bool traceVisibilityRayCustomAS(float3 origin, float3 dir, RaytracingAccelerationStructure as)
{
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = dir;
    ray.TMin = 0.0f;
    ray.TMax = 1.0e38f;

    RayQuery<RAY_FLAG_NONE> rayQuery;
    rayQuery.TraceRayInline(as, RAY_FLAG_NONE, 0xff, ray);

    while(rayQuery.Proceed())
    {
        if(rayQuery.CandidateType() == CANDIDATE_PROCEDURAL_PRIMITIVE)
        {
            uint itemIndex = rayQuery.CandidatePrimitiveIndex();
            rayQuery.Abort();
            return true;
        }
    }

    return false;
}

float3 cosineWeightedSampling(float2 XY, float3 N, out float pdf)
{
    float3 w = N;
    float3 u = 0.0;
    if (abs(w.x) > 0.1)
    {
        u = normalize(cross(float3(0.0, 1.0, 0.0), w));
    }
    else
    {
        u = normalize(cross(float3(1.0, 0.0, 0.0), w));
    }
    float3 v = cross(w, u);
    float r1 = 2.0 * M_PI * XY.x;
    float r2 = XY.y;
    float r2s = sqrt(r2);
    float3 dir = normalize((u * cos(r1) * r2s + v * sin(r1) * r2s + w * sqrt(1.0 - r2)));

    pdf = dot(N, dir) / M_PI;

    return dir;
}

float3 cosineWeightedSampling(float2 XY, float3 N)
{
    float pdf;
    return cosineWeightedSampling(XY, N, pdf);
}

extension VisiblePoint
{
    ShadingData constructShadingData(ShadingDataLoader shadingDataLoader, bool isPrimary = false)
    {
        ITextureSampler lod = ExplicitLodTextureSampler(0.f);
        return shadingDataLoader.loadShadingData(HitInfo(hitInfo), rayOrigin, rayDir, isPrimary, lod);
    } 
}