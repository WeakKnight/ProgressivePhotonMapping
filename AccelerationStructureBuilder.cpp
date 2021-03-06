#include "stdafx.h"
#include "AccelerationStructureBuilder.h"
#include "Core/API/D3D12/FalcorD3D12.h"
#include "Core/Framework.h"

AccelerationStructureBuilder::SharedPtr AccelerationStructureBuilder::Create(Buffer::SharedPtr pBoundingBoxBuffer, uint boxCount)
{
    AccelerationStructureBuilder::SharedPtr result = AccelerationStructureBuilder::SharedPtr(new AccelerationStructureBuilder());
    result->m_BoundingBoxBuffer = pBoundingBoxBuffer;
    result->mBoxCount = boxCount;
    return result;
}

void AccelerationStructureBuilder::BuildAS(RenderContext* pContext, uint32_t rayTypeCount)
{
    mRebuildBlas = true;
    InitGeomDesc();
    BuildBlas(pContext);
    BuildTlas(pContext, rayTypeCount, true);
}

void AccelerationStructureBuilder::SetRaytracingShaderData(const ShaderVar& var, const std::string name, uint32_t rayTypeCount)
{
    auto tlasIt = mTlasCache.find(rayTypeCount);
    var[name].setSrv(tlasIt->second.pSrv);
}

void AccelerationStructureBuilder::InitGeomDesc()
{
    mBlasData.resize(1);

    auto& blas = mBlasData[0];
    auto& geomDescs = blas.geomDescs;
    geomDescs.resize(1);

    {
        /*
        Use PrimitiveIndex() To Get AABB ID
        PrimitiveIndex
        The autogenerated index of the primitive within the geometry inside the bottom-level acceleration structure instance.

        uint PrimitiveIndex();
        For D3D12_RAYTRACING_GEOMETRY_TYPE_TRIANGLES, this is the triangle index within the geometry object.

        For D3D12_RAYTRACING_GEOMETRY_TYPE_PROCEDURAL_PRIMITIVE_AABBS, this is the index into the AABB array defining the geometry object.
        */
        D3D12_RAYTRACING_GEOMETRY_DESC& desc = geomDescs[0];
        desc.Type = D3D12_RAYTRACING_GEOMETRY_TYPE_PROCEDURAL_PRIMITIVE_AABBS;
        desc.Flags = D3D12_RAYTRACING_GEOMETRY_FLAG_OPAQUE;

        D3D12_RAYTRACING_GEOMETRY_AABBS_DESC AABBDesc = {};
        AABBDesc.AABBCount = mBoxCount;
        D3D12_GPU_VIRTUAL_ADDRESS_AND_STRIDE addressAndStride = {};
        AABBDesc.AABBs.StrideInBytes = 32;
        AABBDesc.AABBs.StartAddress = m_BoundingBoxBuffer->getGpuAddress();

        desc.AABBs = AABBDesc;
    }
}

