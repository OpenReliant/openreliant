// Improvement: runtime compilation for mods' post effects (#621), for the variants of the device
// shader with mods' functions in them (#629), and for mods' replacements of OpenReliant's shaders,
// which this checks against OpenReliant's own (#630). Exceptions from the shader libraries stay
// here; Zig receives an owned result or an allocation failure.
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

// What a shader is compiled as: a mod's post effect, checked against the post effects' resources,
// or one of OpenReliant's own shaders, a mod's replacement for one or a variant of the device
// shader with mods' functions in it, whose resources are checked apart (`check_replacement`).
enum Kind { post_effect = 0, openreliant = 1 };

// The stage a shader is compiled for.
enum Stage { vertex = 0, fragment = 1 };

// Compiles the shader of `stage` made of `count` parts, each with its name for the messages, after
// `preamble`'s definitions.
extern "C" void *openreliant_compile_shader(int kind, int stage, int count, const char *const *names,
                                            const char *const *sources, const int *lengths,
                                            const char *preamble) noexcept {
    try {
        auto result = std::make_unique<Result>();
        try {
            require(kind == openreliant || stage == fragment, "post effects are fragment shaders");
            const EShLanguage language = stage == vertex ? EShLangVertex : EShLangFragment;
            // glslang's process lifetime is serialized, including failure and shutdown.
            static std::mutex mutex;
            const std::lock_guard<std::mutex> lock(mutex);
            require(glslang::InitializeProcess(), "glslang initialization failed");
            struct Process { ~Process() { glslang::FinalizeProcess(); } } process;
            glslang::TShader shader(language);
            shader.setStringsWithLengthsAndNames(sources, lengths, names, count);
            shader.setPreamble(preamble);
            shader.setEnvInput(glslang::EShSourceGlsl, language, glslang::EShClientVulkan, 450);
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
                    glslang::GlslangToSpv(*program.getIntermediate(language), result->spirv, &options);
                    spirv_cross::CompilerMSL compiler(result->spirv);
                    if (kind == post_effect) check(compiler);
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
            result->diagnostic = std::string(names[0]) + ": " + error.what();
        }
        return result.release();
    } catch (...) { return nullptr; }
}

// Where a resource is bound, as `set S, binding B`.
static std::string place(const spirv_cross::Compiler &compiler, const spirv_cross::Resource &resource) {
    return "set " + std::to_string(compiler.get_decoration(resource.id, spv::DecorationDescriptorSet)) +
           ", binding " + std::to_string(compiler.get_decoration(resource.id, spv::DecorationBinding));
}

static bool samePlace(const spirv_cross::Compiler &a, const spirv_cross::Resource &x,
                      const spirv_cross::Compiler &b, const spirv_cross::Resource &y) {
    return a.get_decoration(x.id, spv::DecorationDescriptorSet) == b.get_decoration(y.id, spv::DecorationDescriptorSet) &&
           a.get_decoration(x.id, spv::DecorationBinding) == b.get_decoration(y.id, spv::DecorationBinding);
}

// Whether two values of a stage's interface have the same type.
static bool sameArray(const spirv_cross::SPIRType &x, const spirv_cross::SPIRType &y) {
    if (x.array.size() != y.array.size()) return false;
    for (size_t i = 0; i < x.array.size(); ++i)
        if (x.array[i] != y.array[i]) return false;
    return true;
}

static bool sameValue(const spirv_cross::SPIRType &x, const spirv_cross::SPIRType &y) {
    return x.basetype == y.basetype && x.width == y.width && x.vecsize == y.vecsize && x.columns == y.columns &&
           sameArray(x, y);
}

// Whether two textures are read alike.
static bool sameImage(const spirv_cross::Compiler &a, const spirv_cross::SPIRType &x,
                      const spirv_cross::Compiler &b, const spirv_cross::SPIRType &y) {
    return x.image.dim == y.image.dim && x.image.arrayed == y.image.arrayed && x.image.depth == y.image.depth &&
           x.image.ms == y.image.ms && sameArray(x, y) &&
           a.get_type(x.image.type).basetype == b.get_type(y.image.type).basetype;
}

static const spirv_cross::Resource *located(const spirv_cross::Compiler &compiler,
                                            const spirv_cross::SmallVector<spirv_cross::Resource> &values, unsigned location) {
    for (const auto &value : values)
        if (compiler.get_decoration(value.id, spv::DecorationLocation) == location) return &value;
    return nullptr;
}

