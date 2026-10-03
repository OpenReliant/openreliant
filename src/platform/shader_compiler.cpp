// Improvement: runtime compilation for mod post effects (#621). Exceptions from the shader
// libraries stay here; Zig receives an owned result or an allocation failure.
#include <glslang/Public/ShaderLang.h>
#include <glslang/Public/ResourceLimits.h>
#include <SPIRV/GlslangToSpv.h>
#include <spirv-cross/spirv_msl.hpp>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

struct Result {
    std::vector<unsigned> spirv;
    std::string metal;
    std::string diagnostic;
};

static constexpr unsigned texture_set = 2;
static constexpr unsigned uniform_set = 3;
static constexpr unsigned texture_slots = 2;
static constexpr unsigned vector_bytes = 16;
static constexpr unsigned uniform_vectors = 2;

static void require(bool valid, const char *message) {
    if (!valid) throw std::runtime_error(message);
}

static void vectorType(spirv_cross::CompilerMSL &compiler, const spirv_cross::Resource &resource,
                       unsigned width) {
    const auto &type = compiler.get_type(resource.type_id);
    require(type.basetype == spirv_cross::SPIRType::Float && type.width == 32 &&
            type.vecsize == width && type.columns == 1 && type.array.empty(),
            "post-effect interface has the wrong vector type");
    require(compiler.has_decoration(resource.id, spv::DecorationLocation) &&
            compiler.get_decoration(resource.id, spv::DecorationLocation) == 0 &&
            !compiler.has_decoration(resource.id, spv::DecorationComponent) &&
            !compiler.has_decoration(resource.id, spv::DecorationIndex),
            "post-effect input and output must use location 0");
}

static void check(spirv_cross::CompilerMSL &compiler) {
    const auto resources = compiler.get_shader_resources();
    require(resources.storage_buffers.empty() && resources.storage_images.empty() &&
            resources.subpass_inputs.empty() && resources.push_constant_buffers.empty() &&
            resources.atomic_counters.empty() && resources.separate_images.empty() &&
            resources.separate_samplers.empty() && resources.acceleration_structures.empty() &&
            resources.shader_record_buffers.empty() && resources.gl_plain_uniforms.empty() &&
            resources.tensors.empty(),
            "post effects only support combined textures and one uniform block");
    require(compiler.get_specialization_constants().empty(), "post effects do not support specialization constants");
    require(resources.stage_inputs.size() == 1 && resources.stage_outputs.size() == 1,
            "post effects need one vec2 input and one vec4 output");
    vectorType(compiler, resources.stage_inputs[0], 2);
    vectorType(compiler, resources.stage_outputs[0], 4);
    require(resources.builtin_outputs.empty(), "post effects cannot write built-in outputs");
    for (const auto &resource : resources.builtin_inputs)
        require(resource.builtin == spv::BuiltInFragCoord, "post effects only support gl_FragCoord as a built-in input");
    require(resources.sampled_images.size() <= texture_slots && resources.uniform_buffers.size() <= 1,
            "post effects support at most two textures and one uniform block");
    bool occupied[texture_slots] = {};
    for (const auto &resource : resources.sampled_images) {
        const auto &type = compiler.get_type(resource.type_id);
        const auto binding = compiler.get_decoration(resource.id, spv::DecorationBinding);
        require(compiler.has_decoration(resource.id, spv::DecorationDescriptorSet) &&
                compiler.has_decoration(resource.id, spv::DecorationBinding) &&
                compiler.get_decoration(resource.id, spv::DecorationDescriptorSet) == texture_set &&
                binding < texture_slots &&
                type.array.empty() && type.image.dim == spv::Dim2D && !type.image.arrayed &&
                !type.image.ms && !type.image.depth &&
                compiler.get_type(type.image.type).basetype == spirv_cross::SPIRType::Float,
                "post-effect textures must be float sampler2D at set 2, binding 0 or 1");
        require(!occupied[binding], "post-effect texture bindings must be unique");
        occupied[binding] = true;
    }
    for (const auto &resource : resources.uniform_buffers) {
        const auto &type = compiler.get_type(resource.base_type_id);
        require(compiler.has_decoration(resource.id, spv::DecorationDescriptorSet) &&
                compiler.has_decoration(resource.id, spv::DecorationBinding) &&
                compiler.get_decoration(resource.id, spv::DecorationDescriptorSet) == uniform_set &&
                compiler.get_decoration(resource.id, spv::DecorationBinding) == 0 &&
                compiler.get_type(resource.type_id).array.empty() && type.member_types.size() == uniform_vectors &&
                compiler.get_declared_struct_size(type) == uniform_vectors * vector_bytes,
                "post-effect uniforms must be two vec4 fields at set 3, binding 0");
        for (unsigned i = 0; i < uniform_vectors; ++i) {
            const auto &member = compiler.get_type(type.member_types[i]);
            require(member.basetype == spirv_cross::SPIRType::Float && member.width == 32 &&
                    member.vecsize == 4 && member.columns == 1 && member.array.empty() &&
                    compiler.type_struct_member_offset(type, i) == i * vector_bytes,
                    "post-effect uniforms must use the two-vec4 std140 layout");
        }
    }
}