void AccelerationStructureBuilder::BuildBlas(RenderContext* pContext)
{
    pContext->resourceBarrier(m_BoundingBoxBuffer.get(), Resource::State::NonPixelShader);

    // On the first time, or if a full rebuild is necessary we will:
    // - Update all build inputs and prebuild info
    // - Calculate total intermediate buffer sizes
    // - Build all BLASes into an intermediate buffer
    // - Calculate total compacted buffer size
    // - Compact/clone all BLASes to their final location
    if (mRebuildBlas)
    {
        uint64_t totalMaxBlasSize = 0;
        uint64_t totalScratchSize = 0;

        for (auto& blas : mBlasData)
        {
            // Setup build parameters.
            D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS& inputs = blas.buildInputs;
            inputs.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;
            inputs.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
            inputs.NumDescs = (uint32_t)blas.geomDescs.size();
            inputs.pGeometryDescs = blas.geomDescs.data();
            inputs.Flags = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_NONE;

            // Get prebuild info.
            FALCOR_GET_COM_INTERFACE(gpDevice->getApiHandle(), ID3D12Device5, pDevice5);
            pDevice5->GetRaytracingAccelerationStructurePrebuildInfo(&inputs, &blas.prebuildInfo);

            // Figure out the padded allocation sizes to have proper alignement.
            uint64_t paddedMaxBlasSize = align_to((uint64_t)D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT, blas.prebuildInfo.ResultDataMaxSizeInBytes);
            blas.blasByteOffset = totalMaxBlasSize;
            totalMaxBlasSize += paddedMaxBlasSize;

            uint64_t scratchSize = std::max(blas.prebuildInfo.ScratchDataSizeInBytes, blas.prebuildInfo.UpdateScratchDataSizeInBytes);
            uint64_t paddedScratchSize = align_to((uint64_t)D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT, scratchSize);
            blas.scratchByteOffset = totalScratchSize;
            totalScratchSize += paddedScratchSize;
        }

        // Allocate intermediate buffers and scratch buffer.
        // The scratch buffer we'll retain because it's needed for subsequent rebuilds and updates.
        // TODO: Save memory by reducing the scratch buffer to the minimum required for the dynamic objects.
        if (mpBlasScratch == nullptr || mpBlasScratch->getSize() < totalScratchSize)
        {
            mpBlasScratch = Buffer::create(totalScratchSize, Buffer::BindFlags::UnorderedAccess, Buffer::CpuAccess::None);
        }
        else
        {
            // If we didn't need to reallocate, just insert a barrier so it's safe to use.
            pContext->uavBarrier(mpBlasScratch.get());
        }

        Buffer::SharedPtr pDestBuffer = Buffer::create(totalMaxBlasSize, Buffer::BindFlags::AccelerationStructure, Buffer::CpuAccess::None);

        const size_t postBuildInfoSize = sizeof(D3D12_RAYTRACING_ACCELERATION_STRUCTURE_POSTBUILD_INFO_COMPACTED_SIZE_DESC);
        static_assert(postBuildInfoSize == sizeof(D3D12_RAYTRACING_ACCELERATION_STRUCTURE_POSTBUILD_INFO_CURRENT_SIZE_DESC));

        size_t totalPostBuildInfoSize = mBlasData.size() * postBuildInfoSize;

        Buffer::SharedPtr pPostbuildInfoBuffer = Buffer::create(totalPostBuildInfoSize, ResourceBindFlags::UnorderedAccess, Buffer::CpuAccess::None);
        Buffer::SharedPtr pPostbuildInfoStagingBuffer = Buffer::create(totalPostBuildInfoSize, Buffer::BindFlags::None, Buffer::CpuAccess::Read);

        // Build the BLASes into the intermediate destination buffer.
        // We output postbuild info to a separate buffer to find out the final size requirements.
        assert(pDestBuffer && pPostbuildInfoBuffer && mpBlasScratch);
        uint64_t postBuildInfoOffset = 0;

        for (const auto& blas : mBlasData)
        {
            D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC asDesc = {};
            asDesc.Inputs = blas.buildInputs;
            asDesc.ScratchAccelerationStructureData = mpBlasScratch->getGpuAddress() + blas.scratchByteOffset;
            asDesc.DestAccelerationStructureData = pDestBuffer->getGpuAddress() + blas.blasByteOffset;

            // Need to find out the the postbuild compacted BLAS size to know the final allocation size.
            D3D12_RAYTRACING_ACCELERATION_STRUCTURE_POSTBUILD_INFO_DESC postbuildInfoDesc = {};
            postbuildInfoDesc.InfoType = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_POSTBUILD_INFO_CURRENT_SIZE;
            postbuildInfoDesc.DestBuffer = pPostbuildInfoBuffer->getGpuAddress() + postBuildInfoOffset;
            postBuildInfoOffset += postBuildInfoSize;

            FALCOR_GET_COM_INTERFACE(pContext->getLowLevelData()->getCommandList(), ID3D12GraphicsCommandList4, pList4);
            pList4->BuildRaytracingAccelerationStructure(&asDesc, 1, &postbuildInfoDesc);
        }

        mpBlasScratch.reset();
        // TODO Remove This Flush
        pContext->flush(true);
        pContext->copyResource(pPostbuildInfoStagingBuffer.get(), pPostbuildInfoBuffer.get());
        pContext->flush(true);

        // Read back the calculated final size requirements for each BLAS.
        // For this purpose we have to flush and map the postbuild info buffer for readback.
        // TODO: We could copy to a staging buffer first and wait on a GPU fence for when it's ready.
        // But there is no other work to do inbetween so it probably wouldn't help. This is only done once at startup anyway.
        const D3D12_RAYTRACING_ACCELERATION_STRUCTURE_POSTBUILD_INFO_COMPACTED_SIZE_DESC* postBuildInfo =
            (const D3D12_RAYTRACING_ACCELERATION_STRUCTURE_POSTBUILD_INFO_COMPACTED_SIZE_DESC*)pPostbuildInfoStagingBuffer->map(Buffer::MapType::Read);

        uint64_t totalBlasSize = 0;
        for (size_t i = 0; i < mBlasData.size(); i++)
        {
            auto& blas = mBlasData[i];
            blas.blasByteSize = postBuildInfo[i].CompactedSizeInBytes;
            assert(blas.blasByteSize <= blas.prebuildInfo.ResultDataMaxSizeInBytes);
            uint64_t paddedBlasSize = align_to((uint64_t)D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT, blas.blasByteSize);
            totalBlasSize += paddedBlasSize;
        }
        pPostbuildInfoStagingBuffer->unmap();

        // Allocate final BLAS buffer.
        if (mpBlas == nullptr || mpBlas->getSize() < totalBlasSize)
        {
            mpBlas = Buffer::create(totalBlasSize, Buffer::BindFlags::AccelerationStructure, Buffer::CpuAccess::None);
        }
        else
        {
            // If we didn't need to reallocate, just insert a barrier so it's safe to use.
            pContext->uavBarrier(mpBlas.get());
        }

        // Insert barriers for the intermediate buffer. This is probably not necessary since we flushed above, but it's not going to hurt.
        pContext->uavBarrier(pDestBuffer.get());

        // Compact/clone all BLASes to their final location.
        uint64_t blasOffset = 0;
        for (auto& blas : mBlasData)
        {
            FALCOR_GET_COM_INTERFACE(pContext->getLowLevelData()->getCommandList(), ID3D12GraphicsCommandList4, pList4);
            pList4->CopyRaytracingAccelerationStructure(
                mpBlas->getGpuAddress() + blasOffset,
                pDestBuffer->getGpuAddress() + blas.blasByteOffset,
                D3D12_RAYTRACING_ACCELERATION_STRUCTURE_COPY_MODE_CLONE);

            uint64_t paddedBlasSize = align_to((uint64_t)D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BYTE_ALIGNMENT, blas.blasByteSize);
            blas.blasByteOffset = blasOffset;
            blasOffset += paddedBlasSize;
        }
        assert(blasOffset == totalBlasSize);

        // Insert barrier. The BLAS buffer is now ready for use.
        pContext->uavBarrier(mpBlas.get());

        // UpdateRaytracingStats();
        mRebuildBlas = false;

        return;
    }

    // If we get here, all BLASes have previously been built and compacted. We will:
    // - Early out if there are no animated meshes.
    // - Update or rebuild in-place the ones that are animated.
    assert(!mRebuildBlas);
    return;
}

