#include "Utils/Math/MathConstants.slangh"
import Helper;

struct ReduceRadiusPass
{
    void execute(const uint2 pixel)
    {

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
