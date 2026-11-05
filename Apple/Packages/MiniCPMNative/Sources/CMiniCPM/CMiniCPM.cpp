#include "CMiniCPM.h"
#include <llama/llama.h>
#include <atomic>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct mcpm_cancellation { std::atomic<bool> cancelled{false}; };
struct mcpm_session {
    llama_model * model = nullptr;
    llama_context * context = nullptr;
    llama_sampler * sampler = nullptr;
    mcpm_cancellation * cancellation = nullptr; // Borrowed only between begin/end.
    int position = 0;
    int context_size = 0;
    std::string experts_path;
};
static std::once_flag backend_once;
static std::mutex model_load_mutex;
static void quiet_log(enum ggml_log_level, const char *, void *) {}
static bool aborted(void * opaque) {
    return opaque && static_cast<mcpm_cancellation *>(opaque)->cancelled.load();
}
static int fail(char ** error, const char * message) {
    if (error) *error = strdup(message);
    return -1;
}
extern "C" {
mcpm_cancellation * mcpm_cancellation_create(void) { return new mcpm_cancellation; }
void mcpm_cancellation_cancel(mcpm_cancellation * flag) { if (flag) flag->cancelled.store(true); }
void mcpm_cancellation_destroy(mcpm_cancellation * flag) { delete flag; }
void mcpm_string_free(void * value) { free(value); }
mcpm_session * mcpm_load(const char * path, const char * experts_path, int context_size,
                         int expert_cache_slots, int prefetch_depth, char ** error) {
    std::lock_guard<std::mutex> guard(model_load_mutex);
    std::call_once(backend_once, [] { llama_log_set(quiet_log, nullptr); llama_backend_init(); });
    auto session = new mcpm_session;
    auto model_params = llama_model_default_params();
    model_params.n_gpu_layers = 99;
    model_params.use_mmap = true;
    if (experts_path && *experts_path) {
        session->experts_path = experts_path;
        model_params.moe_experts_path = session->experts_path.c_str();
        // The original top-8 routing is preserved; this only bounds the SSD cache.
        model_params.moe_slot_bank = 256;
        const std::string slots = std::to_string(std::clamp(expert_cache_slots, 8, 96));
        const std::string depth = std::to_string(std::clamp(prefetch_depth, 0, 16));
        setenv("LLAMA_MOE_DECODE_WINDOW", slots.c_str(), 1);
        setenv("LLAMA_MOE_LOOKAHEAD_PREFETCH", prefetch_depth > 0 ? "1" : "0", 1);
        setenv("LLAMA_MOE_LOOKAHEAD_PREFETCH_DEPTH", depth.c_str(), 1);
        setenv("LLAMA_MOE_WINDOW_MAX_ROWS", "1", 1);
        setenv("LLAMA_MOE_NO_OWN_ALLOC", "0", 1);
        setenv("LLAMA_MOE_SKIP_READ", "0", 1);
        setenv("LLAMA_MOE_DUMMY_READ", "0", 1);
        unsetenv("LLAMA_MOE_PREWARM");
    }
    session->model = llama_model_load_from_file(path, model_params);
    if (!session->model) { delete session; fail(error, "无法载入面壁模型，请重新校验模型文件。"); return nullptr; }
    auto context_params = llama_context_default_params();
    context_params.n_ctx = std::clamp(context_size, 512, 4096);
    context_params.n_batch = 256;
    context_params.n_ubatch = session->experts_path.empty() ? 128 : 256;
    context_params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
    context_params.n_threads = std::min(4u, std::max(1u, std::thread::hardware_concurrency()));
    context_params.n_threads_batch = context_params.n_threads;
    context_params.no_perf = true;
    session->context = llama_init_from_model(session->model, context_params);
    session->context_size = context_params.n_ctx;
    if (!session->context) { llama_model_free(session->model); delete session;
        fail(error, "无法分配模型运行内存，请关闭其他大型 App 后重试。"); return nullptr; }
    return session;
}
void mcpm_end(mcpm_session * session) {
    if (!session) return;
    if (session->context) llama_set_abort_callback(session->context, nullptr, nullptr);
    if (session->sampler) { llama_sampler_free(session->sampler); session->sampler = nullptr; }
    session->cancellation = nullptr;
}
void mcpm_free(mcpm_session * session) {
    if (!session) return;
    mcpm_end(session);
    if (session->context) llama_free(session->context);
    if (session->model) llama_model_free(session->model);
    delete session;
}
int mcpm_begin(mcpm_session * session, const char * system, const char * prompt,
               const char * grammar, mcpm_cancellation * cancellation, char ** error) {
    if (!session) return fail(error, "请先载入模型。");
    mcpm_end(session);
    session->cancellation = cancellation;
    if (aborted(cancellation)) return -2;
    llama_set_abort_callback(session->context, aborted, cancellation);
    llama_memory_clear(llama_get_memory(session->context), true);
    session->position = 0;
    const auto vocab = llama_model_get_vocab(session->model);
    // MiniCPM-V 4.7 1B uses ChatML. An empty thinking block selects direct instruct mode.
    const std::string input = std::string("<|im_start|>system\n") + system +
        "<|im_end|>\n<|im_start|>user\n" + prompt +
        "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n";
    const int count = -llama_tokenize(vocab, input.c_str(), (int)input.size(), nullptr, 0, true, true);
    if (count <= 0 || count >= session->context_size - 128)
        return fail(error, "描述过长，请缩短描述后重试。");
    std::vector<llama_token> tokens(count);
    if (llama_tokenize(vocab, input.c_str(), (int)input.size(), tokens.data(), count, true, true) < 0)
        return fail(error, "无法编码描述。");
    for (int offset = 0; offset < count; offset += 256) {
        if (aborted(cancellation)) return -2;
        const int n = std::min(256, count - offset);
        auto batch = llama_batch_get_one(tokens.data() + offset, n);
        const int status = llama_decode(session->context, batch);
        if (status != 0) return aborted(cancellation) ? -2 : fail(error, "描述处理失败，请重试。");
        session->position += n;
    }
    auto chain_params = llama_sampler_chain_default_params();
    chain_params.no_perf = true;
    session->sampler = llama_sampler_chain_init(chain_params);
    auto constraint = llama_sampler_init_grammar(vocab, grammar, "root");
    if (!constraint) return fail(error, "场景结构规则无效。");
    llama_sampler_chain_add(session->sampler, constraint);
    llama_sampler_chain_add(session->sampler, llama_sampler_init_greedy());
    return 0;
}
int mcpm_next(mcpm_session * session, uint8_t ** bytes, int * length, char ** error) {
    *bytes = nullptr; *length = 0;
    if (!session || !session->sampler) return fail(error, "模型未准备好。");
    if (aborted(session->cancellation)) return -2;
    if (session->position >= session->context_size - 1) return fail(error, "场景输出超过长度限制，请减少场景中的物体。");
    const auto vocab = llama_model_get_vocab(session->model);
    llama_token token = llama_sampler_sample(session->sampler, session->context, -1);
    if (llama_vocab_is_eog(vocab, token)) return 0;
    int size = llama_token_to_piece(vocab, token, nullptr, 0, 0, false);
    if (size < 0) size = -size;
    std::vector<char> piece(std::max(size, 1));
    int written = llama_token_to_piece(vocab, token, piece.data(), (int)piece.size(), 0, false);
    if (written < 0) return fail(error, "模型输出解码失败。");
    auto batch = llama_batch_get_one(&token, 1);
    const int status = llama_decode(session->context, batch);
    if (status != 0) return aborted(session->cancellation) ? -2 : fail(error, "场景生成失败，请重试。");
    session->position++;
    if (written > 0) {
        *bytes = (uint8_t *)malloc(written);
        if (!*bytes) return fail(error, "内存不足。");
        memcpy(*bytes, piece.data(), written);
        *length = written;
    }
    return 1;
}
}
