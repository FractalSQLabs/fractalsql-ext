/* src/fsql_band_l.h -- force-included when building the LTS band
 * (the latest DuckDB 1.4.x, ABI type C_STRUCT_UNSTABLE). The 1.4 header gates
 * the client-context and bind calls behind these two macros, so they must be
 * defined before duckdb_extension.h is seen. Force-including this file
 * (-include on gcc/clang, /FI on MSVC) keeps the build lines free of
 * shell-quoted string defines.
 *
 * An unstable build is tied to ONE exact DuckDB release. When a new 1.4.x ships,
 * rebuild with L_VERSION=v1.4.N (Makefile) / set L_VERSION (build.bat): the C
 * source does not change, only this string and the footer do (the 1.4.4 and
 * 1.4.5 API headers are byte-identical). */
#ifndef FSQL_BAND_L_H
#define FSQL_BAND_L_H
#ifndef FSQL_BAND_L_VER
#define FSQL_BAND_L_VER "v1.4.5"
#endif
#define DUCKDB_EXTENSION_API_VERSION_UNSTABLE
#define DUCKDB_EXTENSION_API_UNSTABLE_VERSION FSQL_BAND_L_VER
#endif
