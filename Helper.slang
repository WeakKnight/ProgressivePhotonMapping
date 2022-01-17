#pragma once
__exported import Types;
#include "Utils/Math/MathConstants.slangh"
__exported import Utils.Sampling.SampleGenerator;
__exported import Utils.Geometry.GeometryHelpers;
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

#define ATOMIC_ADD_FLOAT(Value, Increment) \
{ \
	uint NewValue = asuint(Increment); \
	uint CompareValue = 0; \
	uint OldValue; \
	[allow_uav_condition] \
	while (true) \
	{ \
		InterlockedCompareExchange(Value, CompareValue, NewValue, OldValue); \
		if (OldValue == CompareValue) \
			break; \
		CompareValue = OldValue; \
		NewValue = asuint(Increment + asfloat(OldValue)); \
	} \
}
