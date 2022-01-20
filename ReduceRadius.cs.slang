#include "Utils/Math/MathConstants.slangh"
import Helper;

struct ReduceRadiusPass
{
    PhotonMappingParams params;
    ShadingDataLoader shadingDataLoader;
    StructuredBuffer<VisiblePoint> visiblePoints;
    RWStructuredBuffer<VisiblePointDensityContext> visiblePointDensityContexts;
    RWStructuredBuffer<uint> visiblePointPhotonNumbers;

    void execute(const uint2 pixel)
    {
        if (any(pixel >= params.frameDim))
        {
            return;
        }

        uint visiblePointPointer = visiblePointPositionToPointer(pixel, params);
        VisiblePoint visiblePoint = visiblePoints[visiblePointPointer];
        VisiblePointDensityContext visiblePointDensityContext = visiblePointDensityContexts[visiblePointPointer];
        if (visiblePoint.isValid() && visiblePointDensityContext.n > 0)
        {
            uint n = visiblePointDensityContext.n;
            uint m = visiblePointPhotonNumbers[visiblePointPointer];

            float normalizationFactor = (float)(n + params.alpha * m) / (float)(n + m);
            // See PPM Paper Equation 9
            visiblePointDensityContexts[visiblePointPointer].radius = visiblePointDensityContext.radius * sqrt(normalizationFactor);
            // See PPM Paper Equation 12
            visiblePointDensityContexts[visiblePointPointer].flux = visiblePointDensityContext.flux * normalizationFactor;
            // Update n
            visiblePointDensityContexts[visiblePointPointer].n = n + params.alpha * m;
            // Clear Photon Number
            visiblePointPhotonNumbers[visiblePointPointer] = 0;
        }
    }
};

cbuffer CB
{
    ReduceRadiusPass gReduceRadiusPass;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    gReduceRadiusPass.execute(dispatchThreadId.xy);
}
