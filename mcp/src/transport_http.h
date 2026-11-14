#pragma once
#include <string>
#include <vector>
#include <functional>
#include <memory>
#include "jsonrpc_server.h"

namespace fsqlmcp
{
    struct HttpConfig
    {
        std::string host = "127.0.0.1";  // FSQL_MCP_BIND / --bind
        int port = 8765;
        std::string path = "/mcp";        // FSQL_MCP_HTTP_PATH
        std::string authToken;          // FSQL_MCP_AUTH_TOKEN
        std::string authTokenFile;       // FSQL_MCP_AUTH_TOKEN_FILE (hot-reloaded)
        // The per-client credential file (FSQL_MCP_TOKEN_POLICY_FILE): a JSON
        // document naming clients, each with the SHA-256 of its token, an
        // optional expiry and an optional tool allowlist. The file itself
        // holds no secret, only hashes.
        std::string tokenPolicyFile;
        // The browser origins this deployment accepts, on top of the loopback
        // origins that are always allowed (FSQL_MCP_ALLOWED_ORIGINS).
        std::vector<std::string> allowedOrigins;
        bool tlsEnabled = false;
        std::string tlsCertPath, tlsKeyPath;
        int shutdownDrainMs = 5000;

        // Per-session engine state, supplied by main.cpp: each Mcp-Session-Id
        // gets its own JsonRpcServer built over its own dedicated DB connection
        // (per-session isolation).
        std::function<std::unique_ptr<JsonRpcServer>()> sessionFactory;
        // Called when a session is torn down (DELETE /mcp or server drain)
        // *after* its server is destroyed, e.g. Db::sessionClose().
        std::function<void()> sessionTeardown = nullptr;
    };

    // Minimal threaded HTTP/1.1 listener, no Boost.Asio/libuv. Every
    // path except GET /healthz and GET /readyz requires a valid Bearer token.
    // One dedicated DB session per Mcp-Session-Id (per-client
    // isolation), created via HttpConfig::sessionFactory.
    int runHttpTransport( JsonRpcServer& server, const HttpConfig& cfg,
                           std::function<bool()> readinessProbe );

    // The startup check for the per-client credential file: a policy file
    // that cannot be read or parsed is a startup failure, never a silent
    // "no authentication". Returns an empty string when the policy is fine.
    std::string tokenPolicyError( const HttpConfig& cfg );
}
