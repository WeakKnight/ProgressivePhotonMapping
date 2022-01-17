import Helper;

struct GenerateVisiblePointsPass
{
    PhotonMappingParams params;
    ShadingDataLoader shadingDataLoader;
    EnvMapSampler envMapSampler;
    EmissiveLightSampler emissiveSampler;
    RWStructuredBuffer<VisiblePoint> visiblePoints;
    RWStructuredBuffer<PackedBoundingBox> visiblePointsBoundingBoxBuffer;
    RWTexture2D<float4> outputColor;
    
    void execute(const uint2 pixel)
    {
        if (any(pixel >= params.frameDim))
        {
            return;
        }

        SampleGenerator sg = SampleGenerator(pixel, params.seed);

        VisiblePoint visiblePoint = VisiblePoint();
        PackedBoundingBox visiblePointBoundingBox = PackedBoundingBox();
        float3 color = 0.0f;

        if (shadingDataLoader.isPixelValid(pixel, params.frameDim))
        {
            ITextureSampler lod = ExplicitLodTextureSampler(0.f);
            
            Ray ray = shadingDataLoader.getPrimaryRay(pixel, params.frameDim, gScene.camera);
            visiblePoint.hitInfo = shadingDataLoader.loadHitInfo(pixel).getData();
            visiblePoint.wi = -ray.dir;
            for (uint i = 0; i < 10; i++)
            {
                // Update Current Shading Data And BSDF
                ShadingData sd = shadingDataLoader.loadShadingData(HitInfo(visiblePoint.hitInfo), ray.origin, ray.dir, i == 0, lod);
                IBSDF bsdf = gScene.materials.getBSDF(sd, lod);

                BSDFSample bsdfSample;
                if (!bsdf.sample(sd, sg, bsdfSample))
                {
                    break;
                }

                if (bsdfSample.isLobe(LobeType::Diffuse))
                {
                    visiblePoint.valid = 1u;
                    visiblePointBoundingBox = PackedBoundingBox(sd.posW, visiblePoint.radius);
                    break;
                }

                color += (visiblePoint.weight * evalEmissiveLighting(sd, sg, emissiveSampler));

                visiblePoint.weight *= bsdfSample.weight;
                visiblePoint.wi = -bsdfSample.wo;
                // Continue Tracing
                ray.origin = sd.posW;
                ray.dir = bsdfSample.wo;
                HitInfo hit;
                float hitT;
                if (!traceSceneRay<1>(ray, hit, hitT, RAY_FLAG_NONE, 0xff))
                {
                    break;
                }
                visiblePoint.hitInfo = hit.getData();
            }
        }

        uint visiblePointPointer = visiblePointPositionToPointer(pixel, params);
        visiblePoints[visiblePointPointer] = visiblePoint;
        visiblePointsBoundingBoxBuffer[visiblePointPointer] = visiblePointBoundingBox;
        outputColor[pixel] = float4(color, 1.0f);
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
