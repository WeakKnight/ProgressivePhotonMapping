/***************************************************************************
 # Copyright (c) 2015-21, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/
#include "ProgressivePhotonMapping.h"
#include "ShadingDataLoader.h"
#include "Params.slang"

const RenderPass::Info ProgressivePhotonMapping::kInfo { "ProgressivePhotonMapping", "Insert pass description here." };

const std::string kResolvePassFile = "RenderPasses/ProgressivePhotonMapping/ResolvePass.cs.slang";
const std::string kShaderModel = "6_5";

const ChannelList kInputChannels =
{
    { "vbuffer",    "",     "Visibility buffer in packed format",   false, HitInfo::kDefaultFormat },
};

const ChannelList kOutputChannels =
{
    { "color",      "",     "Output color", false, ResourceFormat::RGBA32Float},
};

// Don't remove this. it's required for hot-reload to function properly
extern "C" FALCOR_API_EXPORT const char* getProjDir()
{
    return PROJECT_DIR;
}

extern "C" FALCOR_API_EXPORT void getPasses(Falcor::RenderPassLibrary& lib)
{
    lib.registerPass(ProgressivePhotonMapping::kInfo, ProgressivePhotonMapping::create);
}

ProgressivePhotonMapping::ProgressivePhotonMapping() : RenderPass(kInfo)
{
    mpSampleGenerator = SampleGenerator::create(SAMPLE_GENERATOR_TINY_UNIFORM);

    Program::DefineList defines;
    defines.add(mpSampleGenerator->getDefines());
    defines.add("_MS_DISABLE_ALPHA_TEST");
    defines.add("_DEFAULT_ALPHA_TEST");
    mpResolvePass = ComputePass::create(Program::Desc(kResolvePassFile).setShaderModel(kShaderModel).csEntry("main"), defines, false);
}

ProgressivePhotonMapping::SharedPtr ProgressivePhotonMapping::create(RenderContext* pRenderContext, const Dictionary& dict)
{
    SharedPtr pPass = SharedPtr(new ProgressivePhotonMapping());
    for (const auto& [key, value] : dict)
    {
        logWarning("Unknown field '" + key + "' in a ProgressivePhotonMapping dictionary");
    }
    return pPass;
}

Dictionary ProgressivePhotonMapping::getScriptingDictionary()
{
    Dictionary dict;
    return dict;
}

RenderPassReflection ProgressivePhotonMapping::reflect(const CompileData& compileData)
{
    RenderPassReflection reflector;
    addRenderPassInputs(reflector, kInputChannels);
    addRenderPassOutputs(reflector, kOutputChannels);
    return reflector;
}

void ProgressivePhotonMapping::execute(RenderContext* pRenderContext, const RenderData& renderData)
{
    if (mpScene == nullptr)
    {
        return;
    }

    resolve(pRenderContext, renderData);
}

void ProgressivePhotonMapping::renderUI(Gui::Widgets& widget)
{
}

void ProgressivePhotonMapping::setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene)
{
    mpScene = pScene;

    Shader::DefineList defines = mpScene->getSceneDefines();
    Program::TypeConformanceList typeConformances = mpScene->getTypeConformances();

    auto prepareProgram = [&](Program::SharedPtr program)
    {
        program->addDefines(defines);
        program->setTypeConformances(typeConformances);
    };

    prepareProgram(mpResolvePass->getProgram());
    mpResolvePass->setVars(nullptr);
}

void ProgressivePhotonMapping::resolve(RenderContext* pRenderContext, const RenderData& renderData)
{
    PROFILE("Resolve");

    auto cb = mpResolvePass["CB"];
    cb["gResolvePass"]["params"]["frameDim"] = uint2(gpFramework->getTargetFbo()->getWidth(), gpFramework->getTargetFbo()->getHeight());
    cb["gResolvePass"]["params"]["frameCount"] = (uint)gpFramework->getGlobalClock().getFrame();
    cb["gResolvePass"]["params"]["seed"] = (uint)gpFramework->getGlobalClock().getFrame();
    cb["gResolvePass"]["outputColor"] = renderData[kOutputChannels[0].name]->asTexture();
    ShadingDataLoader::setShaderData(renderData, cb["gShadingDataLoader"]);

    mpSampleGenerator->setShaderData(mpResolvePass->getRootVar());
    mpScene->setRaytracingShaderData(pRenderContext, mpResolvePass->getRootVar());

    mpResolvePass->execute(pRenderContext, gpFramework->getTargetFbo()->getWidth(), gpFramework->getTargetFbo()->getHeight());
}
