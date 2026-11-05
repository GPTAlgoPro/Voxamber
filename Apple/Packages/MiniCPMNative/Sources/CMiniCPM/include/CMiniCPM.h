#ifndef THREE_LIVE_MINICPM_H
#define THREE_LIVE_MINICPM_H
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct mcpm_session mcpm_session;
typedef struct mcpm_cancellation mcpm_cancellation;
mcpm_cancellation * mcpm_cancellation_create(void);
void mcpm_cancellation_cancel(mcpm_cancellation * flag);
void mcpm_cancellation_destroy(mcpm_cancellation * flag);
mcpm_session * mcpm_load(const char * model_path, const char * experts_path,
                         int context_size, int expert_cache_slots, int prefetch_depth, char ** error);
void mcpm_free(mcpm_session * session);
// Starts an independent ChatML turn, clears prior KV state and constrains sampling with GBNF.
int mcpm_begin(mcpm_session * session, const char * system, const char * prompt,
               const char * grammar, mcpm_cancellation * cancellation, char ** error);
// Returns 1 for a token, 0 for EOG, -1 for failure, -2 for cancellation.
// A token can end within a UTF-8 sequence: consume bytes, not a C string per token.
int mcpm_next(mcpm_session * session, uint8_t ** bytes, int * length, char ** error);
void mcpm_end(mcpm_session * session);
void mcpm_string_free(void * value);
#ifdef __cplusplus
}
#endif
#endif