extern "C" void *openreliant_compile_post_effect(const char *name, const char *source, int length) noexcept {
    try {
        auto result = std::make_unique<Result>();
        try {
            // glslang's process lifetime is serialized, including failure and shutdown.
            static std::mutex mutex;
            const std::lock_guard<std::mutex> lock(mutex);
            require(glslang::InitializeProcess(), "glslang initialization failed");
            struct Process { ~Process() { glslang::FinalizeProcess(); } } process;
            glslang::TShader shader(EShLangFragment);
            shader.setStringsWithLengthsAndNames(&source, &length, &name, 1);
            shader.setEnvInput(glslang::EShSourceGlsl, EShLangFragment, glslang::EShClientVulkan, 450);
            shader.setEnvClient(glslang::EShClientVulkan, glslang::EShTargetVulkan_1_0);
            shader.setEnvTarget(glslang::EShTargetSpv, glslang::EShTargetSpv_1_0);
            const auto messages = EShMessages(EShMsgSpvRules | EShMsgVulkanRules);
            if (!shader.parse(GetDefaultResources(), 450, false, messages)) {
                result->diagnostic = shader.getInfoLog();
            } else {
                glslang::TProgram program;
                program.addShader(&shader);
                if (!program.link(messages)) result->diagnostic = program.getInfoLog();
                else {
                    glslang::SpvOptions options;
                    options.disableOptimizer = true;
                    glslang::GlslangToSpv(*program.getIntermediate(EShLangFragment), result->spirv, &options);
                    spirv_cross::CompilerMSL compiler(result->spirv);
                    check(compiler);
                    auto metal_options = compiler.get_msl_options();
                    metal_options.set_msl_version(2, 2);
                    metal_options.enable_decoration_binding = true;
                    compiler.set_msl_options(metal_options);
                    result->metal = compiler.compile();
                }
            }
        } catch (const std::bad_alloc &) {
            throw;
        } catch (const std::exception &error) {
            result->diagnostic = std::string(name) + ": " + error.what();
        }
        return result.release();
    } catch (...) { return nullptr; }
}

extern "C" const unsigned *openreliant_shader_spirv(const Result *result, size_t *count) noexcept {
    *count = result->spirv.size();
    return result->spirv.data();
}
extern "C" const char *openreliant_shader_metal(const Result *result) noexcept { return result->metal.c_str(); }
extern "C" const char *openreliant_shader_diagnostic(const Result *result) noexcept { return result->diagnostic.c_str(); }
extern "C" void openreliant_shader_free(Result *result) noexcept { delete result; }
