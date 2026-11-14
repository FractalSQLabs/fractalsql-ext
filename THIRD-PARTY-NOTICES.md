<p align="center">
  <img src="FractalSQLforDuckDB.jpg" alt="FractalSQL for DuckDB" width="720">
</p>

Third-Party Notices

This file contains licensing and attribution notices for third-party software components incorporated into FractalSQL.

### 1. SFS (Stochastic Fractal Search) Algorithms
Component: SFS Core Math & Stochastic Convergence Logic, as shipped in the
vendored community core archives (`libfractalsql-community-*-c.a`,
`libfractalsql-community-*.so`, `libfractalsql-community-*.dylib`).
SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
Source: Based on "Stochastic Fractal Search" (Salimi 2014)
License: BSD-2-Clause for the SFS algorithm itself (the notice below);
Apache-2.0 for the remainder of the vendored core archive.

The vendored core's own public headers carry
`SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause` (see
`include/fractalsql.h` and `include/fractalsql_sql.h`), and the two
halves are: the Apache-2.0 half, which is this repository's `LICENSE`,
and the BSD-2-Clause half for the SFS algorithm lineage, which is this
section. The community core archives are therefore covered by the
repository's Apache-2.0 grant together with the notice below.

Copyright (c) 2014, Hamid Salimi. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in
      the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

-------------------------------------------------------------------------------

### 2. LuaJIT PRNG (lj_prng.c)
Component: Tausworthe-223 pseudo-random number generator, ported to C from LuaJIT's lj_prng.c and baked into the vendored core archive. The LuaJIT runtime itself is not linked.
Source: https://luajit.org/
License: MIT License

Copyright (C) 2005-2026 Mike Pall. All rights reserved.

