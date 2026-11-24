// The slice of llama.cpp that LocalLLM uses, behind plain C types.
//
// Why a shim instead of `import llama`: whisper.framework and llama.framework
// each ship their own ggml.h, from different ggml versions. Importing both
// clang modules into the one Swift module fails ("'ggml_type' has different
// definitions in different modules"). Only LlamaBridge.c sees llama.h (and
// its ggml.h); Swift sees this header, which mentions no ggml type.
//
// This is the target's Swift bridging header (SWIFT_OBJC_BRIDGING_HEADER).

#ifndef UFLOW_LLAMA_BRIDGE_H
#define UFLOW_LLAMA_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

typedef struct uflow_llama uflow_llama;   // model + context + greedy sampler

/// Once per process, before any load. `on_error` receives llama.cpp's error
/// log lines (everything below error level is dropped); may be NULL.
void uflow_llama_init(void (*on_error)(const char *text));

/// mmap (never mlock) load of a GGUF with a `n_ctx`-token KV cache, all
/// layers on Metal when `gpu`, CPU only otherwise. NULL on failure.
uflow_llama *uflow_llama_load(const char *path, bool gpu, uint32_t n_ctx, int32_t n_threads);
void uflow_llama_free(uflow_llama *llm);

bool uflow_llama_uses_gpu(const uflow_llama *llm);
/// The GGUF's chat template (Jinja) copied into `buf`; its full length, or
/// -1 when there is none. Truncated (not terminated) if `len` is too small.
int32_t uflow_llama_chat_template(const uflow_llama *llm, char *buf, int32_t len);
/// What llama_chat_apply_template makes of the GGUF template for one system
/// and one user message, with the generation prompt; < 0 when unsupported.
int32_t uflow_llama_apply_template(const uflow_llama *llm, const char *system, const char *user, char *buf, int32_t len);

/// No BOS added. Returns the count, or -(needed) when `max` is too small.
int32_t uflow_llama_tokenize(const uflow_llama *llm, const char *text, int32_t len,
                             int32_t *tokens, int32_t max, bool parse_special);
/// The BOS token when the model wants one prepended, else -1.
int32_t uflow_llama_bos(const uflow_llama *llm);
bool uflow_llama_is_eog(const uflow_llama *llm, int32_t token);
/// The token's text (special tokens rendered). Returns the byte count, or
/// -(needed) when `len` is too small.
int32_t uflow_llama_piece(const uflow_llama *llm, int32_t token, char *buf, int32_t len);

/// Sliding-window attention width (0 when the model has none).
int32_t uflow_llama_swa_window(const uflow_llama *llm);
/// Lowest position still in the KV cache, -1 when empty.
int32_t uflow_llama_pos_min(const uflow_llama *llm);
/// Drops cached positions `from` and up; false if the cache can't.
bool uflow_llama_truncate(uflow_llama *llm, int32_t from);
void uflow_llama_clear(uflow_llama *llm);

/// Evaluates tokens at positions start…, logits for the last one only.
/// 0 on success; 2 when aborted; anything else is a failure.
int32_t uflow_llama_eval(uflow_llama *llm, const int32_t *tokens, int32_t n, int32_t start);
/// Greedy pick from the last evaluated token's logits.
int32_t uflow_llama_sample(uflow_llama *llm);

/// Polled between compute steps (CPU work; Metal finishes its graph first).
/// NULL `callback` clears it.
void uflow_llama_set_abort(uflow_llama *llm, bool (*callback)(void *data), void *data);

#endif