void AccelerationStructureBuilder::FillInstanceDesc(std::vector<D3D12_RAYTRACING_INSTANCE_DESC>& instanceDescs, uint32_t rayCount, bool perMeshHitEntry)
{
    assert(mpBlas);
    instanceDescs.clear();
    uint32_t instanceContributionToHitGroupIndex = 0;
    uint32_t instanceId = 0;

    for (size_t i = 0; i < mBlasData.size(); i++)
    {
        D3D12_RAYTRACING_INSTANCE_DESC desc = {};
        desc.AccelerationStructure = mpBlas->getGpuAddress() + mBlasData[i].blasByteOffset;
        desc.InstanceMask = 0xFF;
        desc.InstanceContributionToHitGroupIndex = perMeshHitEntry ? instanceContributionToHitGroupIndex : 0;
        instanceContributionToHitGroupIndex += rayCount;
        desc.InstanceID = 0;
        glm::mat4 transform4x4 = glm::mat4(1.0f);
        std::memcpy(desc.Transform, &transform4x4, sizeof(desc.Transform));
        instanceDescs.push_back(desc);
    }
}

void AccelerationStructureBuilder::BuildTlas(RenderContext* pContext, uint32_t rayCount, bool perMeshHitEntry)
{
    TlasData tlas;
    auto it = mTlasCache.find(rayCount);
    if (it != mTlasCache.end()) tlas = it->second;

    FillInstanceDesc(mInstanceDescs, rayCount, perMeshHitEntry);

    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS inputs = {};
    inputs.Type = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL;
    inputs.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
    inputs.NumDescs = (uint32_t)mInstanceDescs.size();
    inputs.Flags = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_NONE;

    // On first build for the scene, create scratch buffer and cache prebuild info. As long as INSTANCE_DESC count doesn't change, we can reuse these
    if (mpTlasScratch == nullptr)
    {
        // Prebuild
        FALCOR_GET_COM_INTERFACE(gpDevice->getApiHandle(), ID3D12Device5, pDevice5);
        pDevice5->GetRaytracingAccelerationStructurePrebuildInfo(&inputs, &mTlasPrebuildInfo);
        mpTlasScratch = Buffer::create(mTlasPrebuildInfo.ScratchDataSizeInBytes, Buffer::BindFlags::UnorderedAccess, Buffer::CpuAccess::None);

        // #SCENE This isn't guaranteed according to the spec, and the scratch buffer being stored should be sized differently depending on update mode
        assert(mTlasPrebuildInfo.UpdateScratchDataSizeInBytes <= mTlasPrebuildInfo.ScratchDataSizeInBytes);
    }

    // Setup GPU buffers
    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC asDesc = {};
    asDesc.Inputs = inputs;

    // If first time building this TLAS
    if (tlas.pTlas == nullptr)
    {
        assert(tlas.pInstanceDescs == nullptr); // Instance desc should also be null if no TLAS
        tlas.pTlas = Buffer::create(mTlasPrebuildInfo.ResultDataMaxSizeInBytes, Buffer::BindFlags::AccelerationStructure, Buffer::CpuAccess::None);
        tlas.pInstanceDescs = Buffer::create((uint32_t)mInstanceDescs.size() * sizeof(D3D12_RAYTRACING_INSTANCE_DESC), Buffer::BindFlags::None, Buffer::CpuAccess::Write, mInstanceDescs.data());
    }
    //// Else update instance descs and barrier TLAS buffers
    else
    {
        //pContext->uavBarrier(tlas.pTlas.get());
        //pContext->uavBarrier(mpTlasScratch.get());
        tlas.pInstanceDescs->setBlob(mInstanceDescs.data(), 0, inputs.NumDescs * sizeof(D3D12_RAYTRACING_INSTANCE_DESC));

        // asDesc.Inputs.Flags = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PERFORM_UPDATE;
        // asDesc.SourceAccelerationStructureData = tlas.pTlas->getGpuAddress(); // Perform the update in-place
    }

    assert((inputs.NumDescs != 0) && tlas.pInstanceDescs->getApiHandle() && tlas.pTlas->getApiHandle() && mpTlasScratch->getApiHandle());

    asDesc.Inputs.InstanceDescs = tlas.pInstanceDescs->getGpuAddress();
    asDesc.ScratchAccelerationStructureData = mpTlasScratch->getGpuAddress();
    asDesc.DestAccelerationStructureData = tlas.pTlas->getGpuAddress();

    // Set the source buffer to update in place if this is an update
    // if ((inputs.Flags & D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PERFORM_UPDATE) > 0) asDesc.SourceAccelerationStructureData = asDesc.DestAccelerationStructureData;

    // Create TLAS
    FALCOR_GET_COM_INTERFACE(pContext->getLowLevelData()->getCommandList(), ID3D12GraphicsCommandList4, pList4);
    pContext->resourceBarrier(tlas.pInstanceDescs.get(), Resource::State::NonPixelShader);
    pList4->BuildRaytracingAccelerationStructure(&asDesc, 0, nullptr);
    pContext->uavBarrier(tlas.pTlas.get());

    // Create TLAS SRV
    if (tlas.pSrv == nullptr)
    {
        tlas.pSrv = ShaderResourceView::createViewForAccelerationStructure(tlas.pTlas);
    }

    mTlasCache[rayCount] = tlas;
}

