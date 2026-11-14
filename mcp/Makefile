# SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# fractalsql-ext-mcp: the MCP server. It links libduckdb (DuckDB's C library) and loads the FractalSQL
# extension into the process at start-up.
#
#   make DUCKDB_DIR=/path/with/duckdb.h-and-libduckdb.so      build ./fractalsql-ext-mcp   (OUT=path and BUILD=dir move the outputs)
#   make probes DUCKDB_DIR=...                                the standalone unit probes under build/
#   make clean
#
# DUCKDB_DIR is the directory of a DuckDB release's libduckdb-<os>-<arch>.zip (duckdb.h and libduckdb.so), matching
# the DuckDB version the extension was built for (see docs/getting-started.md).
CXX      ?= c++
CXXFLAGS ?= -O2
STD      := -std=c++17 -Wall -Wextra
DUCKDB_DIR ?= /usr/local
# CPPEXTRA / LDEXTRA: extra include and library flags (macOS: Homebrew's keg-only OpenSSL, -I<prefix>/include and -L<prefix>/lib).
CPPEXTRA ?=
LDEXTRA  ?=
INC      := -Isrc -Ivendor -I$(DUCKDB_DIR) -I$(DUCKDB_DIR)/include $(CPPEXTRA)
# RPATH is where the binary looks for libduckdb.so at run time. The default is the build-time directory; a release
# package sets it to $$ORIGIN (make RPATH='$$ORIGIN') so the library can ride beside the binary.
RPATH    ?= $(DUCKDB_DIR)
LDLIBS   := -L$(DUCKDB_DIR) -L$(DUCKDB_DIR)/lib $(LDEXTRA) -lduckdb -lssl -lcrypto -lpthread -Wl,-rpath,'$(RPATH)' -Wl,-rpath,'$(RPATH)/lib'
BUILD    ?= build
OUT      ?= fractalsql-ext-mcp

SRCS := $(wildcard src/*.cpp) $(wildcard src/adapters/*.cpp)
OBJS := $(patsubst src/%.cpp,$(BUILD)/%.o,$(SRCS))

.DEFAULT_GOAL := $(OUT)

$(OUT): $(OBJS)
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -o $@ $(OBJS) $(LDLIBS) $(SANFLAGS)

$(BUILD)/%.o: src/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(STD) $(CXXFLAGS) $(SANFLAGS) $(INC) -MMD -c -o $@ $<

-include $(OBJS:.o=.d)

src/adapters/tools_spec.inc: tools.spec.json scripts/gen_spec_inc.py
	python3 scripts/gen_spec_inc.py

all: $(OUT)

probes: $(BUILD)/vectors_probe $(BUILD)/concurrency_probe $(BUILD)/db_probe $(BUILD)/sanitize_probe $(BUILD)/duckdb_exec

$(BUILD)/vectors_probe: tests/vectors_probe.cpp src/vectors.cpp src/errors.cpp
	@mkdir -p $(BUILD)
	$(CXX) $(STD) $(CXXFLAGS) $(INC) -o $@ $^ $(LDLIBS)
$(BUILD)/concurrency_probe: tests/concurrency_probe.cpp src/errors.cpp
	@mkdir -p $(BUILD)
	$(CXX) $(STD) $(CXXFLAGS) $(INC) -o $@ $^ $(LDLIBS)
$(BUILD)/db_probe: tests/db_probe.cpp src/db.cpp src/errors.cpp src/logging.cpp
	@mkdir -p $(BUILD)
	$(CXX) $(STD) $(CXXFLAGS) $(INC) -o $@ $^ $(LDLIBS)
$(BUILD)/sanitize_probe: tests/sanitize_probe.cpp src/errors.cpp
	@mkdir -p $(BUILD)
	$(CXX) $(STD) $(CXXFLAGS) $(INC) -o $@ $^ $(LDLIBS)
$(BUILD)/duckdb_exec: tests/duckdb_exec.cpp
	@mkdir -p $(BUILD)
	$(CXX) $(STD) $(CXXFLAGS) $(INC) -o $@ $^ $(LDLIBS)

clean:
	rm -rf $(BUILD) $(OUT)

.PHONY: all probes clean
