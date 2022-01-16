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

struct GenerateHitPointsPass
{
    PhotonMappingParams params;
    ShadingDataLoader shadingDataLoader;
    RWStructuredBuffer<HitPoint> hitPoints;

    void execute(const uint2 pixel)
    {
        if (any(pixel >= params.frameDim))
        {
            return;
        }

        if (!shadingDataLoader.isPixelValid(pixel, params.frameDim))
        {
            return;
        }

        ShadingData sd = shadingDataLoader.loadShadingData(pixel, params.frameDim, gScene.camera);
        HitPoint hitPoint = HitPoint();
        hitPoint.flux = float3(pixel.x / (float)params.frameDim.x, pixel.y / (float)params.frameDim.y, 0.0f);
        uint hitPointPointer = hitPointPixelPositionToPointer(pixel, params);
        hitPoints[hitPointPointer] = hitPoint;
    }
};

cbuffer CB
{
    GenerateHitPointsPass gGenerateHitPointsPass;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    gGenerateHitPointsPass.execute(dispatchThreadId.xy);
}
