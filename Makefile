# Makefile -- the pure-C DuckDB extension, built in both bands.
#
#   make            both bands into dist/<platform>/
#   make band-s     stable  (C_STRUCT, v1.5.6 header)  -> DuckDB 1.5.6, 2.0.0
#   make band-l     lts     (C_STRUCT_UNSTABLE, L_VERSION) -> exactly that DuckDB 1.4.x
#                   (default: the latest 1.4.x; rebuild with L_VERSION=v1.4.N when one ships)
#   make clean
#
# No DuckDB source is compiled or linked: the extension calls the engine
# through the function table DuckDB hands it at LOAD, so a build takes seconds.
# Windows uses build.bat (cl, C mode); this Makefile covers Linux and macOS.
# See ~/github/duckdb-purec-ext-port.txt.

CC      ?= cc
# SAN=address | undefined builds an instrumented extension into dist/<san>/ (not a release artifact).
# Run it with the runtime preloaded: see test/parity_diff.py (CAPI_SAN=address|undefined).
SAN     ?=
OSNAME  := $(shell uname -s)
ARCH    := $(shell uname -m)

ifeq ($(OSNAME),Darwin)
  PLAT_OS := osx
  SHARED  := -dynamiclib -undefined dynamic_lookup -Wl,-exported_symbol,_fractalsql_init_c_api
else
  PLAT_OS := linux
  SHARED  := -shared -Wl,--exclude-libs,ALL -Wl,--version-script=src/exports.map -Wl,-z,relro,-z,now
endif
# The vendored core (fractalsql-core), linked statically: it stays private to the
# extension (one exported symbol), exactly as in the C++ build.
ifeq ($(OSNAME),Darwin)
  CORE_PLAT := darwin-$(if $(filter x86_64 amd64,$(ARCH)),x86_64,arm64)
else
  CORE_PLAT := linux-$(if $(filter x86_64 amd64,$(ARCH)),x86_64,aarch64)
endif
CORE_VARIANT ?= community-sovereign-c
CORE_LIB     ?= include/$(CORE_PLAT)/libfractalsql-$(CORE_VARIANT).a
LDLIBS       ?= -lm -ldl -lpthread
ifeq ($(ARCH),x86_64)
  PLAT_ARCH := amd64
else ifeq ($(ARCH),amd64)
  PLAT_ARCH := amd64
else
  PLAT_ARCH := arm64
endif
PLATFORM ?= $(PLAT_OS)_$(PLAT_ARCH)

# Sources. The real extension; `make SRC=test/spike/fsql_spike.c CORE_LIB=` builds the P0 spike.
SRC     ?= src/fractalsql_ext.c src/fsql_duck.c src/fsql_buf.c src/fsql_vector.c src/fsql_sovereign.c src/fsql_enterprise.c src/fsql_reasoning.c src/fsql_config.c src/fsql_ledger.c src/fsql_parse.c src/fsql_t2s.c src/fsql_vectorizer.c src/fsql_agents.c src/fsql_domain_agents.c
EXTVER  ?= v2.0.1
L_VERSION ?= v1.4.5
COV     ?=
OUT     ?= dist/$(if $(SAN),san-$(SAN),$(if $(COV),cov,$(PLATFORM)))
FOOTER  := python3 -I scripts/append_metadata.py

CFLAGS  ?= -O2
ifneq ($(SAN),)
  CFLAGS := -O1 -g -fno-omit-frame-pointer -fsanitize=$(SAN) -fno-sanitize-recover=undefined
  SHARED += -fsanitize=$(SAN)
endif
ifneq ($(COV),)
  CFLAGS := -O0 -g --coverage -fprofile-update=atomic    # atomic: the extension is multithreaded (the monitor, host threads)
  SHARED += --coverage
endif
# -Wno-missing-field-initializers: the fsql_*_def registration tables rely on C's zero-filled trailing
# fields (optional bind callback, struct field names); every other warning stays on.
CFLAGS  += -std=c11 -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers -fPIC -fvisibility=hidden -D_GNU_SOURCE -Iinclude

BAND_S_FILE := $(OUT)/fractalsql.capi.$(PLATFORM).duckdb_extension
BAND_L_FILE := $(OUT)/fractalsql.$(L_VERSION).$(PLATFORM).duckdb_extension

.PHONY: all band-s band-l clean unit
all: band-s band-l
band-s: $(BAND_S_FILE)
band-l: $(BAND_L_FILE)

# Stable band: the v1.5.6 API surface; loads on 1.5.6 and 2.0.0.
$(BAND_S_FILE): $(SRC) $(wildcard src/*.h) $(wildcard src/*.c) src/exports.map
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -Isrc -Ivendor/duckdb-v1.5.6 $(SHARED) $(SRC) $(CORE_LIB) $(LDLIBS) -o $@
	$(FOOTER) --extension $@ --platform $(PLATFORM) --duckdb-version v1.5.6 \
	  --extension-version $(EXTVER) --abi-type C_STRUCT

# LTS band: tied to exactly one DuckDB 1.4.x (its client-context and bind calls are
# in the unstable part of that header). The headers are identical across 1.4.x patches.
$(BAND_L_FILE): $(SRC) $(wildcard src/*.h) $(wildcard src/*.c) src/exports.map
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -Isrc -Ivendor/duckdb-$(L_VERSION) -DFSQL_BAND_L -DFSQL_BAND_L_VER='"$(L_VERSION)"' -include src/fsql_band_l.h \
	  $(SHARED) $(SRC) $(CORE_LIB) $(LDLIBS) -o $@
	$(FOOTER) --extension $@ --platform $(PLATFORM) --duckdb-version $(L_VERSION) \
	  --extension-version $(EXTVER) --abi-type C_STRUCT_UNSTABLE

# Only what this build writes: dist/ also holds release packages and older artifacts.
clean:
	rm -rf dist/$(PLATFORM) dist/san-address dist/san-undefined dist/san-thread dist/cov dist/unit dist/lifecycle

# Unit tests, built with ASan + UBSan (no DuckDB needed): `make unit`
UNIT_CC ?= $(CC)
unit: dist/unit/buf_test dist/unit/redact_unit dist/unit/ledger_unit
	dist/unit/buf_test
	dist/unit/redact_unit
	dist/unit/ledger_unit
dist/unit/redact_unit: test/redact_unit.c src/fsql_audit_redact.h src/fsql_hmac.h
	@mkdir -p dist/unit
	$(UNIT_CC) -std=c11 -g -O1 -Wall -Wextra -Wno-unused-function -fsanitize=address,undefined -fno-sanitize-recover=undefined -Isrc \
	  test/redact_unit.c -o $@
dist/unit/ledger_unit: test/ledger_unit.c src/fsql_ledger_store.h src/fsql_hmac.h
	@mkdir -p dist/unit
	$(UNIT_CC) -std=c11 -g -O1 -Wall -Wextra -fsanitize=address,undefined -fno-sanitize-recover=undefined -Isrc \
	  test/ledger_unit.c -o $@
dist/unit/buf_test: test/buf_test.c src/fsql_buf.c src/fsql_buf.h
	@mkdir -p dist/unit
	$(UNIT_CC) -std=c11 -g -O1 -Wall -Wextra -fsanitize=address,undefined -fno-sanitize-recover=undefined -Isrc \
	  test/buf_test.c src/fsql_buf.c -lm -o $@
