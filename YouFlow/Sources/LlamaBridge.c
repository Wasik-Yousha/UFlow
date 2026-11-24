// See LlamaBridge.h. Compiled on its own, so llama's ggml.h never meets
// whisper's.

#include "LlamaBridge.h"

#include <llama/llama.h>
#include <stdlib.h>
#include <string.h>

struct uflow_llama {
    struct llama_model *model;
    struct llama_context *ctx;
    struct llama_sampler *sampler;
    const struct llama_vocab *vocab;
    struct llama_batch_ext *batch;
    bool gpu;
};

static void (*error_sink)(const char *text);

static void log_callback(enum ggml_log_level level, const char *text, void *user_data) {
    (void)user_data;
    if (level == GGML_LOG_LEVEL_ERROR && error_sink && text) error_sink(text);
}

void uflow_llama_init(void (*on_error)(const char *text)) {
    error_sink = on_error;
    llama_log_set(log_callback, NULL);
    llama_backend_init();
}

uflow_llama *uflow_llama_load(const char *path, bool gpu, uint32_t n_ctx, int32_t n_threads) {
    struct llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = gpu ? -1 : 0;
    mparams.load_mode = LLAMA_LOAD_MODE_MMAP;   // never mlock
    if (!gpu) mparams.use_extra_bufts = false;
    struct llama_model *model = llama_model_load_from_file(path, mparams);
    if (!model) return NULL;

    struct llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx = n_ctx;
    cparams.n_batch = n_ctx;   // any prompt that fits fits in one batch
    cparams.n_seq_max = 1;
    cparams.n_threads = n_threads;
    cparams.n_threads_batch = n_threads;
    cparams.no_perf = true;
    cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
    if (!gpu) {
        cparams.offload_kqv = false;
        cparams.op_offload = false;
    }
    struct llama_context *ctx = llama_init_from_model(model, cparams);
    if (!ctx) {
        llama_model_free(model);
        return NULL;
    }
    struct llama_batch_ext *batch = llama_batch_ext_init(ctx);
    if (!batch) {
        llama_free(ctx);
        llama_model_free(model);
        return NULL;
    }
    struct llama_sampler *sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(sampler, llama_sampler_init_greedy());

    uflow_llama *llm = calloc(1, sizeof *llm);
    llm->model = model;
    llm->ctx = ctx;
    llm->sampler = sampler;
    llm->vocab = llama_model_get_vocab(model);
    llm->batch = batch;
    llm->gpu = gpu && llama_supports_gpu_offload();
    return llm;
}

void uflow_llama_free(uflow_llama *llm) {
    if (!llm) return;
    llama_batch_ext_free(llm->batch);
    llama_sampler_free(llm->sampler);
    llama_free(llm->ctx);
    llama_model_free(llm->model);
    free(llm);
}

bool uflow_llama_uses_gpu(const uflow_llama *llm) { return llm->gpu; }

int32_t uflow_llama_chat_template(const uflow_llama *llm, char *buf, int32_t len) {
    const char *tmpl = llama_model_chat_template(llm->model, NULL);
    if (!tmpl) return -1;
    size_t n = strlen(tmpl);
    if (len > 0) memcpy(buf, tmpl, n < (size_t)len ? n : (size_t)len);
    return (int32_t)n;
}

int32_t uflow_llama_apply_template(const uflow_llama *llm, const char *system, const char *user, char *buf, int32_t len) {
    struct llama_chat_message messages[2] = { { "system", system }, { "user", user } };
    return llama_chat_apply_template(llama_model_chat_template(llm->model, NULL), messages, 2, true, buf, len);
}

int32_t uflow_llama_tokenize(const uflow_llama *llm, const char *text, int32_t len,
                             int32_t *tokens, int32_t max, bool parse_special) {
    return llama_tokenize(llm->vocab, text, len, tokens, max, false, parse_special);
}

int32_t uflow_llama_bos(const uflow_llama *llm) {
    return llama_vocab_get_add_bos(llm->vocab) ? llama_vocab_bos(llm->vocab) : -1;
}

bool uflow_llama_is_eog(const uflow_llama *llm, int32_t token) { return llama_vocab_is_eog(llm->vocab, token); }

int32_t uflow_llama_piece(const uflow_llama *llm, int32_t token, char *buf, int32_t len) {
    return llama_token_to_piece(llm->vocab, token, buf, len, 0, true);
}

int32_t uflow_llama_swa_window(const uflow_llama *llm) { return llama_model_n_swa(llm->model); }

int32_t uflow_llama_pos_min(const uflow_llama *llm) { return llama_memory_seq_pos_min(llama_get_memory(llm->ctx), 0); }

bool uflow_llama_truncate(uflow_llama *llm, int32_t from) {
    return llama_memory_seq_rm(llama_get_memory(llm->ctx), 0, from, -1);
}

void uflow_llama_clear(uflow_llama *llm) { llama_memory_clear(llama_get_memory(llm->ctx), true); }

int32_t uflow_llama_eval(uflow_llama *llm, const int32_t *tokens, int32_t n, int32_t start) {
    if (n <= 0) return -1;
    int32_t done = 0;
    while (done < n) {
        llama_batch_ext_clear(llm->batch);
        int32_t last = -1;
        int32_t i = done;
        for (; i < n; i++) {
            int32_t slot = llama_batch_ext_add_token(llm->batch, 0, tokens[i]);
            if (slot == -1) break;   // batch full: evaluate this chunk first
            if (slot < 0) return -1;
            llama_pos pos = start + i;
            if (!llama_batch_ext_set_pos(llm->batch, slot, &pos)) return -1;
            last = slot;
        }
        if (last < 0) return -1;
        if (i == n) llama_batch_ext_set_output_logits(llm->batch, last, true);
        int32_t rc = llama_process(llm->ctx, LLAMA_PROCESS_TYPE_DECODE, llm->batch);
        if (rc != 0) return rc;
        done = i;
    }
    return 0;
}

int32_t uflow_llama_sample(uflow_llama *llm) { return llama_sampler_sample(llm->sampler, llm->ctx, -1); }

void uflow_llama_set_abort(uflow_llama *llm, bool (*callback)(void *data), void *data) {
    llama_set_abort_callback(llm->ctx, callback, data);
}
