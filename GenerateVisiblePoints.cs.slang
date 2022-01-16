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

struct GenerateVisiblePointsPass
{
    PhotonMappingParams params;
    ShadingDataLoader shadingDataLoader;
    RWStructuredBuffer<VisiblePoint> visiblePoints;

    void execute(const uint2 pixel)
    {
        if (any(pixel >= params.frameDim))
        {
            return;
        }

        VisiblePoint visiblePoint = VisiblePoint();
        visiblePoint.flux = float3(pixel.x / (float)params.frameDim.x, pixel.y / (float)params.frameDim.y, 0.0f);

        if (shadingDataLoader.isPixelValid(pixel, params.frameDim))
        {
            ShadingData sd = shadingDataLoader.loadShadingData(pixel, params.frameDim, gScene.camera);
            ITextureSampler lod = ExplicitLodTextureSampler(0.f);
            IBSDF bsdf = gScene.materials.getBSDF(sd, lod);
        }

        uint visiblePointPointer = visiblePointPositionToPointer(pixel, params);
        visiblePoints[visiblePointPointer] = visiblePoint;
    }
};

cbuffer CB
{
    GenerateVisiblePointsPass gGenerateVisiblePointsPass;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    gGenerateVisiblePointsPass.execute(dispatchThreadId.xy);
}
