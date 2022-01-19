#include "Utils/Math/MathConstants.slangh"
import Helper;

struct ResolvePass
{
    PhotonMappingParams params;
    RWTexture2D<float4> outputColor;

    ShadingDataLoader shadingDataLoader;
    EnvMapSampler envMapSampler;
    EmissiveLightSampler emissiveSampler;

    RWStructuredBuffer<VisiblePoint> visiblePoints;
    RaytracingAccelerationStructure visiblePointsAS;

    void execute(const uint2 pixel)
    {
        if (any(pixel >= params.frameDim))
        {
            return;
        }

        ITextureSampler lod = ExplicitLodTextureSampler(0.f);
        float3 color = outputColor[pixel].xyz;

        SampleGenerator sg = SampleGenerator(pixel, params.seed);
        
        if (shadingDataLoader.isPixelValid(pixel, params.frameDim))
        {
            ShadingData sd = shadingDataLoader.loadShadingData(pixel, params.frameDim, gScene.camera);
            IBSDF bsdf = gScene.materials.getBSDF(sd, lod);
            color += bsdf.getProperties(sd).emissive;
        }

        uint visiblePointPointer = visiblePointPositionToPointer(pixel, params);
        VisiblePoint visiblePoint = visiblePoints[visiblePointPointer];

        if (visiblePoint.isValid())
        {
            ShadingData sdVisiblePoint = visiblePoint.constructShadingData(shadingDataLoader);
            IBSDF bsdfVisiblePoint = gScene.materials.getBSDF(sdVisiblePoint, lod);
            color += visiblePoint.weight * visiblePoint.flux / params.photonCount / (M_PI * visiblePoint.radius * visiblePoint.radius);
        }

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