// Checks that `replacement` fits where OpenReliant draws `reference`: it uses only textures and
// uniform blocks the reference has, alike and no larger; it reads only the inputs the reference
// reads; it writes every output the reference writes, and a fragment shader no others; and it
// writes no built-in the reference doesn't.
static void checkReplacement(const spirv_cross::Compiler &reference, const spirv_cross::Compiler &replacement) {
    const auto wanted = reference.get_shader_resources();
    const auto given = replacement.get_shader_resources();
    require(given.storage_buffers.empty() && given.storage_images.empty() && given.subpass_inputs.empty() &&
            given.push_constant_buffers.empty() && given.atomic_counters.empty() && given.separate_images.empty() &&
            given.separate_samplers.empty() && given.acceleration_structures.empty() &&
            given.shader_record_buffers.empty() && given.gl_plain_uniforms.empty() && given.tensors.empty(),
            "it uses a kind of resource OpenReliant doesn't bind: only textures and uniform blocks");
    require(replacement.get_specialization_constants().empty(), "it uses specialization constants");
    for (const auto &texture : given.sampled_images) {
        const spirv_cross::Resource *match = nullptr;
        for (const auto &other : wanted.sampled_images)
            if (samePlace(replacement, texture, reference, other)) match = &other;
        if (!match) throw std::runtime_error("OpenReliant binds no texture at " + place(replacement, texture));
        if (!sameImage(replacement, replacement.get_type(texture.type_id), reference, reference.get_type(match->type_id)))
            throw std::runtime_error("the texture at " + place(replacement, texture) + " isn't of the type OpenReliant binds there");
    }
    for (const auto &block : given.uniform_buffers) {
        const spirv_cross::Resource *match = nullptr;
        for (const auto &other : wanted.uniform_buffers)
            if (samePlace(replacement, block, reference, other)) match = &other;
        if (!match) throw std::runtime_error("OpenReliant binds no uniform block at " + place(replacement, block));
        const auto size = replacement.get_declared_struct_size(replacement.get_type(block.base_type_id));
        const auto room = reference.get_declared_struct_size(reference.get_type(match->base_type_id));
        if (size > room)
            throw std::runtime_error("the uniform block at " + place(replacement, block) + " is " + std::to_string(size) +
                                     " bytes, more than the " + std::to_string(room) + " OpenReliant fills");
    }
    for (const auto &input : given.stage_inputs) {
        const auto location = replacement.get_decoration(input.id, spv::DecorationLocation);
        const auto *match = located(reference, wanted.stage_inputs, location);
        if (!match || !sameValue(replacement.get_type(input.type_id), reference.get_type(match->type_id)))
            throw std::runtime_error("OpenReliant gives no input of its type at location " + std::to_string(location));
    }
    for (const auto &output : wanted.stage_outputs) {
        const auto location = reference.get_decoration(output.id, spv::DecorationLocation);
        const auto *match = located(replacement, given.stage_outputs, location);
        if (!match || !sameValue(reference.get_type(output.type_id), replacement.get_type(match->type_id)))
            throw std::runtime_error("it doesn't write the output at location " + std::to_string(location) + " as OpenReliant's does");
    }
    if (replacement.get_execution_model() == spv::ExecutionModelFragment) {
        for (const auto &output : given.stage_outputs) {
            const auto location = replacement.get_decoration(output.id, spv::DecorationLocation);
            if (!located(reference, wanted.stage_outputs, location))
                throw std::runtime_error("OpenReliant draws into nothing at output location " + std::to_string(location));
        }
    }
    for (const auto &builtin : given.builtin_outputs) {
        bool known = false;
        for (const auto &other : wanted.builtin_outputs) known = known || other.builtin == builtin.builtin;
        require(known, "it writes a built-in output OpenReliant's doesn't");
    }
}

// Checks that the fragment stage reads only what the vertex stage writes, of the same type.
static void checkLink(const spirv_cross::Compiler &vertex, const spirv_cross::Compiler &fragment) {
    const auto written = vertex.get_shader_resources().stage_outputs;
    for (const auto &input : fragment.get_shader_resources().stage_inputs) {
        const auto location = fragment.get_decoration(input.id, spv::DecorationLocation);
        const auto *match = located(vertex, written, location);
        if (!match || !sameValue(fragment.get_type(input.type_id), vertex.get_type(match->type_id)))
            throw std::runtime_error("the fragment stage reads location " + std::to_string(location) +
                                     ", which the vertex stage doesn't write alike");
    }
}

// Runs `checking` on compilers of the given SPIR-V, and gives its complaint, named `name`, as the
// result's diagnostic, which is empty where there is none.
template <typename Check>
static void *checked(const char *name, Check checking) noexcept {
    try {
        auto result = std::make_unique<Result>();
        try {
            checking();
        } catch (const std::bad_alloc &) {
            throw;
        } catch (const std::exception &error) {
            result->diagnostic = std::string(name) + ": " + error.what();
        }
        return result.release();
    } catch (...) { return nullptr; }
}

extern "C" void *openreliant_check_replacement(const char *name, const unsigned *reference, size_t reference_count,
                                               const unsigned *replacement, size_t replacement_count) noexcept {
    return checked(name, [&] {
        const spirv_cross::Compiler wanted(reference, reference_count);
        const spirv_cross::Compiler given(replacement, replacement_count);
        checkReplacement(wanted, given);
    });
}

extern "C" void *openreliant_check_link(const char *name, const unsigned *vertex, size_t vertex_count,
                                        const unsigned *fragment, size_t fragment_count) noexcept {
    return checked(name, [&] {
        const spirv_cross::Compiler written(vertex, vertex_count);
        const spirv_cross::Compiler read(fragment, fragment_count);
        checkLink(written, read);
    });
}

extern "C" const unsigned *openreliant_shader_spirv(const Result *result, size_t *count) noexcept {
    *count = result->spirv.size();
    return result->spirv.data();
}
extern "C" const char *openreliant_shader_metal(const Result *result) noexcept { return result->metal.c_str(); }
extern "C" const char *openreliant_shader_diagnostic(const Result *result) noexcept { return result->diagnostic.c_str(); }
extern "C" void openreliant_shader_free(Result *result) noexcept { delete result; }
