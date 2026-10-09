#ifndef GTO_CORE_H
#define GTO_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque solver handle.
typedef struct SolverHandle SolverHandle;

typedef void (*gto_progress_cb)(void *ctx, uint32_t iteration, float exploitability, double elapsed);

/// All functions returning `char *` return UTF-8 JSON of the form
/// `{"ok": true, ...}` or `{"ok": false, "error": "..."}`.
/// Release every returned string with `gto_string_free`.
void gto_string_free(char *s);
char *gto_version(void);

char *gto_estimate(const char *config_json);
SolverHandle *gto_solver_create(const char *config_json, char **error_out);
void gto_solver_free(SolverHandle *h);
char *gto_solver_info(const SolverHandle *h);
char *gto_solver_solve(const SolverHandle *h, uint32_t max_iterations, float target_exploitability,
                       uint32_t check_every, gto_progress_cb callback, void *ctx);
void gto_solver_stop(const SolverHandle *h);
/// `path_json`: JSON array mixing action indices (numbers) and dealt cards ("Kh").
char *gto_solver_query(const SolverHandle *h, const char *path_json);

/// Heads-up preflop solver (player 0 = SB/button, 1 = BB). Exploitability in mbb/hand.
typedef struct PreflopHandle PreflopHandle;
PreflopHandle *gto_preflop_create(const char *config_json, char **error_out);
void gto_preflop_free(PreflopHandle *h);
char *gto_preflop_solve(const PreflopHandle *h, uint32_t max_iterations, float target_mbb, uint32_t check_every,
                        gto_progress_cb callback, void *ctx);
void gto_preflop_stop(const PreflopHandle *h);
/// `path_json`: JSON array of action indices.
char *gto_preflop_query(const PreflopHandle *h, const char *path_json);

char *gto_parse_range(const char *range);
char *gto_evaluate(const char *request_json);
char *gto_equity(const char *request_json);

#ifdef __cplusplus
}
#endif

#endif
