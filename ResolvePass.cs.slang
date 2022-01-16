import Params;
#include "Utils/Math/MathConstants.slangh"
import Utils.Sampling.SampleGenerator;
import Utils.Geometry.GeometryHelpers;
import Scene.Scene;
import Scene.RaytracingInline;
import ShadingDataLoader;
import Rendering.Lights.EnvMapSampler;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;

bool traceShadowRay(float3 origin, float3 dir, float distance)
{
    Ray ray;
    ray.origin = origin;
    ray.dir = dir;
    ray.tMin = 0.0f;
    ray.tMax = distance;

    return traceSceneVisibilityRay<1>(ray, RAY_FLAG_NONE, 0xff);
}

struct ResolvePass
{
    PhotonMappingParams params;
    RWTexture2D<float4> outputColor;

    ShadingDataLoader shadingDataLoader;
    EnvMapSampler envMapSampler;
    EmissiveLightSampler emissiveSampler;

    StructuredBuffer<VisiblePoint> visiblePoints;

    float3 evalEmissiveLighting(ShadingData sd, inout SampleGenerator sg)
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

            bool V = traceShadowRay(shadingOrigin, L, lightDistance);
            if (!V) 
            {
                return float3(0.f);
            }

            return bsdf.eval(sd, L) * tls.Le / tls.pdf;
        }
        
        return 0.0f;
    }

    void execute(const uint2 pixel)
    {
        if (any(pixel >= params.frameDim))
        {
            return;
        }


        float3 color = float3(0.f);

        SampleGenerator sg = SampleGenerator(pixel, params.seed);
        
        if (shadingDataLoader.isPixelValid(pixel, params.frameDim))
        {
            ShadingData sd = shadingDataLoader.loadShadingData(pixel, params.frameDim, gScene.camera);
            ITextureSampler lod = ExplicitLodTextureSampler(0.f);
            IBSDF bsdf = gScene.materials.getBSDF(sd, lod);

            color = evalEmissiveLighting(sd, sg);
            color += bsdf.getProperties(sd).emissive;
        }

        uint visiblePointPointer = visiblePointPositionToPointer(pixel, params);
        VisiblePoint visiblePoint = visiblePoints[visiblePointPointer];
        color = visiblePoint.flux;
        outputColor[pixel] = float4(color, 1.0f);
    }
};

cbuffer CB
{
    ResolvePass gResolvePass;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    gResolvePass.execute(dispatchThreadId.xy);
}