(The year above is the copyright year carried by the LuaJIT v2.1 branch
tip at the time of the build. LuaJIT is cloned at build time from the
`v2.1` branch rather than pinned to a commit, so this line is refreshed
whenever the branch's copyright notice changes.)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

-------------------------------------------------------------------------------

### 3. libcurl
Component: bundled inside the vendored fractalsql-reasoning-http plugin
(include/<os>-<arch>/fractalsql-reasoning-http.so / .dll). The plugin is
not part of the .duckdb_extension and is not staged into any package
output: it is distributed from this repository's tree at the pinned
release tag and installed by scripts/easy_install.sh /
scripts/windows/easy_install.ps1.
Source: https://curl.se/
License: curl license (MIT/X derivative)

Linkage by platform (inherited from fractalsql-reasoning-http's own build):
  - Linux:   dynamically linked against the distro-provided libcurl;
             not bundled into the shipped .so.
  - Windows: statically linked and bundled into the shipped .dll. TLS
             backend is Schannel.
  - Darwin:  dynamically linked against the system-provided libcurl;
             not bundled into the shipped .so.

Copyright (c) 1996 - 2026, Daniel Stenberg, <daniel@haxx.se>, and many
contributors, see the THANKS file.

All rights reserved.

Permission to use, copy, modify, and distribute this software for any purpose
with or without fee is hereby granted, provided that the above copyright
notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF THIRD PARTY RIGHTS. IN
NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE
OR OTHER DEALINGS IN THE SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall not
be used in advertising or otherwise to promote the sale, use or other dealings
in this Software without prior written authorization of the copyright holder.

-------------------------------------------------------------------------------

### 4. zlib -- Windows builds only
Component: bundled inside the vendored fractalsql-reasoning-http plugin's
Windows build only, alongside static libcurl in entry 3 above -- curl's
own build depends on zlib for HTTP gzip/deflate Content-Encoding support,
and vcpkg links it transitively into the shipped .dll.
Source: https://zlib.net/
License: zlib License

Copyright notice:

 (C) 1995-2026 Jean-loup Gailly and Mark Adler

  This software is provided 'as-is', without any express or implied
  warranty.  In no event will the authors be held liable for any damages
  arising from the use of this software.

  Permission is granted to anyone to use this software for any purpose,
  including commercial applications, and to alter it and redistribute it
  freely, subject to the following restrictions:

  1. The origin of this software must not be misrepresented; you must not
     claim that you wrote the original software. If you use this software
     in a product, an acknowledgment in the product documentation would be
     appreciated but is not required.
  2. Altered source versions must be plainly marked as such, and must not be
     misrepresented as being the original software.
  3. This notice may not be removed or altered from any source distribution.

  Jean-loup Gailly        Mark Adler
  jloup@gzip.org          madler@alumni.caltech.edu

-------------------------------------------------------------------------------

### 5. Algorithm Attributions (Original Implementations)

The vendored core artifact (v2.x, community-sovereign) includes several
components that are ORIGINAL C implementations of published algorithms/
methods, not ports or incorporations of existing third-party source code
-- so no third-party license text applies. Listed here as academic
attribution for the published method each implementation follows, per
standard practice for algorithm-based (rather than code-derived)
components. Mirrors core's own THIRD-PARTY-NOTICES-COMMUNITY.md.

- **HNSW** -- Malkov, Y. A., & Yashunin, D. A. (2016, revised 2018).
  "Efficient and Robust Approximate Nearest Neighbor Search Using
  Hierarchical Navigable Small World Graphs." Implemented in the vendored
  core for a planned persistent-index feature; not currently used by
  `fractal_search`/`fractal_search_explore`, which do an exact brute-force
  scan (see `bench/README.md`).
- **DFA -- Detrended Fluctuation Analysis** (`fractal_dimension_dfa`,
  `fractal_dimension_drift`) -- Peng, C.-K., Buldyrev, S. V., Havlin, S.,
  Simons, M., Stanley, H. E., & Goldberger, A. L. (1994). "Mosaic
  organization of DNA nucleotides."
- **Box-counting (Minkowski-Bouligand) dimension**
  (`fractal_dimension_boxcount`, and shared by the domain-geometry
  functions below) -- standard, widely-used fractal-dimension estimation
  technique; not attributed to a single originating paper.
- **Lacunarity, fixed-grid variant** (used by
  `fractal_morphological_complexity`) -- Plotnick, R. E., Gardner, R. H.,
  & O'Neill, R. V. (1996). "Lacunarity indices as measures of landscape
  texture."
- **Gyrification Index** (`fractal_cortical_folding`) -- Zilles, K.,
  Armstrong, E., Schleicher, A., & Kretschmann, H. J. (1988). "The human
  pattern of gyrification in the cerebral cortex."
- **Vascular tortuosity (arc-chord ratio) / branch density**
  (`fractal_vascular_network`) -- standard vascular morphometry measures,
  not attributed to a single originating paper.
- **Corneal Nerve Fractal Dimension (CNFrD) convention**
  (`fractal_nerve_plexus_metric`) -- parameter conventions match those
  used by corneal confocal microscopy (CCM) analysis tools such as
  ACCMetrics.
- **Cardinality-constrained portfolio optimization**
  (`fractal_optimize_portfolio`) -- a hardcoded objective template built
  on entry 1's SFS engine (project-then-evaluate against a Sharpe-ratio
  objective); not itself a port of a separate published algorithm.
- **SimHash / random-projection state fingerprint** (`fractal_state_fingerprint`)
  -- Charikar, M. S. (2002). "Similarity estimation techniques from
  rounding algorithms." Proceedings of the 34th Annual ACM Symposium on
  Theory of Computing (STOC), pp. 380-388.
- **Brent's cycle detection** (`fractal_cycle_detect`) -- Brent, R. P.
  (1980). "An improved Monte Carlo factorization algorithm." BIT
  Numerical Mathematics, 20(2), 176-184. This module implements Brent's
  tortoise-and-hare checkpoint schedule, adapted to run incrementally
  over a live stream of values rather than a freely-callable function --
  an extension of the published algorithm, not a direct port.
- **Periodogram** (`fractal_periodogram`) -- Schuster, A. (1898). "On
  the investigation of hidden periodicities with application to a
  supposed 26 day period of meteorological phenomena." Terrestrial
  Magnetism, 3(1), 13-41. The classical periodogram, computed here via
  direct DFT.
- **TDA persistence diagram, 0-dimensional exact + graph Betti number**
  (`fractal_tda_persistence_diagram`) -- Edelsbrunner, H., Letscher, D.,
  & Zomorodian, A. (2002). "Topological persistence and simplification."
  Discrete & Computational Geometry, 28(4), 511-533. The 0-dimensional
  persistence computation (single-linkage clustering via Kruskal's
  algorithm) is an exact instance of this theory. The reported first
  Betti number is the cycle rank of the underlying Vietoris-Rips graph
  (edges minus vertices plus connected components), not the full
  simplicial first homology group the cited paper's boundary-matrix
  reduction method would produce.

-------------------------------------------------------------------------------

### 6. DuckDB (C extension API headers; and the shared library shipped with the MCP server)
Component: the DuckDB C extension API headers (`duckdb.h` and
`duckdb_extension.h`), vendored under `vendor/duckdb-<tag>/`.
Source: https://github.com/duckdb/duckdb (the tag each header set comes
from is the directory name)
License: MIT

