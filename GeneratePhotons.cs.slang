#include "Utils/Math/MathConstants.slangh"
import Helper;

#define ATOMIC_ADD_FLOAT(Buffer, Address, Increment) \
{ \
	uint NewValue = asuint(Increment); \
	uint CompareValue = 0; \
	uint OldValue; \
	[allow_uav_condition] \
	while (true) \
	{ \
		Buffer.InterlockedCompareExchange(Address, CompareValue, NewValue, OldValue); \
		if (OldValue == CompareValue) \
			break; \
		CompareValue = OldValue; \
		NewValue = asuint(Increment + asfloat(OldValue)); \
	} \
}

struct GeneratePhotonsPass
{
    PhotonMappingParams params;
    ShadingDataLoader shadingDataLoader;
    
    StructuredBuffer<VisiblePoint> visiblePoints;
    RWByteAddressBuffer visiblePointDensityContexts;
    RaytracingAccelerationStructure visiblePointsAS;
    AliasTable emissiveTable;

    void atomicAddFlux(uint pointer, float3 flux)
    {
        const uint typeSize = 2 * 16;
        const uint base = typeSize * pointer;

        ATOMIC_ADD_FLOAT(visiblePointDensityContexts, base + 0, flux.r);
        ATOMIC_ADD_FLOAT(visiblePointDensityContexts, base + 4, flux.g);
        ATOMIC_ADD_FLOAT(visiblePointDensityContexts, base + 8, flux.b);
        visiblePointDensityContexts.InterlockedAdd(base + 16, 1);
    }

    void execute(const uint photonIndex)
    {
        if (any(photonIndex >= params.photonCount))
        {
            return;
        }

        ITextureSampler lod = ExplicitLodTextureSampler(0.f);
        SampleGenerator sg = SampleGenerator(uint2(photonIndex, 1), params.seed);

        uint triIndex = emissiveTable.sample(sampleNext2D(sg));
        float triPdf = emissiveTable.getWeight(triIndex) / emissiveTable.weightSum;

        EmissiveTriangle emissiveTri = gScene.lightCollection.getTriangle(triIndex);
        float samplePdf = triPdf / emissiveTri.area;
        float3 barycentric = sample_triangle(sampleNext2D(sg));
        float3 samplePos = emissiveTri.getPosition(barycentric);
        float2 sampleUV = emissiveTri.getTexCoord(barycentric);
        float3 flux = gScene.materials.evalEmissive(emissiveTri.materialID, sampleUV);
        flux = flux * M_PI / samplePdf;

        Ray ray = Ray(computeRayOrigin(samplePos, emissiveTri.normal), cosineWeightedSampling(sampleNext2D(sg), emissiveTri.normal));

        for (uint i = 0; i < 10; i++)
        {
            HitInfo hit;
            float hitT;
            if (!traceSceneRay<1>(ray, hit, hitT, RAY_FLAG_NONE, 0xff))
            {
                break;
            }

            ShadingData sd = shadingDataLoader.loadShadingData(hit, ray.origin, ray.dir, false, lod);
            IBSDF bsdf = gScene.materials.getBSDF(sd, lod);

            RayDesc searchRay;
            searchRay.Origin = sd.posW;
            searchRay.Direction = float3(0.0f, 1.0f, 0.0f);
            searchRay.TMin = 0.0f;
            searchRay.TMax = 0.0f;
            RayQuery<RAY_FLAG_NONE> rayQuery;
            rayQuery.TraceRayInline(visiblePointsAS, RAY_FLAG_NONE, 0xff, searchRay);
            while(rayQuery.Proceed())
            {
                if(rayQuery.CandidateType() == CANDIDATE_PROCEDURAL_PRIMITIVE)
                {
                    uint pointer = rayQuery.CandidatePrimitiveIndex();
                    VisiblePoint visiblePoint = visiblePoints[pointer];
                    VisiblePointDensityContext visiblePointDensityContext = VisiblePointDensityContext(visiblePointDensityContexts, pointer);
                    ShadingData sdVisiblePoint = visiblePoint.constructShadingData(shadingDataLoader);
                    float3 visiblePointToPhoton = sd.posW - sdVisiblePoint.posW;
                    if (dot(visiblePointToPhoton, visiblePointToPhoton) < (visiblePointDensityContext.radius * visiblePointDensityContext.radius))
                    {
                        IBSDF bsdfVisiblePoint = gScene.materials.getBSDF(sdVisiblePoint, lod);
                        // Consider Refraction Lobe
                        float geomTerm = (visiblePoint.lobe & uint(LobeType::Transmission) != 0)? dot(sdVisiblePoint.N, -ray.dir): dot(-sdVisiblePoint.N, -ray.dir);
                        atomicAddFlux(pointer, flux * saturate(geomTerm));
                    }
                }
            }

            BSDFSample bsdfSample;
            if (!bsdf.sample(sd, sg, bsdfSample))
            {
                break;
            }

            float3 newFlux = flux * bsdfSample.weight;
            float continuationProb = sqrt(saturate(max(newFlux.x, max(newFlux.y, newFlux.z)) / max(flux.x, max(flux.y, flux.z))));
            if (continuationProb < 1)
            {
                if (sampleNext1D(sg) >= continuationProb)
                {
                    break;
                }
                flux = newFlux / continuationProb;
            }
            else
            {
                flux = newFlux;
            }
            
            ray.origin = sd.computeNewRayOrigin(!bsdfSample.isLobe(LobeType::Transmission));
            ray.dir = bsdfSample.wo;   
        }
    }
};

cbuffer CB
{
    GeneratePhotonsPass gGeneratePhotonsPass;
}

[numthreads(256, 1, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    gGeneratePhotonsPass.execute(dispatchThreadId.x);
}
