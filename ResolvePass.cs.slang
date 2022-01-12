import Params;
#include "Utils/Math/MathConstants.slangh"
import Utils.Sampling.SampleGenerator;
import Scene.Scene;
import ShadingDataLoader;

struct ResolvePass
{
    PhotonMappingParams params; ///< Runtime parameters.
    RWTexture2D<float4> outputColor; ///< Output resolved color.

    /** Entry point for resolve pass.
        \param[in] pixel Pixel coordinates.
    */
    void execute(const uint2 pixel)
    {
        if (any(pixel >= params.frameDim))
        {
            return;
        }

        float3 color = float3(0.f);

        SampleGenerator sg = SampleGenerator(pixel, params.seed * 1);
        
        if (gShadingDataLoader.isPixelValid(pixel, params.frameDim))
        {
            ShadingData sd = gShadingDataLoader.loadShadingData(pixel, params.frameDim, gScene.camera);
            color = sd.posW;
        }
        
        outputColor[pixel] = float4(color, 1.0f);
    }
};

cbuffer CB
{
    ShadingDataLoader gShadingDataLoader;
    ResolvePass gResolvePass;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    gResolvePass.execute(dispatchThreadId.xy);
}