This extension is written in C and calls DuckDB only through the function
table the engine hands it when the extension is loaded. No DuckDB source
code is compiled or linked into the extension; what the build takes from
DuckDB is these two headers (type declarations, constants and the table of
function pointers). They are MIT-licensed, so their notice is reproduced here.

The MCP server that ships in the release bundles (`mcp/` inside each bundle)
is a different case. It is a standalone program that runs DuckDB itself, so
each bundle carries DuckDB's own shared library for the DuckDB version that
bundle is for (`libduckdb.so`, `libduckdb.dylib` or `duckdb.dll`), taken
unmodified from the official DuckDB release of that tag. That is a
redistribution of DuckDB, under the MIT licence reproduced below. Each bundle
also carries, under `licenses/duckdb/`, the `LICENSE` file of that DuckDB tag
and the licence files of the third-party components DuckDB's source tree
carries under `third_party/`, so the notices of everything inside the DuckDB
library travel with it. The extension file itself still contains no DuckDB code.

The copyright line carried by each DuckDB tag whose headers this project
builds against is:

| DuckDB tag | Copyright line in that tag's LICENSE |
| --- | --- |
| v1.4.5 | Copyright 2018-2025 Stichting DuckDB Foundation |
| v1.5.6 | Copyright 2018-2025 Stichting DuckDB Foundation |
| v2.0.0 | Copyright 2018-2026 Stichting DuckDB Foundation |

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

-------------------------------------------------------------------------------

### 7. The reasoning plugin (fractalsql-reasoning-http)

Component: `fractalsql-reasoning-http`, the optional reasoning-tier
plugin. It is not a DuckDB extension; it is loaded by the extension at
runtime as a shared library, and it is what carries the HTTP round trip
to an LLM endpoint.
Version: `reasoning-http v1.4.1` (recorded in `include/REASONING_VERSION`)
Vendored at: `include/<os>-<arch>/fractalsql-reasoning-http.so`, and
`include/windows-x86_64/fractalsql-reasoning-http.dll` on Windows.

License: Apache-2.0, the same terms as the rest of this repository's
source. The plugin is built from the Apache-2.0 sources of the
`fractalsql-reasoning-http` project, and the copies vendored under
`include/` carry those terms with them.

The plugin bundles third-party code of its own on some platforms, and
those notices travel with it as installed:

- **libcurl** -- section 3. Statically linked on the Windows build;
  dynamically linked against the system libcurl on Linux and macOS.
- **zlib** -- section 4. The Windows build only.

That is why the installers write `LICENSE` and `LICENSE-THIRD-PARTY`
into the install directory next to the plugin as well as next to the
extension, and why the container images carry the same files under
`/licenses/`.

-------------------------------------------------------------------------------

### 8. nlohmann/json (MCP server)
Component: JSON for Modern C++ 3.11.3, a single header (`mcp/vendor/json.hpp`)
compiled into the MCP server (`fractalsql-ext-mcp`). The DuckDB extension does
not use it.
Source: https://github.com/nlohmann/json
License: MIT

Copyright (c) 2013-2023 Niels Lohmann <https://nlohmann.me>

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

-------------------------------------------------------------------------------

### 9. OpenSSL (MCP server, Windows build)
Component: OpenSSL 3.x (`libssl`, `libcrypto`), used by the MCP server's HTTPS
transport. It is linked statically into the Windows MCP binary (vcpkg
`openssl:x64-windows-static`) and redistributed inside it. The Linux and
macOS MCP binaries link OpenSSL dynamically (the host's own library on Linux,
Homebrew's `openssl@3` on macOS) and do not distribute it. The DuckDB
extension does not use it.
Source: https://www.openssl.org/
License: Apache License, Version 2.0

Copyright 1995-<year of the release> The OpenSSL Project Authors. All Rights
Reserved. Individual OpenSSL source files carry their own years and, in places,
other holders (for example Oracle and Nokia); the header of each file in the
OpenSSL source tree states the exact line. OpenSSL's own `LICENSE.txt` is the
unmodified Apache License 2.0 text and the source tree has no separate NOTICE
file.

Licensed under the Apache License, Version 2.0; the full text of that licence
is the `LICENSE` file in this distribution (this project is Apache-2.0 too).
Unless required by applicable law or agreed to in writing, the software is
distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
either express or implied.

-------------------------------------------------------------------------------

### 10. Compiler runtime libraries (MCP server)
Component: the GNU C++ standard library (`libstdc++`), linked statically into
the Linux MCP binaries.

libstdc++ is GPL-3.0-or-later WITH the GCC Runtime Library Exception
(version 3.1), which permits distributing the compiled program under terms of
its own choosing.
