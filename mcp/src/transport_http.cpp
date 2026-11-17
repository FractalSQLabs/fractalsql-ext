#include "transport_http.h"
#include "errors.h"
#include "logging.h"
#include "policy.h"
#include <openssl/sha.h>
#include <openssl/ssl.h>
#include <openssl/rand.h>
#include <openssl/err.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <fstream>
#include <mutex>
#include <condition_variable>
#include <thread>
#include <atomic>
#include <chrono>
#include <map>
#include <set>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <sstream>
#include <cctype>
#include <cerrno>
#include <csignal>
#include <algorithm>

#ifdef _WIN32
  #ifndef WIN32_LEAN_AND_MEAN
    #define WIN32_LEAN_AND_MEAN
  #endif
  #include <winsock2.h>
  #include <ws2tcpip.h>
  typedef int socklen_t;
  // Winsock2 has no inet_pton(); the WinSock spelling of the same call is
  // InetPtonA (Vista+). Same signature, same return convention.
  #define inet_pton InetPtonA
#else
  #include <sys/socket.h>
  #include <sys/resource.h>
  #include <sys/time.h>
  #include <poll.h>
  #include <netinet/in.h>
  #include <arpa/inet.h>
  #include <unistd.h>
  #include <sys/stat.h>
#endif

// Close a socket, on either platform. The two spellings are genuinely
// different functions -- WinSock's closesocket() and POSIX's close() --
// so this is a small inline shim rather than a macro: a macro named
// `closesocket` that expanded to `::close` broke the one QUALIFIED call
// site (`::closesocket(fd)` expanded to `::::close`, which is not a
// valid expression), and a macro that expanded to a bare `close` would
// instead be open to a member-function lookup shadowing it. The shim has
// neither problem: the call is always unqualified and always resolves
// to the global function.
#ifdef _WIN32
  inline void fsqlCloseSocket( int fd ) { ::closesocket( fd ); }
  inline void fsqlHalfCloseSend( int fd ) { ::shutdown( fd, SD_SEND ); }
  inline void fsqlSetRecvTimeoutMs( int fd, int ms )
  { DWORD t = static_cast<DWORD>( ms ); ::setsockopt( fd, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>( &t ), sizeof( t ) ); }
#else
  inline void fsqlCloseSocket( int fd ) { ::close( fd ); }
  inline void fsqlHalfCloseSend( int fd ) { ::shutdown( fd, SHUT_WR ); }
  inline void fsqlSetRecvTimeoutMs( int fd, int ms )
  { timeval t{ ms / 1000, ( ms % 1000 ) * 1000 }; ::setsockopt( fd, SOL_SOCKET, SO_RCVTIMEO, &t, sizeof( t ) ); }
#endif

// Closes after a refusal reply: half-closes, reads and discards the client's
// pending request for up to lingerMs, then closes. A plain close with unread
// data resets the connection, and the reset discards the reply that was just
// written -- the peer then sees a broken connection instead of the refusal it
// was owed (seen on Windows).
inline void fsqlCloseAfterReply( int fd, int lingerMs )
{
    fsqlHalfCloseSend( fd );
    fsqlSetRecvTimeoutMs( fd, 100 );
    char sink[ 4096 ];
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds( lingerMs );
    while( std::chrono::steady_clock::now() < deadline )
    {
        const int n = static_cast<int>( ::recv( fd, sink, sizeof( sink ), 0 ) );
        if( n == 0 ) break;   // the peer closed: nothing more can arrive
        if( n < 0 )
        {
            // No data yet (or a signal landed mid-read): keep waiting for the
            // rest of the peer's request.
#ifdef _WIN32
            const int e = WSAGetLastError();
            if( e != WSAETIMEDOUT && e != WSAEWOULDBLOCK ) break;
#else
            if( errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR ) break;
#endif
        }
    }
    fsqlCloseSocket( fd );
}

// Minimal threaded HTTP/1.1 listener :
//   GET  /healthz -> 200, no auth, no DB touch
//   GET  /readyz  -> readinessProbe() ? 200 : 503, no auth
//   POST <path>    -> auth required; initialize mints Mcp-Session-Id, every
//                     other method requires it (400 missing / 404 unknown);
//                     body capped at 32 MiB; dispatched on the connection's
//                     worker thread, reply written only after dispatch returns
//                     (concurrency bounded by ConcurrencyManager, not thread
//                     count)
// One request per connection: the reply is written, then the connection is
// closed. The MCP HTTP transport is a request/response protocol, so a
// keep-alive loop bought nothing and cost a class of lifetime bugs.
//   DELETE <path>  -> closes the named session's dedicated DB connection
// SIGTERM/SIGINT -> sessions drain up to cfg.shutdownDrainMs, then the
// listening socket is closed. SIGHUP -> reload the auth token ONLY, never
// shutdown. The reload itself runs on the request path, not in the signal
// handler: the handler only raises a flag, because the reload is file I/O
// plus allocation and neither is async-signal-safe.

namespace fsqlmcp
{
    // A header the server acts on that arrives twice is refused: two values for the host, the credential, the origin or the
    // framing are an ambiguity a proxy in front and this parser could resolve differently (SECURITY_AUDIT.md 3.18).
    static bool isSingleValuedHeader( const std::string& name )
    {
        static const char* const kNames[] = { "host", "authorization", "origin", "content-type", "transfer-encoding",
                                              "mcp-session-id", "mcp-protocol-version", "mcp-method", "mcp-name" };
        for( const char* n : kNames )
            if( name == n ) return true;
        return false;
    }

    static constexpr std::size_t kBodyMax = 32 * 1024 * 1024;

    // SIGHUP means "reload the auth token", and that reload is file I/O plus
    // allocation. Doing that work inside the signal handler is not
    // async-signal-safe: it can deadlock against the malloc arena lock the
    // interrupted thread already held (observed as a TSan-reported hang
    // under a fully thread-instrumented build), and it can corrupt the
    // TokenStore's own mutex if the interrupted thread was inside reload().
    //
    // So the handler only sets a flag. The reload itself happens on the
    // ordinary request path (check() -> reload()), which is not signal
    // context and is free to block on I/O.
    static std::atomic<bool> g_sighupReload{ false };

    // The last-write time of a file, or false when it cannot be read. Used to
    // hot-reload the token file and the per-client credential file.
    static bool fileMtime( const std::string& path, time_t& out )
    {
#ifdef _WIN32
        HANDLE h = CreateFileA( path.c_str(), FILE_READ_ATTRIBUTES,
                                FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                                OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr );
        if( h == INVALID_HANDLE_VALUE ) return false;
        FILETIME ft{};
        const bool ok = GetFileTime( h, nullptr, nullptr, &ft ) != 0;
        CloseHandle( h );
        if( !ok ) return false;
        out = ( static_cast<time_t>( ft.dwHighDateTime ) << 32 ) | ft.dwLowDateTime;
        return true;
#else
        struct stat st{};
        if( ::stat( path.c_str(), &st ) != 0 ) return false;
        out = st.st_mtime;
        return true;
#endif
    }

    // Bearer-token store: opaque token, mtime-hot-reloaded file form,
    // timing-safe compare, NEVER logged.
    //
    // Two credential forms live here:
    //
    //  1. THE DEPLOYMENT TOKEN (FSQL_MCP_AUTH_TOKEN / _FILE). One secret for
    //     the whole deployment; every holder shares one identity and may call
    //     every tool.
    //  2. PER-CLIENT CREDENTIALS (FSQL_MCP_TOKEN_POLICY_FILE). A JSON file
    //     naming clients, each with the SHA-256 of its token (so the file
    //     itself holds no secret), an optional expiry and an optional tool
    //     allowlist. A client that presents its own token is that client:
    //     its name is its fairness key and its allowlist bounds what it can
    //     call.
    class TokenStore
    {
    public:
        // What a presented credential turned out to be.
        struct Credential
        {
            bool ok = false;
            bool expired = false;
            std::string clientName;                        // the policy entry's name, or a token-derived key
            std::optional<std::set<std::string>> allow;    // unset = every tool
        };

        // The config is held BY VALUE: a connection thread can outlive
        // runHttpTransport() (the shutdown path detaches whatever is still
        // in flight), and a reference to the caller's config would dangle
        // by then.
        explicit TokenStore( const HttpConfig& cfg ) : cfg_( cfg ) { reload( true ); }

        Credential check( const std::string& presented )
        {
            // One lock only: the reload (mtime check) reads token state, so
            // it happens under the same guard as the compare. A same-thread
            // second lock on this non-recursive mutex aborts on MSVC and
            // deadlocks forever on glibc; do not restore the
            // maybeReload-then-lock shape.
            std::lock_guard<std::mutex> lk( mu_ );
            // SIGHUP's forced reload: ignores the mtime check entirely,
            // consumed here (on whatever ordinary request thread happens
            // to call check() next) rather than done on the signal
            // handler's own stack -- see g_sighupReload's own comment.
            if( g_sighupReload.exchange( false, std::memory_order_relaxed ) )
                reload( true );
            // The credential files are re-read whenever their timestamp
            // changed. Both of them hot-reload: a deployment token and a
            // per-client credential file are the same kind of file, and an
            // operator who adds a client to the policy file expects that
            // client to work without a restart.
            if( !cfg_.authTokenFile.empty() || !cfg_.tokenPolicyFile.empty() ) reload( false );
            if( presented.empty() ) return Credential{};

            if( !token_.empty() && presented.size() == token_.size() &&
                CRYPTO_memcmp( presented.data(), token_.data(), token_.size() ) == 0 )   // timing-safe
            {
                Credential c;
                c.ok = true;
                // The identity of a deployment-token holder: a short digest
                // of the token, never the token itself.
                c.clientName = "token:" + sha256Hex( presented ).substr( 0, 8 );
                return c;
            }

            if( policies_.empty() ) return Credential{};

            // Per-client credentials: the presented token's SHA-256 against
            // every entry. No early exit: the work per attempt stays the
            // same whether or not the hash matches.
            const std::string hex = sha256Hex( presented );
            Credential out;
            bool known = false;
            for( const PolicyEntry& e : policies_ )
            {
                if( e.sha256.size() != hex.size() ) continue;
                if( CRYPTO_memcmp( e.sha256.data(), hex.data(), hex.size() ) != 0 ) continue;
                known = true;
                if( e.expired() ) { out.expired = true; continue; }
                out.ok = true;
                out.clientName = e.name.empty() ? ( "client:" + hex.substr( 0, 8 ) ) : e.name;
                out.allow = e.allTools ? std::nullopt
                                       : std::optional<std::set<std::string>>( e.tools );
            }
            if( !known ) return Credential{};
            return out;
        }

        static std::string sha256Hex( const std::string& v )
        {
            unsigned char d[ SHA256_DIGEST_LENGTH ];
            SHA256( reinterpret_cast<const unsigned char*>( v.data() ), v.size(), d );
            static const char* const kHex = "0123456789abcdef";
            std::string out;
            for( int i = 0; i < SHA256_DIGEST_LENGTH; ++i )
            { out.push_back( kHex[ d[ i ] >> 4 ] ); out.push_back( kHex[ d[ i ] & 0xF ] ); }
            return out;
        }

        // A malformed policy file keeps the last good one and says so; the
        // caller surfaces the message at startup.
        std::string policyError()
        {
            std::lock_guard<std::mutex> lk( mu_ );
            return policyError_;
        }

    private:
        struct PolicyEntry
        {
            std::string name;
            std::string sha256;
            bool allTools = false;
            std::set<std::string> tools;
            std::time_t expiresAt = 0;      // 0 = never expires
            bool expired() const
            {
                if( expiresAt == 0 ) return false;
                return std::time( nullptr ) >= expiresAt;
            }
        };

        // Parses an ISO-8601 expiry: "YYYY-MM-DD" or
        // "YYYY-MM-DDTHH:MM:SSZ". Returns 0 when the text is not a usable
        // expiry, which the caller treats as "no expiry given".
        static std::time_t parseExpiry( const std::string& text )
        {
            if( text.size() < 10 ) return 0;
            std::tm tm{};
            int y = 0, mo = 0, d = 0, h = 0, mi = 0, se = 0;
            if( std::sscanf( text.c_str(), "%d-%d-%dT%d:%d:%d", &y, &mo, &d, &h, &mi, &se ) < 3 &&
                std::sscanf( text.c_str(), "%d-%d-%d", &y, &mo, &d ) < 3 )
                return 0;
            if( y < 1970 || mo < 1 || mo > 12 || d < 1 || d > 31 ) return 0;
            tm.tm_year = y - 1900; tm.tm_mon = mo - 1; tm.tm_mday = d;
            tm.tm_hour = h; tm.tm_min = mi; tm.tm_sec = se;
            return utcToTimeT( tm );
        }

        // UTC calendar time -> time_t. timegm() is POSIX; the MSVC CRT has
        // _mkgmtime() instead.
#if defined( _WIN32 )
        static std::time_t utcToTimeT( std::tm& tm )
        { return static_cast<std::time_t>( _mkgmtime( &tm ) ); }
#else
        static std::time_t utcToTimeT( std::tm& tm )
        { return timegm( &tm ); }
#endif

        void loadPolicyLocked()
        {
            if( cfg_.tokenPolicyFile.empty() ) return;
            std::ifstream in( cfg_.tokenPolicyFile, std::ios::binary );
            if( !in ) { policyError_ = "cannot read " + cfg_.tokenPolicyFile; return; }
            const std::string text( ( std::istreambuf_iterator<char>( in ) ), std::istreambuf_iterator<char>() );
            std::vector<PolicyEntry> next;
            try
            {
                const Json doc = Json::parse( text );
                if( !doc.is_object() || !doc.contains( "tokens" ) || !doc.at( "tokens" ).is_array() )
                    throw std::runtime_error( "expected {\"tokens\":[...]}" );
                for( const Json& t : doc.at( "tokens" ) )
                {
                    PolicyEntry e;
                    if( t.contains( "name" ) && t.at( "name" ).is_string() ) e.name = t.at( "name" ).get<std::string>();
                    e.sha256 = t.at( "sha256" ).get<std::string>();
                    if( e.sha256.size() != 64 ) throw std::runtime_error( "sha256 must be 64 hex digits" );
                    for( char& c : e.sha256 ) c = static_cast<char>( std::tolower( static_cast<unsigned char>( c ) ) );
                    const Json& tools = t.at( "tools" );
                    if( tools.is_string() && tools.get<std::string>() == "*" ) e.allTools = true;
                    else if( tools.is_array() )
                        for( const Json& n : tools ) e.tools.insert( n.get<std::string>() );
                    else throw std::runtime_error( "tools must be \"*\" or an array of tool names" );
                    if( t.contains( "expires" ) && t.at( "expires" ).is_string() )
                    {
                        e.expiresAt = parseExpiry( t.at( "expires" ).get<std::string>() );
                        if( e.expiresAt == 0 )
                            throw std::runtime_error( "expires must be an ISO-8601 date/time (YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ)" );
                    }
                    next.push_back( std::move( e ) );
                }
            }
            catch( const std::exception& ex )
            {
                policyError_ = std::string( "FSQL_MCP_TOKEN_POLICY_FILE is not valid: " ) + ex.what();
                return;   // keep the last good policy
            }
            policies_ = std::move( next );
            policyError_.clear();
        }

        // reload() runs with mu_ held; the mtime hot reload happens whenever
        // check() is called on the file forms.
        void reload( bool force )
        {
            if( !cfg_.authTokenFile.empty() )
            {
                time_t cur = 0;
                if( fileMtime( cfg_.authTokenFile, cur ) )
                {
                    if( force || cur != tokenMtime_ )
                    {
                        std::ifstream in( cfg_.authTokenFile, std::ios::binary );
                        if( in )
                        {
                            std::string t;
                            std::getline( in, t );
                            while( !t.empty() && ( t.back() == '\r' || t.back() == '\n' ) ) t.pop_back();
                            // An unreadable or empty file never silently
                            // disables auth: the token is only replaced when
                            // the file yields one.
                            if( !t.empty() ) { token_ = t; tokenMtime_ = cur; }
                        }
                    }
                }
                // A file that vanished keeps the last known token.
            }
            else
                token_ = cfg_.authToken;    // plain env-var form: no hot-reload

            // The credential file is re-read whenever its timestamp changed
            // or on a forced reload (SIGHUP): it is small and holds no
            // secret. A file that cannot even be stat'ed is read anyway, so
            // the error says so: a credential file that cannot be read is a
            // startup failure, never a silent "no authentication".
            if( !cfg_.tokenPolicyFile.empty() )
            {
                time_t cur = 0;
                const bool haveMtime = fileMtime( cfg_.tokenPolicyFile, cur );
                if( !haveMtime || force || cur != policyMtime_ || !policyLoaded_ )
                {
                    loadPolicyLocked();
                    if( haveMtime ) policyMtime_ = cur;
                    policyLoaded_ = true;
                }
            }
            else if( !policyLoaded_ )
            {
                loadPolicyLocked();   // no file configured: clears any earlier error
                policyLoaded_ = true;
            }
        }

        HttpConfig cfg_;
        std::mutex mu_;
        std::string token_;
        time_t tokenMtime_ = 0;
        std::vector<PolicyEntry> policies_;
        std::string policyError_;
        bool policyLoaded_ = false;
        time_t policyMtime_ = 0;
    };

    // The startup check for the per-client credential file: a file that
    // cannot be read or parsed is a startup failure, never a silent "no
    // authentication".
    std::string tokenPolicyError( const HttpConfig& cfg )
    {
        TokenStore store( cfg );
        return store.policyError();
    }

    // SIGHUP means "reload the auth token", and that reload is file I/O plus
    // allocation. Doing that work inside the signal handler is not
    // async-signal-safe: it can deadlock against the malloc arena lock the
    // interrupted thread already held (observed as a TSan-reported hang
    // under a fully thread-instrumented build), and it can corrupt the
    // TokenStore's own mutex if the interrupted thread was inside reload().
    //
    // So the handler only sets a flag. The reload itself happens on the
    // ordinary request path (check() -> reload()), which is not signal
    // context and is free to block on I/O.
    static std::atomic<bool> g_httpSignalled{ false };
    // Set when the transport stops accepting new connections. A request that
    // arrives after that is answered with 503 rather than dispatched.
    static std::atomic<bool> g_httpDraining{ false };
    static void onHttpTermSignal( int ) { g_httpSignalled.store( true ); }

    // Most connections served at once. Each one holds a thread and a
    // descriptor before it has authenticated, so the count is bounded:
    // FSQL_MCP_MAX_CONNECTIONS overrides the default of 256, and on POSIX
    // the result never exceeds half the process's descriptor limit.
    static std::size_t maxConnections()
    {
        long n = 256;
        if( const char* v = std::getenv( "FSQL_MCP_MAX_CONNECTIONS" ) )
        {
            const long x = std::strtol( v, nullptr, 10 );
            if( x > 0 ) n = x;
        }
#ifndef _WIN32
        rlimit rl{};
        if( getrlimit( RLIMIT_NOFILE, &rl ) == 0 && rl.rlim_cur != RLIM_INFINITY && rl.rlim_cur > 8 )
            n = std::min<long>( n, static_cast<long>( rl.rlim_cur / 2 ) );
#endif
        return static_cast<std::size_t>( n );
    }

    // A refused connection is closed only after the peer's request has been
    // read and discarded, so the refusal itself is not lost. The window is
    // long enough for a client that is slow to write its request, and short
    // enough that a refused connection does not hold anything for long.
    static constexpr int kRefusalLingerMs = 1000;

    // How many refusals may be delivering themselves at once. A flood of
    // connections past the limit must not turn into a flood of threads.
    static constexpr int kMaxRefusalsInFlight = 64;

    // Bounds how long a read or write on this socket may block.
    static void setSocketTimeoutMs( int fd, int ms )
    {
#ifdef _WIN32
        DWORD v = static_cast<DWORD>( ms );
        setsockopt( fd, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>( &v ), sizeof( v ) );
        setsockopt( fd, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>( &v ), sizeof( v ) );
#else
        timeval tv{ ms / 1000, ( ms % 1000 ) * 1000 };
        setsockopt( fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof( tv ) );
        setsockopt( fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof( tv ) );
#endif
    }

    // Waits up to `ms` for a pending connection. A handler installed with
    // std::signal restarts a blocked accept(), so the accept loop waits here
    // in short slices and re-checks g_httpSignalled between them.
    static bool waitForConnection( int listenFd, int ms )
    {
#ifdef _WIN32
        WSAPOLLFD p{ static_cast<SOCKET>( listenFd ), POLLRDNORM, 0 };
        return WSAPoll( &p, 1, ms ) > 0;
#else
        pollfd p{ listenFd, POLLIN, 0 };
        return ::poll( &p, 1, ms ) > 0;
#endif
    }
#ifdef SIGHUP
    static void onSighup( int ) { g_sighupReload.store( true, std::memory_order_relaxed ); }
#endif

    // ---- the per-client state: protocol sessions and engine contexts ----
    //
    // Two kinds of entry live here:
    //
    //  - a protocol session (the legacy era's Mcp-Session-Id), which owns an
    //    engine context;
    //  - an engine context (the modern era's context_id handle), which owns a
    //    dedicated engine connection.
    //
    // Every context owns a server of its own, built over a connection of its
    // own: the connection is created with the read-only setting and the
    // destructive latch already applied, because the latch belongs to the
    // connection, not to the request.
    //
    // Both kinds are capped (FSQL_MCP_MAX_SESSIONS, default 64) and expire
    // when idle (FSQL_MCP_SESSION_TTL_SECS, default 3600), so the map -- and
    // the engine connections behind it -- cannot grow without bound. Every
    // context is bound to the fingerprint of the credential that created it:
    // another token is told the handle does not exist, so a client can
    // neither use nor probe for a handle it does not own.
    class ClientRegistry
    {
    public:
        struct Context
        {
            std::shared_ptr<JsonRpcServer> srv;
            std::string ownerFp;                                  // the fingerprint of the creating credential
            std::chrono::steady_clock::time_point lastUse;
        };
        struct Session
        {
            std::string contextId;                               // the engine context this session owns
            std::string clientKey;                               // the fairness key
            std::string ownerFp;
            std::chrono::steady_clock::time_point lastUse;
        };

        explicit ClientRegistry( const HttpConfig& cfg ) : cfg_( cfg ) {}

        // A new engine context: its own server over its own dedicated
        // connection. Throws Connectivity when the registry is full.
        std::string createContext( const std::string& ownerFp, std::shared_ptr<JsonRpcServer>& srvOut )
        {
            checkRoom();
            std::unique_ptr<JsonRpcServer> srv = cfg_.sessionFactory();
            const std::string id = mintHandle();
            std::lock_guard<std::mutex> lk( mu_ );
            srvOut = makeServer( std::move( srv ) );
            contexts_[ id ] = Context{ srvOut, ownerFp, std::chrono::steady_clock::now() };
            return id;
        }

        // The context a request names. Returns false when the handle does not
        // exist or belongs to another credential: the caller answers "not
        // found" either way.
        bool findContext( const std::string& id, const std::string& ownerFp,
                          std::shared_ptr<JsonRpcServer>& srvOut )
        {
            std::lock_guard<std::mutex> lk( mu_ );
            auto it = contexts_.find( id );
            if( it == contexts_.end() ) return false;
            if( it->second.ownerFp != ownerFp ) return false;
            it->second.lastUse = std::chrono::steady_clock::now();
            srvOut = it->second.srv;
            return true;
        }

        // The credential's own server: the connection a request that keeps no
        // engine state runs on. One per credential, created on demand.
        std::shared_ptr<JsonRpcServer> credentialServer( const std::string& ownerFp )
        {
            {
                std::lock_guard<std::mutex> lk( mu_ );
                auto it = credServers_.find( ownerFp );
                if( it != credServers_.end() )
                {
                    it->second.lastUse = std::chrono::steady_clock::now();
                    return it->second.srv;
                }
            }
            checkRoom();
            std::unique_ptr<JsonRpcServer> srv = cfg_.sessionFactory();
            std::lock_guard<std::mutex> lk( mu_ );
            auto it = credServers_.find( ownerFp );
            if( it != credServers_.end() )
            {
                it->second.lastUse = std::chrono::steady_clock::now();
                return it->second.srv;
            }
            auto sp = makeServer( std::move( srv ) );
            credServers_[ ownerFp ] = Context{ sp, ownerFp, std::chrono::steady_clock::now() };
            return sp;
        }

        // A protocol session and the engine context it owns.
        std::string createSession( const std::string& ownerFp, const std::string& clientKey,
                                   std::string& contextIdOut, std::shared_ptr<JsonRpcServer>& srvOut )
        {
            const std::string ctxId = createContext( ownerFp, srvOut );
            const std::string sid = mintHandle();
            std::lock_guard<std::mutex> lk( mu_ );
            sessions_[ sid ] = Session{ ctxId, clientKey, ownerFp, std::chrono::steady_clock::now() };
            contextIdOut = ctxId;
            return sid;
        }

        // The session a request names, with the context it owns. A session
        // belongs to the credential that created it: a request presenting a
        // different token (e.g. after a token rotation, or a second token)
        // neither sees nor tears it down, and gets the same "not found" as an
        // unknown id so existence is not revealed.
        bool findSession( const std::string& id, const std::string& ownerFp,
                          std::string& contextIdOut, std::shared_ptr<JsonRpcServer>& srvOut )
        {
            std::lock_guard<std::mutex> lk( mu_ );
            auto it = sessions_.find( id );
            if( it == sessions_.end() ) return false;
            if( it->second.ownerFp != ownerFp ) return false;
            auto cit = contexts_.find( it->second.contextId );
            if( cit == contexts_.end() ) return false;
            const auto now = std::chrono::steady_clock::now();
            it->second.lastUse = now;
            cit->second.lastUse = now;
            contextIdOut = it->second.contextId;
            srvOut = cit->second.srv;
            return true;
        }

        bool eraseSession( const std::string& id, const std::string& ownerFp )
        {
            std::shared_ptr<JsonRpcServer> dead;
            {
                std::lock_guard<std::mutex> lk( mu_ );
                auto it = sessions_.find( id );
                if( it == sessions_.end() ) return false;
                if( it->second.ownerFp != ownerFp ) return false;
                auto cit = contexts_.find( it->second.contextId );
                if( cit != contexts_.end() ) { dead = cit->second.srv; contexts_.erase( cit ); }
                sessions_.erase( it );
            }
            dead.reset();    // the context's connection closes here
            return true;
        }

        static std::size_t maxSessions()
        {
            const char* v = std::getenv( "FSQL_MCP_MAX_SESSIONS" );
            const long n = v && *v ? std::atol( v ) : 64;
            return n > 0 ? static_cast<std::size_t>( n ) : 64;
        }
        static std::chrono::seconds sessionTtl()
        {
            const char* v = std::getenv( "FSQL_MCP_SESSION_TTL_SECS" );
            const long n = v && *v ? std::atol( v ) : 3600;
            return std::chrono::seconds( n > 0 ? n : 3600 );
        }

        // Drops the idle entries. The servers of the expired entries are
        // returned so the caller can destroy them (and close their
        // connections) outside the lock.
        std::vector<std::shared_ptr<JsonRpcServer>> evictIdle()
        {
            std::lock_guard<std::mutex> lk( mu_ );
            return evictIdleLocked();
        }

        void endAll()
        {
            std::map<std::string, Context> deadCtx;
            std::map<std::string, Session> deadSes;
            {
                std::lock_guard<std::mutex> lk( mu_ );
                deadCtx.swap( contexts_ );
                deadSes.swap( sessions_ );
                credServers_.clear();
            }
            deadCtx.clear();
            deadSes.clear();
        }

    private:
        // A handle: 128 bits of randomness, hex.
        static std::string mintHandle()
        {
            unsigned char rnd[ 16 ] = {};
            if( RAND_bytes( rnd, sizeof( rnd ) ) != 1 )
            {
                RAND_poll();
                (void) RAND_bytes( rnd, sizeof( rnd ) );
            }
            static const char* const kHex = "0123456789abcdef";
            std::string out;
            for( unsigned char c : rnd )
            {
                out.push_back( kHex[ c >> 4 ] );
                out.push_back( kHex[ c & 0xF ] );
            }
            return out;
        }

        // The registry is bounded: every entry pins a dedicated engine
        // connection, and an entry that is only removed by an explicit DELETE
        // would otherwise grow without bound.
        void checkRoom()
        {
            std::lock_guard<std::mutex> lk( mu_ );
            evictIdleLocked();
            if( contexts_.size() + credServers_.size() >= maxSessions() )
                throw ToolError( ErrorClass::Connectivity, "too many open MCP sessions" );
        }

        std::vector<std::shared_ptr<JsonRpcServer>> evictIdleLocked()
        {
            std::vector<std::shared_ptr<JsonRpcServer>> dead;
            const auto now = std::chrono::steady_clock::now();
            const auto ttl = sessionTtl();
            for( auto it = sessions_.begin(); it != sessions_.end(); )
                it = ( now - it->second.lastUse > ttl ) ? sessions_.erase( it ) : std::next( it );
            for( auto it = contexts_.begin(); it != contexts_.end(); )
            {
                if( now - it->second.lastUse > ttl ) { dead.push_back( it->second.srv ); it = contexts_.erase( it ); }
                else ++it;
            }
            for( auto it = credServers_.begin(); it != credServers_.end(); )
            {
                if( now - it->second.lastUse > ttl ) { dead.push_back( it->second.srv ); it = credServers_.erase( it ); }
                else ++it;
            }
            return dead;
        }

        // The teardown callback is tied to the SERVER's own destruction, not
        // to the removal of the map slot: that is the only ordering that
        // holds when an in-flight request still holds the server alive, and
        // it is the order the config documents ("after its server is
        // destroyed"). The callback is copied into the deleter so the
        // deleter does not depend on this registry's lifetime.
        std::shared_ptr<JsonRpcServer> makeServer( std::unique_ptr<JsonRpcServer> srv )
        {
            auto teardown = cfg_.sessionTeardown;
            return std::shared_ptr<JsonRpcServer>( srv.release(),
                [ teardown ]( JsonRpcServer* p )
                {
                    delete p;
                    if( teardown ) teardown();
                } );
        }

        HttpConfig cfg_;
        std::mutex mu_;
        std::map<std::string, Context> contexts_;
        std::map<std::string, Context> credServers_;   // the credential's own connection
        std::map<std::string, Session> sessions_;
    };

    // Non-reversible fingerprint of the presented bearer token (never log or return it).
    static std::string tokenFingerprint( const std::string& bearer )
    {
        unsigned char d[ SHA256_DIGEST_LENGTH ];
        SHA256( reinterpret_cast<const unsigned char*>( bearer.data() ), bearer.size(), d );
        static const char* const kHex = "0123456789abcdef";
        std::string out;
        for( int i = 0; i < 16; ++i ) { out.push_back( kHex[ d[ i ] >> 4 ] ); out.push_back( kHex[ d[ i ] & 0xF ] ); }
        return out;
    }

    static std::string clientKeyFor( const std::string& bearer, const std::string& sessionId )
    {
        // Session id when the deployment uses the file-token form, a raw
        // token prefix would collapse per-client fairness to one bucket when
        // the whole team shares one static token.
        return sessionId.empty() ? ( "token:" + bearer.substr( 0, 8 ) ) : ( "session:" + sessionId );
    }

    // ---- wire abstraction: plain socket or OpenSSL TLS BIO ----
    struct Wire
    {
        virtual ~Wire() = default;
        virtual int sendAll( const char* data, std::size_t len ) = 0;
        virtual int recvSome( char* buf, std::size_t max ) = 0;
        virtual void closeWire() = 0;
        virtual void setTimeoutMs( int ms ) = 0;
    };
    using WirePtr = std::unique_ptr<Wire>;

    class PlainWire : public Wire
    {
    public:
        explicit PlainWire( int fd ) : fd_( fd ) {}
        int sendAll( const char* data, std::size_t len ) override
        {
            std::size_t off = 0;
            while( off < len )
            {
                const int n = ::send( fd_, data + off, static_cast<int>( len - off ), 0 );
                if( n <= 0 ) return -1;
                off += static_cast<std::size_t>( n );
            }
            return 0;
        }
        int recvSome( char* buf, std::size_t max ) override
        {
            return static_cast<int>( ::recv( fd_, buf, static_cast<int>( max ), 0 ) );
        }
        void closeWire() override { if( fd_ >= 0 ) { fsqlCloseSocket( fd_ ); fd_ = -1; } }
        void setTimeoutMs( int ms ) override { if( fd_ >= 0 ) setSocketTimeoutMs( fd_, ms ); }
    private:
        int fd_ = -1;
    };

    class TlsWire : public Wire
    {
    public:
        TlsWire( int fd, SSL_CTX* ctx ) : ssl_( SSL_new( ctx ) ), fd_( fd )
        {
            if( ssl_ ) SSL_set_fd( ssl_, fd );
        }
        bool ok() const { return ssl_ != nullptr; }
        bool accept() { return SSL_accept( ssl_ ) == 1; }
        int sendAll( const char* data, std::size_t len ) override
        {
            std::size_t off = 0;
            while( off < len )
            {
                const int n = SSL_write( ssl_, data + off, static_cast<int>( len - off ) );
                if( n <= 0 ) return -1;
                off += static_cast<std::size_t>( n );
            }
            return 0;
        }
        int recvSome( char* buf, std::size_t max ) override
        {
            return SSL_read( ssl_, buf, static_cast<int>( max ) );
        }
        void closeWire() override { if( ssl_ ) { SSL_shutdown( ssl_ ); SSL_free( ssl_ ); ssl_ = nullptr; } }
        void setTimeoutMs( int ms ) override { setSocketTimeoutMs( fd_, ms ); }
    private:
        SSL* ssl_ = nullptr;
        int fd_ = -1;
    };

    struct HttpRequest
    {
        std::string method, target, bearer, sessionId;
        std::string body;
        bool keepAlive = true;
        // The framing of the body, taken from the headers. The body
        // itself is read separately, after the request is authenticated.
        std::size_t contentLength = 0;
        bool chunked = false;
        bool malformed = false;    // framing the server refuses; answered with 400
        // How many body bytes were read from the socket. A request that was
        // answered before its body was needed leaves the rest of the body
        // in the socket, and it has to be drained before the connection is
        // closed.
        std::size_t bodyBytesRead = 0;

        // The headers the modern protocol era requires: the revision, the
        // method and (for the methods that address something by name) the
        // name. An unknown header is simply ignored.
        std::string protocolVersion, mcpMethod, mcpName;
        // The browser origin, when the request carries one.
        std::string origin;
    };

    // Trims the surrounding whitespace (spaces, tabs, carriage returns and
    // newlines) off a value that came off the wire.
    static std::string trimValue( const std::string& s )
    {
        const auto isWs = []( char c ) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; };
        std::size_t b = 0, e = s.size();
        while( b < e && isWs( s[ b ] ) ) ++b;
        while( e > b && isWs( s[ e - 1 ] ) ) --e;
        return s.substr( b, e - b );
    }

    static std::string lowerValue( const std::string& s )
    {
        std::string out = s;
        for( char& c : out ) c = static_cast<char>( std::tolower( static_cast<unsigned char>( c ) ) );
        return out;
    }

    // The path of a request target: everything before the query string.
    static std::string pathOf( const std::string& target )
    {
        const std::size_t q = target.find( '?' );
        return ( q == std::string::npos ) ? target : target.substr( 0, q );
    }

    static const char* statusText( int code )
    {
        switch( code )
        {
            case 200: return "OK";
            case 202: return "Accepted";
            case 400: return "Bad Request";
            case 401: return "Unauthorized";
            case 403: return "Forbidden";
            case 404: return "Not Found";
            case 405: return "Method Not Allowed";
            case 411: return "Length Required";
            case 413: return "Payload Too Large";
            case 500: return "Internal Server Error";
            case 503: return "Service Unavailable";
            default:  return "Status";
        }
    }

    // One response: the status line, the headers, the body. Every response
    // says "Connection: close": the server writes one reply per connection
    // and closes the socket after it.
    static void sendHttp( Wire& w, int status, const std::string& body, const std::string& contentType,
                          const std::vector<std::pair<std::string, std::string>>& extra = {} )
    {
        std::ostringstream h;
        h << "HTTP/1.1 " << status << ' ' << statusText( status ) << "\r\n";
        if( !contentType.empty() ) h << "Content-Type: " << contentType << "\r\n";
        h << "Content-Length: " << body.size() << "\r\n";
        for( const auto& kv : extra ) h << kv.first << ": " << kv.second << "\r\n";
        h << "Connection: close\r\n\r\n";
        const std::string head = h.str();
        w.sendAll( head.data(), head.size() );
        if( !body.empty() ) w.sendAll( body.data(), body.size() );
    }

    static void sendJson( Wire& w, int status, const Json& body,
                          const std::vector<std::pair<std::string, std::string>>& extra = {} )
    {
        sendHttp( w, status, body.dump(), "application/json", extra );
    }

    static void sendStatus( Wire& w, int code, const char* text )
    {
        std::ostringstream h;
        h << "HTTP/1.1 " << code << ' ' << text << "\r\nContent-Length: 0\r\n"
          << "Content-Type: application/json\r\nConnection: close\r\n\r\n";
        const std::string s = h.str();
        w.sendAll( s.data(), s.size() );
    }

    // A JSON-RPC error body for a refusal that happened before the request
    // reached the dispatch core. There is no id to correlate it with, so the
    // body carries none.
    static std::string rpcErrorBody( int code, const std::string& message, const Json& data = Json() )
    {
        Json err{ { "code", code }, { "message", message } };
        if( !data.is_null() ) err[ "data" ] = data;
        return Json{ { "jsonrpc", "2.0" }, { "error", err } }.dump();
    }

    static void sendRpcError( Wire& w, int status, int code, const std::string& message,
                              const Json& data = Json() )
    {
        sendHttp( w, status, rpcErrorBody( code, message, data ), "application/json" );
    }

    // The RFC 6750 challenge a 401 carries. No scope and no
    // resource_metadata: this server authenticates one bearer token (or a
    // per-client credential from the policy file) and does not implement
    // the OAuth 2.1 resource-server flow.
    static const char* const kAuthRealm = "Bearer realm=\"fractalsql-mcp\"";

    // The 401 for a missing or a refused credential. A token that WAS
    // presented but is wrong or expired says so in the challenge; the
    // presented value itself is never logged.
    static void sendUnauthorized( Wire& w, bool presented )
    {
        std::vector<std::pair<std::string, std::string>> extra;
        extra.emplace_back( "WWW-Authenticate", std::string( kAuthRealm ) +
            ( presented ? ", error=\"invalid_token\"" : "" ) );
        sendJson( w, 401, Json{ { "error", presented ? "invalid bearer token" : "missing bearer token" } }, extra );
    }

    // True for an IPv4 address in 127.0.0.0/8, parsed as an address: a name that merely starts with "127." (127.evil.example,
    // 127.0.0.1.nip.io) is not one (SECURITY_AUDIT.md 3.17).
    static bool isLoopbackV4( const std::string& host )
    {
        in_addr addr{};
        return inet_pton( AF_INET, host.c_str(), &addr ) == 1 && ( ntohl( addr.s_addr ) >> 24 ) == 127;
    }

    // True when the origin names a loopback host. The host part is what
    // matters: a page served from http://127.0.0.1:3000 is a loopback
    // origin whatever its port.
    static bool originIsLoopback( const std::string& origin )
    {
        const std::size_t sep = origin.find( "://" );
        if( sep == std::string::npos ) return false;
        std::string host = origin.substr( sep + 3 );
        const std::size_t slash = host.find( '/' );
        if( slash != std::string::npos ) host = host.substr( 0, slash );
        if( !host.empty() && host.front() == '[' )
        {
            const std::size_t close = host.find( ']' );
            if( close == std::string::npos ) return false;
            const std::string inner = host.substr( 1, close - 1 );
            return inner == "::1";
        }
        const std::size_t colon = host.rfind( ':' );
        if( colon != std::string::npos ) host = host.substr( 0, colon );
        if( host == "localhost" ) return true;
        if( isLoopbackV4( host ) ) return true;
        return false;
    }

    // An Origin header, when present, must be one this deployment allows:
    // a loopback origin by default, plus whatever FSQL_MCP_ALLOWED_ORIGINS
    // lists (browser tools such as the MCP Inspector need their origin
    // there). A request with no Origin header is not a browser request and
    // is allowed through.
    static bool originAllowed( const std::string& origin, const HttpConfig& cfg )
    {
        if( origin.empty() ) return true;
        if( originIsLoopback( origin ) ) return true;
        const std::string o = lowerValue( trimValue( origin ) );
        for( const std::string& allowed : cfg.allowedOrigins )
            if( lowerValue( trimValue( allowed ) ) == o ) return true;
        return false;
    }

    // base64 decode, for the Mcp-Name header's "=?base64?...?=" form.
    static std::string base64Decode( const std::string& in )
    {
        if( in.empty() ) return std::string();
        // The decoder counts the padding characters as decoded bytes, so it
        // reports a length that is too long by the number of trailing '=' in
        // the INPUT. The padding is then dropped from the decoded value.
        // (Looking for '=' in the OUTPUT does nothing: the output holds the
        // decoded bytes, not the padding.)
        std::size_t pad = 0;
        while( pad < in.size() && in[ in.size() - 1 - pad ] == '=' ) ++pad;
        std::string out( ( in.size() / 4 + 1 ) * 3 + 3, '\0' );
        const int n = EVP_DecodeBlock( reinterpret_cast<unsigned char*>( &out[ 0 ] ),
                                       reinterpret_cast<const unsigned char*>( in.data() ),
                                       static_cast<int>( in.size() ) );
        if( n < 0 ) return std::string();
        std::size_t len = static_cast<std::size_t>( n );
        len = ( len >= pad ) ? len - pad : 0;
        out.resize( len );
        return out;
    }

    // The Mcp-Name header may carry the name in the base64 form the spec
    // allows. Decoded, it is the same string; a value that is not in that
    // form is taken literally.
    static std::string decodeMcpName( const std::string& raw )
    {
        static const std::string kPrefix = "=?base64?";
        const std::string v = trimValue( raw );
        if( v.rfind( kPrefix, 0 ) != 0 ) return v;
        const std::size_t end = v.rfind( "?=" );
        if( end == std::string::npos || end < kPrefix.size() ) return std::string();
        // The payload starts after the prefix and runs to the closing "?=":
        // both the start and the length come from the prefix's own length.
        std::string b64 = v.substr( kPrefix.size(), end - kPrefix.size() );
        for( char& c : b64 ) { if( c == '-' ) c = '+'; else if( c == '_' ) c = '/'; }
        while( b64.size() % 4 != 0 ) b64.push_back( '=' );
        return base64Decode( b64 );
    }

    // The modern era's per-request protocol version, carried in the body's
    // _meta. The spec names it
    // _meta.io.modelcontextprotocol/protocolVersion; the nested spelling is
    // accepted too, because a client that builds _meta as a tree rather
    // than as a namespaced key produces that.
    static std::string modernMetaVersion( const Json& body )
    {
        if( !body.is_object() ) return std::string();
        auto meta = body.find( "_meta" );
        if( meta == body.end() || !meta->is_object() ) return std::string();
        auto it = meta->find( "io.modelcontextprotocol/protocolVersion" );
        if( it != meta->end() && it->is_string() ) return it->get<std::string>();
        auto ns = meta->find( "io.modelcontextprotocol" );
        if( ns != meta->end() && ns->is_object() )
        {
            auto v = ns->find( "protocolVersion" );
            if( v != ns->end() && v->is_string() ) return v->get<std::string>();
        }
        return std::string();
    }

    // A string field of the request's params, or "" when it is absent or
    // not a string. Never throws on a wrongly typed params object.
    static std::string paramsString( const Json& body, const std::string& key )
    {
        auto p = body.find( "params" );
        if( p == body.end() || !p->is_object() ) return std::string();
        auto v = p->find( key );
        if( v == p->end() || !v->is_string() ) return std::string();
        return v->get<std::string>();
    }

    // The context handle a request names, read from the arguments of the
    // call (never from the params object itself).
    static std::string paramsContextId( const Json& body )
    {
        auto p = body.find( "params" );
        if( p == body.end() || !p->is_object() ) return std::string();
        auto a = p->find( "arguments" );
        if( a == p->end() || !a->is_object() ) return std::string();
        auto c = a->find( "context_id" );
        if( c == a->end() || !c->is_string() ) return std::string();
        return c->get<std::string>();
    }

    // The JSON-RPC methods this server answers. A modern request naming
    // anything else is answered with 404 and -32601; a legacy request keeps
    // the legacy behaviour (the dispatch core answers -32601).
    static bool isKnownRpcMethod( const std::string& m )
    {
        static const char* const kMethods[] = {
            "initialize", "ping", "tools/list", "tools/call",
            "resources/list", "resources/read", "resources/templates/list",
            "prompts/list", "prompts/get", "server/discover", "logging/setLevel",
            "notifications/initialized", "notifications/cancelled", "$/cancel"
        };
        for( const char* k : kMethods ) if( m == k ) return true;
        return false;
    }

    // The outcome of validating a modern-era request's headers against its
    // body.
    struct ModernCheck
    {
        bool ok = true;
        int httpStatus = 200;
        int code = 0;                 // the JSON-RPC error code, 0 = no error
        std::string message;
        Json data = Json();           // the error's data, when it carries any
    };

    // A modern protocol era request must carry MCP-Protocol-Version,
    // Mcp-Method and, where the method addresses something by name,
    // Mcp-Name; and the headers must agree with the body. A disagreement
    // is -32020 (HeaderMismatch), an unsupported revision is -32022
    // (UnsupportedProtocolVersionError).
    static ModernCheck validateModernRequest( const HttpRequest& req, const Json& body,
                                               const std::string& bodyMethod )
    {
        ModernCheck out;

        if( req.protocolVersion.empty() )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32020;
            out.message = "missing MCP-Protocol-Version header: a modern protocol era request "
                          "must name the revision it speaks";
            return out;
        }
        const std::string headerVersion = trimValue( req.protocolVersion );
        const auto& versions = modernProtocolVersions();
        if( std::find( versions.begin(), versions.end(), headerVersion ) == versions.end() )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32022;
            out.message = "unsupported protocol version: " + headerVersion;
            Json supported = Json::array();
            for( const std::string& v : versions ) supported.push_back( v );
            out.data = Json{ { "supported", supported }, { "requested", headerVersion } };
            return out;
        }

        const std::string bodyVersion = modernMetaVersion( body );
        if( bodyVersion.empty() )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32020;
            out.message = "missing _meta.io.modelcontextprotocol/protocolVersion: a modern protocol "
                          "era request carries its revision in the body as well as in the header";
            return out;
        }
        if( bodyVersion != headerVersion )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32020;
            out.message = "header and body disagree about the protocol version: header says "
                          + headerVersion + ", body says " + bodyVersion;
            return out;
        }

        if( req.mcpMethod.empty() )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32020;
            out.message = "missing Mcp-Method header: a modern protocol era request must name its method";
            return out;
        }
        if( trimValue( req.mcpMethod ) != bodyMethod )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32020;
            out.message = "header and body disagree about the method: header says '"
                          + trimValue( req.mcpMethod ) + "', body says '" + bodyMethod + "'";
            return out;
        }

        // Mcp-Name, for the methods that address something by name.
        std::string expectedName;
        bool nameRequired = false;
        if( bodyMethod == "tools/call" || bodyMethod == "prompts/get" )
        {
            expectedName = paramsString( body, "name" );
            nameRequired = true;
        }
        else if( bodyMethod == "resources/read" )
        {
            expectedName = paramsString( body, "uri" );
            nameRequired = true;
        }
        if( nameRequired )
        {
            if( req.mcpName.empty() )
            {
                out.ok = false; out.httpStatus = 400; out.code = -32020;
                out.message = "missing Mcp-Name header: " + bodyMethod + " must name what it addresses";
                return out;
            }
            const std::string headerName = decodeMcpName( req.mcpName );
            if( headerName != expectedName )
            {
                out.ok = false; out.httpStatus = 400; out.code = -32020;
                out.message = "header and body disagree about the name: header says '" + headerName
                              + "', body says '" + expectedName + "'";
                return out;
            }
        }
        return out;
    }

    // Resolves the configured bind address into addr. Accepts a literal
    // IPv4 dotted quad, the two loopback spellings, and the empty string
    // (which means "the loopback interface" -- the documented default).
    // Anything else is refused rather than silently widened to INADDR_ANY:
    // a bind address an operator mistyped must fail loudly at startup, not
    // quietly listen on every interface.
    static bool resolveBindAddr( const std::string& host, sockaddr_in& addr )
    {
        std::string h = host;
        // Trim surrounding whitespace: a value arriving from a config file
        // or a shell variable routinely carries a stray newline.
        while( !h.empty() && ( h.front() == ' ' || h.front() == '\t' || h.front() == '\r' || h.front() == '\n' ) )
            h.erase( h.begin() );
        while( !h.empty() && ( h.back() == ' ' || h.back() == '\t' || h.back() == '\r' || h.back() == '\n' ) )
            h.pop_back();
        if( h.empty() || h == "localhost" || h == "127.0.0.1" )
        {
            addr.sin_addr.s_addr = htonl( INADDR_LOOPBACK );
            return true;
        }
        if( h == "*" || h == "0.0.0.0" )
        {
            addr.sin_addr.s_addr = htonl( INADDR_ANY );
            return true;
        }
        in_addr parsed{};
        if( inet_pton( AF_INET, h.c_str(), &parsed ) == 1 )
        {
            addr.sin_addr = parsed;
            return true;
        }
        return false;
    }

    // Reads one HTTP request HEAD (the request line and the headers);
    // returns false on EOF/empty. The body is read separately, AFTER
    // the request has been authenticated -- see readRequestBody.
    //
    // Splitting the two is deliberate. The body is up to 32 MiB, and a
    // client that has not authenticated yet should not be able to make
    // the server hold that much memory per connection: the head is
    // bounded by the per-line caps below, so an unauthenticated
    // connection can only ever cost the server a few tens of KiB.
    static bool readRequestHead( Wire& w, HttpRequest& out )
    {
        // The whole head, not just each line, is bounded: an unauthenticated
        // client must not be able to keep a thread reading headers forever.
        constexpr std::size_t kHeadMax = 64 * 1024;
        constexpr int kMaxHeaders = 100;
        std::size_t headBytes = 0;
        std::string buf;
        auto readLine = [&]( std::string& line, std::size_t cap ) -> bool
        {
            std::size_t nl;
            while( ( nl = buf.find( '\n' ) ) == std::string::npos )
            {
                if( buf.size() > cap || ++headBytes > kHeadMax ) return false;
                char tmp[ 1 ];
                const int n = w.recvSome( tmp, sizeof( tmp ) );
                if( n <= 0 ) return false;
                buf.append( tmp, static_cast<std::size_t>( n ) );
            }
            line = buf.substr( 0, nl );
            if( !line.empty() && line.back() == '\r' ) line.pop_back();
            buf.erase( 0, nl + 1 );
            return true;
        };

        std::string head;
        if( !readLine( head, 16 * 1024 ) ) return false;
        {
            std::istringstream sl( head );
            sl >> out.method >> out.target;
        }
        auto trim = []( std::string s )
        {
            const auto isWs = []( char c ) { return c == ' ' || c == '\t'; };
            while( !s.empty() && isWs( s.front() ) ) s.erase( s.begin() );
            while( !s.empty() && isWs( s.back() ) ) s.pop_back();
            return s;
        };
        std::string h;
        int headerCount = 0;
        bool sawLength = false, sawEncoding = false;
        std::set<std::string> seenHeaders;
        while( readLine( h, 64 * 1024 ) && !h.empty() )
        {
            if( ++headerCount > kMaxHeaders ) return false;
            std::string lower = h;
            for( char& c : lower ) c = static_cast<char>( std::tolower( static_cast<unsigned char>( c ) ) );
            {
                const std::size_t colonAt = lower.find( ':' );
                if( colonAt != std::string::npos )
                {
                    std::string name = lower.substr( 0, colonAt );
                    while( !name.empty() && ( name.back() == ' ' || name.back() == '\t' ) ) name.pop_back();
                    if( !seenHeaders.insert( name ).second && isSingleValuedHeader( name ) ) { out.malformed = true; return false; }
                }
            }
            if( lower.rfind( "authorization: bearer ", 0 ) == 0 )
                out.bearer = trimValue( h.substr( 22 ) );
            else if( lower.rfind( "mcp-session-id:", 0 ) == 0 )
            {
                std::size_t s = 15;
                while( s < h.size() && h[ s ] == ' ' ) ++s;
                out.sessionId = trimValue( h.substr( s ) );
            }
            else if( lower.rfind( "origin:", 0 ) == 0 )
                out.origin = trimValue( h.substr( 7 ) );
            else if( lower.rfind( "mcp-protocol-version:", 0 ) == 0 )
                out.protocolVersion = trimValue( h.substr( 21 ) );
            else if( lower.rfind( "mcp-method:", 0 ) == 0 )
                out.mcpMethod = trimValue( h.substr( 11 ) );
            else if( lower.rfind( "mcp-name:", 0 ) == 0 )
                out.mcpName = trimValue( h.substr( 9 ) );
            else if( lower.rfind( "content-length:", 0 ) == 0 )
            {
                // Exactly one Content-Length, digits only: anything else is a
                // framing error, not a different length.
                const std::string v = trim( h.substr( 15 ) );
                const bool digits = !v.empty() && v.size() <= 12 &&
                    std::all_of( v.begin(), v.end(), []( char c ) { return c >= '0' && c <= '9'; } );
                if( sawLength || !digits ) { out.malformed = true; return false; }
                sawLength = true;
                out.contentLength = static_cast<std::size_t>( std::strtoull( v.c_str(), nullptr, 10 ) );
            }
            else if( lower.rfind( "transfer-encoding:", 0 ) == 0 )
            {
                // Only a plain "chunked" is understood; any other coding would
                // be framed differently here than by a proxy in front.
                if( sawEncoding || trim( lower.substr( 18 ) ) != "chunked" ) { out.malformed = true; return false; }
                sawEncoding = true;
                out.chunked = true;
            }
            else if( lower.rfind( "connection: close", 0 ) == 0 )
                out.keepAlive = false;
            // Every other header is simply ignored: an unknown request
            // header never changes what the server does.
        }
        if( sawLength && sawEncoding ) { out.malformed = true; return false; }
        return !out.method.empty();
    }

    // Reads the request BODY into `out`. Returns false on EOF; throws
    // when the body exceeds the 32 MiB cap.
    //
    // A chunked body never reaches this function: the framing has no length,
    // so the request is answered with 411 before the body is read.
    static bool readRequestBody( Wire& w, HttpRequest& out )
    {
        // The line reader is a local copy of readRequestHead's: the head
        // and the body are read at different times, so the head's
        // leftover bytes are not carried over.
        std::string buf;
        auto readLine = [&]( std::string& line, std::size_t cap ) -> bool
        {
            std::size_t nl;
            while( ( nl = buf.find( '\n' ) ) == std::string::npos )
            {
                if( buf.size() > cap ) return false;
                char tmp[ 1 ];
                const int n = w.recvSome( tmp, sizeof( tmp ) );
                if( n <= 0 ) return false;
                buf.append( tmp, static_cast<std::size_t>( n ) );
            }
            line = buf.substr( 0, nl );
            if( !line.empty() && line.back() == '\r' ) line.pop_back();
            buf.erase( 0, nl + 1 );
            return true;
        };

        if( out.contentLength > 0 )
        {
            if( out.contentLength > kBodyMax )
                throw ToolError( ErrorClass::Connectivity, "request body exceeds the 32 MiB cap" );
            out.body.resize( out.contentLength );
            std::size_t got = 0;
            while( got < out.contentLength )
            {
                const int n = w.recvSome( &out.body[ got ], out.contentLength - got );
                if( n <= 0 ) return false;
                got += static_cast<std::size_t>( n );
            }
            out.bodyBytesRead = got;
        }
        return true;
    }

    // Reads and discards a body the server did not need: the request was
    // answered before the body was read (a refused credential, a refused
    // origin, a chunked body), so the rest of it is still in the socket.
    //
    // Draining it matters to the client. Closing a socket that still holds
    // unread data makes the operating system reset the connection instead
    // of ending it cleanly, and a client that is waiting for the answer
    // then sees a connection reset where it should see the response.
    static void drainChunkedBody( Wire& w )
    {
        constexpr std::size_t kDrainMax = 8u * 1024 * 1024;
        std::string buf;
        auto readLine = [&]( std::string& line ) -> bool
        {
            std::size_t nl;
            while( ( nl = buf.find( '\n' ) ) == std::string::npos )
            {
                if( buf.size() > 4096 ) return false;
                char tmp[ 1 ];
                const int n = w.recvSome( tmp, sizeof( tmp ) );
                if( n <= 0 ) return false;
                buf.append( tmp, static_cast<std::size_t>( n ) );
            }
            line = buf.substr( 0, nl );
            if( !line.empty() && line.back() == '\r' ) line.pop_back();
            buf.erase( 0, nl + 1 );
            return true;
        };
        std::vector<char> sink( 8192 );
        std::size_t total = 0;
        for( int chunk = 0; chunk < 4096; ++chunk )
        {
            std::string sizeLine;
            if( !readLine( sizeLine ) ) return;
            const std::size_t semi = sizeLine.find( ';' );   // a chunk extension
            if( semi != std::string::npos ) sizeLine = sizeLine.substr( 0, semi );
            sizeLine = trimValue( sizeLine );
            if( sizeLine.empty() ) return;
            std::size_t size = 0;
            for( char c : sizeLine )
            {
                int digit;
                if( c >= '0' && c <= '9' ) digit = c - '0';
                else if( c >= 'a' && c <= 'f' ) digit = c - 'a' + 10;
                else if( c >= 'A' && c <= 'F' ) digit = c - 'A' + 10;
                else return;    // not a chunk size: the framing is not what it claims to be
                size = size * 16 + static_cast<std::size_t>( digit );
            }
            if( size == 0 )
            {
                std::string trailer;
                readLine( trailer );   // the trailer of the last chunk
                return;
            }
            total += size;
            if( total > kDrainMax ) return;
            std::size_t left = size;
            while( left > 0 )
            {
                const std::size_t want = ( left < sink.size() ) ? left : sink.size();
                const int n = w.recvSome( sink.data(), want );
                if( n <= 0 ) return;
                left -= static_cast<std::size_t>( n );
            }
            std::string crlf;
            if( !readLine( crlf ) ) return;
        }
    }

    // Reads and discards whatever the client has already sent and the
    // server has not read, until the socket goes quiet.
    //
    // This is the drain for a request whose framing is REFUSED. The body
    // length such a request announces cannot be believed -- a repeated
    // Content-Length says two different lengths, a malformed one says
    // something that is not a length at all -- so counting to one of them
    // would leave the rest of the body in the socket. Closing a socket
    // that still holds unread data makes the operating system reset the
    // connection instead of ending it, and the client then loses the
    // refusal it was supposed to read.
    //
    // The connection carries one request, so nothing that follows the
    // refused one can be mistaken for a second request: the bytes are
    // read and thrown away until the client stops sending.
    static void drainToQuiet( Wire& w )
    {
        constexpr std::size_t kDrainMax = 1u * 1024 * 1024;
        std::vector<char> sink( 8192 );
        std::size_t total = 0;
        w.setTimeoutMs( 250 );
        while( total < kDrainMax )
        {
            const int n = w.recvSome( sink.data(), sink.size() );
            if( n <= 0 ) return;    // the client stopped sending, or the read timed out
            total += static_cast<std::size_t>( n );
        }
    }

    // Reads and discards a body the server did not need: the request was
    // answered before the body was read (a refused credential, a refused
    // origin, a chunked body), so the rest of it is still in the socket.
    static void drainUnreadBody( Wire& w, const HttpRequest& req )
    {
        if( req.chunked ) { drainChunkedBody( w ); return; }
        if( req.contentLength <= req.bodyBytesRead ) return;
        std::size_t left = req.contentLength - req.bodyBytesRead;
        std::vector<char> sink( 8192 );
        while( left > 0 )
        {
            const std::size_t want = ( left < sink.size() ) ? left : sink.size();
            const int n = w.recvSome( sink.data(), want );
            if( n <= 0 ) return;    // the client stopped sending; there is nothing left to drain
            left -= static_cast<std::size_t>( n );
        }
    }

    // ---- request handling, split by concern ----
    //
    // Each helper below handles one decision and returns whether the
    // connection may continue. Keeping them separate (rather than one
    // long function with inline `break`s) is what makes the
    // one-request-per-connection rule below obvious: there is exactly
    // one place that decides "reply and stop".

    // The two unauthenticated liveness endpoints. They touch no session
    // state and no DB, so they are answered before the auth check.
    //
    // The return value means "this request is FINISHED -- do not send
    // anything else on this connection". A wrong path is finished: the
    // 404 IS the answer. Returning false there (as an earlier version
    // of this helper did) let the caller fall through to the auth check
    // and then to the dispatch, so an authenticated POST to a path the
    // server does not serve got a 404 AND a 200 with the tool's result
    // -- two HTTP responses on one connection, and the tool really ran.
    // A client that reads one response per connection was then left
    // with the stale 200 in its socket buffer, and the NEXT request on
    // a pooled socket parsed that stale response as its own.
    static bool handleUnauthenticatedGet( Wire& wire, const HttpRequest& req,
                                          const std::string& path,
                                          const std::function<bool()>& readinessProbe )
    {
        if( req.method != "GET" ) return false;
        if( path == "/healthz" ) { sendStatus( wire, 200, "OK" ); return true; }
        if( path == "/readyz" )
        {
            // This route is unauthenticated and the probe is a live query: the result is kept for 5 s so a burst of requests
            // costs the engine one probe, not one each (SECURITY_AUDIT.md 3.14).
            static std::mutex probeMu;
            static std::chrono::steady_clock::time_point probedAt{};
            static bool probed = false, lastReady = false;
            bool ready;
            {
                std::lock_guard<std::mutex> lk( probeMu );
                const auto now = std::chrono::steady_clock::now();
                if( !probed || now - probedAt >= std::chrono::seconds( 5 ) )
                {
                    lastReady = readinessProbe();
                    probedAt = now;
                    probed = true;
                }
                ready = lastReady;
            }
            sendStatus( wire, ready ? 200 : 503, ready ? "OK" : "Service Unavailable" );
            return true;
        }
        return false;   // the MCP path itself: the caller continues
    }

    // Failed-auth backoff: each failure stalls its own connection thread for a growing
    // interval (capped at 2 s), which throttles online token guessing without a lockout
    // an attacker could turn against legitimate clients. A success pays one failure back.
    static std::atomic<int>& authFailureCounter() { static std::atomic<int> n{ 0 }; return n; }
    static void authFailed()
    {
        const int fails = std::min( authFailureCounter().fetch_add( 1 ) + 1, 20 );
        std::this_thread::sleep_for( std::chrono::milliseconds( fails * 100 ) );
    }
    static void authOk()
    {
        int f = authFailureCounter().load();
        while( f > 0 && !authFailureCounter().compare_exchange_weak( f, f - 1 ) ) {}
    }

    // DELETE closes the named session's dedicated DB connection.
    static bool handleDelete( Wire& wire, const HttpRequest& req, ClientRegistry& reg,
                              const std::string& ownerFp )
    {
        if( req.sessionId.empty() ) { sendStatus( wire, 400, "Bad Request" ); return false; }
        if( reg.eraseSession( req.sessionId, ownerFp ) ) sendStatus( wire, 200, "OK" );
        else sendStatus( wire, 404, "Not Found" );
        return false;
    }

    // The reply of a dispatched request: the JSON-RPC answer, or the empty
    // 202 of a notification.
    static void sendDispatchReply( Wire& wire, const std::string& body, bool isRequest,
                                   const std::string& sessionHeader )
    {
        if( !isRequest )
        {
            // A notification is never answered with substance: the server
            // acknowledges that it was accepted.
            std::ostringstream head;
            head << "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nContent-Type: application/json\r\n"
                 << "Connection: close\r\n";
            if( !sessionHeader.empty() ) head << "Mcp-Session-Id: " << sessionHeader << "\r\n";
            head << "\r\n";
            const std::string h = head.str();
            wire.sendAll( h.data(), h.size() );
            return;
        }
        std::ostringstream head;
        head << "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
             << body.size() << "\r\n";
        // The server closes the socket after this reply (one request, one
        // reply, one close), and HTTP/1.1 defaults to KEEP-ALIVE. A
        // client that pools connections -- httpx, requests.Session,
        // urllib3, all standard for the Streamable-HTTP transport --
        // reads the reply, sees no "Connection: close", and returns the
        // socket to the pool. The next request on that pooled socket
        // goes to a socket the server has already shut, and the client
        // sees a reset on an otherwise healthy server. Every other
        // response in this file already says "Connection: close"; this
        // one did not.
        head << "Connection: close\r\n";
        if( !sessionHeader.empty() )
            head << "Mcp-Session-Id: " << sessionHeader << "\r\n";
        head << "\r\n";
        const std::string headStr = head.str();
        if( wire.sendAll( headStr.data(), headStr.size() ) != 0 || wire.sendAll( body.data(), body.size() ) != 0 )
            return;
    }

    // The legacy era's handshake: initialize mints the protocol session and
    // the engine context the session owns, and answers with the session id.
    static void handleLegacyInitialize( Wire& wire, const HttpRequest& req,
                                        const std::string& ownerFp, const std::string& bearer,
                                        const TokenStore::Credential& cred,
                                        ClientRegistry& reg, bool isRequest )
    {
        if( !req.sessionId.empty() )
        {
            sendJson( wire, 400, Json{ { "error", "initialize must not carry a session id" } } );
            return;
        }
        std::string contextId;
        std::shared_ptr<JsonRpcServer> srv;
        std::string sessionId;
        try
        {
            sessionId = reg.createSession( ownerFp, clientKeyFor( bearer, "" ), contextId, srv );
        }
        catch( const ToolError& )
        {
            sendStatus( wire, 503, "Service Unavailable" );
            return;
        }
        const std::string clientKey = clientKeyFor( bearer, sessionId );
        CallOptions opts;
        opts.era = ProtocolEra::Legacy;
        opts.toolAllow = cred.allow;
        auto resp = srv->handleLine( req.body, clientKey, opts );
        std::string body = resp ? *resp : std::string();
        // The client is told which context the session owns, so it can name
        // it back on a later call.
        if( !contextId.empty() && !body.empty() )
        {
            try
            {
                Json j = Json::parse( body );
                if( j.is_object() && j.contains( "result" ) && j[ "result" ].is_object() )
                {
                    j[ "result" ][ "context_id" ] = contextId;
                    body = j.dump();
                }
            }
            catch( ... ) {}
        }
        sendDispatchReply( wire, body, isRequest, sessionId );
    }

    // An ordinary call on an already-initialized legacy session.
    static void handleLegacyDispatch( Wire& wire, const HttpRequest& req, const Json& body,
                                      const std::string& ownerFp, const std::string& bearer,
                                      const TokenStore::Credential& cred,
                                      ClientRegistry& reg, bool isRequest )
    {
        std::string contextId;
        std::shared_ptr<JsonRpcServer> srv;
        if( !reg.findSession( req.sessionId, ownerFp, contextId, srv ) )
        {
            // A missing session id and an unknown one are told apart (400
            // and 404); a session that belongs to another credential is
            // reported as unknown, so a client cannot tell the difference.
            if( req.sessionId.empty() ) sendStatus( wire, 400, "Bad Request" );
            else sendStatus( wire, 404, "Not Found" );
            return;
        }
        // A context handle the client names must be the session's own: the
        // legacy era's context comes from the protocol session.
        const std::string requested = paramsContextId( body );
        if( !requested.empty() && requested != contextId )
        {
            sendRpcError( wire, 400, -32602,
                "the context handle does not match this session's context" );
            return;
        }
        const std::string clientKey = clientKeyFor( bearer, req.sessionId );
        CallOptions opts;
        opts.era = ProtocolEra::Legacy;
        opts.toolAllow = cred.allow;
        auto resp = srv->handleLine( req.body, clientKey, opts );
        sendDispatchReply( wire, resp ? *resp : std::string(), isRequest, std::string() );
    }

    // A modern era request: stateless, no protocol session. The engine
    // context comes from the request's own context_id argument when the
    // call addresses a stateful tool; otherwise the call runs on the
    // credential's own connection.
    static void handleModernDispatch( Wire& wire, const HttpRequest& req, const Json& body,
                                      const std::string& bodyMethod, bool isRequest,
                                      const std::string& ownerFp,
                                      const TokenStore::Credential& cred,
                                      ClientRegistry& reg )
    {
        const ModernCheck check = validateModernRequest( req, body, bodyMethod );
        if( !check.ok )
        {
            sendRpcError( wire, check.httpStatus, check.code, check.message, check.data );
            return;
        }
        if( !isKnownRpcMethod( bodyMethod ) )
        {
            sendRpcError( wire, 404, -32601, "method not found: " + bodyMethod );
            return;
        }

        // The engine context: the request's own handle when it names one
        // and the tool is stateful, otherwise a fresh handle, and the
        // credential's own connection for a tool that keeps no state.
        const std::string toolName = ( bodyMethod == "tools/call" ) ? paramsString( body, "name" ) : std::string();
        const bool stateful = !toolName.empty() && isContextScopedTool( toolName );
        std::string contextId;
        std::shared_ptr<JsonRpcServer> srv;
        try
        {
            if( stateful )
            {
                const std::string requested = paramsContextId( body );
                if( !requested.empty() )
                {
                    if( !reg.findContext( requested, ownerFp, srv ) )
                    {
                        sendJson( wire, 404, Json{ { "error",
                            "unknown context handle: it does not exist, or it belongs to another credential" } } );
                        return;
                    }
                    contextId = requested;
                }
                else
                    contextId = reg.createContext( ownerFp, srv );
            }
            else
                srv = reg.credentialServer( ownerFp );
        }
        catch( const ToolError& e )
        {
            sendJson( wire, 503, Json{ { "error", e.message } } );
            return;
        }

        CallOptions opts;
        opts.era = ProtocolEra::Modern;
        opts.contextId = stateful ? contextId : std::string();
        opts.toolAllow = cred.allow;
        auto resp = srv->handleLine( req.body, cred.clientName, opts );
        // The modern era mints no protocol session: no Mcp-Session-Id is
        // sent, and one the client sent is ignored.
        sendDispatchReply( wire, resp ? *resp : std::string(), isRequest, std::string() );
    }

    static void serveRequest( Wire& wire, HttpRequest& req, ClientRegistry& reg,
                              TokenStore& tokens, const HttpConfig& cfg,
                              const std::function<bool()>& readinessProbe )
    {
        // One request per connection. The MCP HTTP transport is a
        // request/response protocol: the client opens a connection,
        // sends one request, and reads one reply. Keeping a keep-alive
        // loop here bought nothing and cost a class of bugs -- a
        // half-sent request left in the socket when the session was
        // torn down, and a reply written to a connection the client had
        // already abandoned. One request, one reply, one close.
        if( !readRequestHead( wire, req ) )
        {
            if( req.malformed )
            {
                // The body of a request whose framing is refused is still in
                // the socket, and its length cannot be trusted. It is read
                // and discarded before the refusal is sent, so the client
                // reads the refusal instead of a connection reset.
                drainToQuiet( wire );
                req.contentLength = 0;
                req.bodyBytesRead = 0;
                sendStatus( wire, 400, "Bad Request" );
            }
            return;
        }
        wire.setTimeoutMs( 65000 );    // the head arrived; allow a slower body

        if( g_httpSignalled.load() ) return;

        const std::string path = pathOf( req.target );

        // A chunked body has no length: the client has to send a
        // Content-Length. The answer is 411, and the connection closes
        // after it.
        if( req.chunked )
        {
            sendJson( wire, 411, Json{ { "error", "a chunked request body is not accepted; send Content-Length" } } );
            return;
        }

        if( handleUnauthenticatedGet( wire, req, path, readinessProbe ) ) return;

        // Origin validation: a browser origin that this deployment does not
        // allow is refused before the request is looked at any further.
        if( !originAllowed( req.origin, cfg ) )
        {
            sendRpcError( wire, 403, -32000,
                "origin not allowed: " + req.origin + " is not a loopback origin and is not "
                "listed in FSQL_MCP_ALLOWED_ORIGINS" );
            return;
        }

        // The credential. The Authorization header is the ONLY place a
        // credential is read from: a token in the URL's query string is not
        // a credential, and the spec forbids putting one there (it ends up
        // in proxy logs and browser history).
        const std::string bearer = trimValue( req.bearer );
        const TokenStore::Credential cred = tokens.check( bearer );
        if( !cred.ok )
        {
            authFailed();
            sendUnauthorized( wire, !bearer.empty() );
            return;
        }
        authOk();
        const std::string ownerFp = tokenFingerprint( bearer );

        // A modern era request carries the modern protocol version header
        // (and the matching _meta in its body). The legacy era has neither.
        const bool modernByHeader = !req.protocolVersion.empty();

        if( req.method == "GET" || req.method == "DELETE" )
        {
            // The modern era has no GET stream and no session teardown, so
            // both are refused for a modern request.
            if( modernByHeader || modernEraOnly() )
            {
                sendJson( wire, 405, Json{ { "error",
                    req.method == "GET"
                        ? "GET is not used by the modern protocol era; POST JSON-RPC 2.0 messages"
                        : "DELETE is not used by the modern protocol era; it has no protocol session to tear down" } } );
                return;
            }
            if( req.method == "GET" )
            {
                // The legacy era has no GET stream either: the MCP path
                // answers 405, any other path 404.
                if( path == cfg.path )
                    sendJson( wire, 405, Json{ { "error",
                        "GET " + cfg.path + " is not used by this server; POST JSON-RPC 2.0 messages" } } );
                else
                    sendJson( wire, 404, Json{ { "error", "not found" } } );
                return;
            }
            handleDelete( wire, req, reg, ownerFp );
            return;
        }

        if( req.method != "POST" ) { sendStatus( wire, 405, "Method Not Allowed" ); return; }
        if( path != cfg.path ) { sendStatus( wire, 404, "Not Found" ); return; }
        if( g_httpDraining.load() )
        {
            sendJson( wire, 503, Json{ { "error", "server shutting down (retry after restart)" } } );
            return;
        }

        // The body is read only once the request is known to be
        // authenticated: an unauthenticated client must not be able to
        // make the server buffer a body for it.
        if( req.method == "DELETE" || req.method == "POST" )
        {
            try
            {
                if( !readRequestBody( wire, req ) ) return;
            }
            catch( const ToolError& )
            {
                sendStatus( wire, 413, "Payload Too Large" );
                return;
            }
        }

        if( jsonNestsTooDeep( req.body ) ) { sendStatus( wire, 400, "Bad Request" ); return; }
        Json bodyJson = Json::parse( req.body, nullptr, false );
        const bool parsed = !bodyJson.is_discarded() && bodyJson.is_object();
        if( !parsed )
        {
            // A body that is not a JSON-RPC message is a parse error, and
            // the JSON-RPC error object says so.
            sendRpcError( wire, 400, -32700,
                "parse error: the request body is not a JSON-RPC 2.0 message" );
            return;
        }
        const std::string method = ( bodyJson.contains( "method" ) && bodyJson[ "method" ].is_string() )
            ? bodyJson[ "method" ].get<std::string>() : std::string();
        const bool isRequest = bodyJson.contains( "id" );

        // The era of this request. "initialize" is the legacy handshake and
        // always selects the legacy flow; anything else is modern when it
        // carries the modern metadata or the modern version header.
        const bool isModern = ( method != "initialize" ) &&
            ( modernByHeader || !modernMetaVersion( bodyJson ).empty() );

        if( modernEraOnly() && !isModern )
        {
            // A modern-only server refuses the legacy era outright, and says
            // which revisions it speaks.
            std::string versions;
            for( const std::string& v : modernProtocolVersions() )
            {
                if( !versions.empty() ) versions += ", ";
                versions += v;
            }
            sendRpcError( wire, 400, -32000,
                "this server speaks the modern protocol era only (FSQL_MCP_PROTOCOL_ERA=modern); "
                "the legacy initialize handshake and the legacy session headers are refused. "
                "Supported versions: " + versions );
            return;
        }

        if( isModern )
        {
            handleModernDispatch( wire, req, bodyJson, method, isRequest, ownerFp, cred, reg );
            return;
        }

        // Session isolation: initialize mints the session id (and must not
        // arrive with one); every other request presents a valid one (400
        // missing, 404 unknown).
        if( method == "initialize" )
        {
            handleLegacyInitialize( wire, req, ownerFp, bearer, cred, reg, isRequest );
            return;
        }

        handleLegacyDispatch( wire, req, bodyJson, ownerFp, bearer, cred, reg, isRequest );
    }


    // One connection, one request, one reply, one close -- and a body that
    // the request did not need is drained before the connection goes, so the
    // close is a clean end of stream instead of a connection reset.
    static void serveConnection( const WirePtr& wire, ClientRegistry& reg,
                                  TokenStore& tokens, const HttpConfig& cfg,
                                  const std::function<bool()>& readinessProbe )
    {
        HttpRequest req;
        serveRequest( *wire, req, reg, tokens, cfg, readinessProbe );
        // A request that was answered before its body was needed (a refused
        // credential, a refused origin, a chunked body) leaves the rest of
        // the body in the socket. Closing a socket that still holds unread
        // data makes the operating system reset the connection, and the
        // client loses the answer that was just sent. The rest of the body
        // is read and discarded first.
        //
        // The drain waits briefly: the body may never arrive, and the
        // connection is finished either way. It sits between the answer and
        // the end of the stream the client reads, so a long wait here is
        // added to the time a refusal takes -- and a refusal is answered
        // within about two and a half seconds (RFC 6750 section 3). The
        // chunked drain above uses the same timeout for the same reason.
        wire->setTimeoutMs( 250 );
        drainUnreadBody( *wire, req );
    }

    // The last OpenSSL error as a readable string. Every TLS startup
    // failure below reports through it: a bare "cert/key failed to load"
    // tells an operator nothing about WHICH file failed or why.
    static std::string opensslLastError()
    {
        const unsigned long code = ERR_get_error();
        if( code == 0 ) return "unknown OpenSSL error";
        char buf[ 256 ];
        ERR_error_string_n( code, buf, sizeof( buf ) );
        return std::string( buf );
    }

    // A routable bind without TLS sends the bearer token and every tool result in clear
    // text. Warn always; refuse unless FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK is set.
    static bool hostIsLoopback( const std::string& h )
    {
        return h.empty() || h == "localhost" || h == "::1" || isLoopbackV4( h );
    }

    static SSL_CTX* makeSslCtx( const HttpConfig& cfg, std::string& errOut )
    {
        SSL_CTX* ctx = SSL_CTX_new( TLS_server_method() );
        if( !ctx ) { errOut = "SSL_CTX_new failed: " + opensslLastError(); return nullptr; }
        SSL_CTX_set_min_proto_version( ctx, TLS1_2_VERSION );
        if( SSL_CTX_use_certificate_chain_file( ctx, cfg.tlsCertPath.c_str() ) != 1 )
        {
            errOut = "failed to load TLS cert file '" + cfg.tlsCertPath + "': " + opensslLastError();
            SSL_CTX_free( ctx );
            return nullptr;
        }
        if( SSL_CTX_use_PrivateKey_file( ctx, cfg.tlsKeyPath.c_str(), SSL_FILETYPE_PEM ) != 1 )
        {
            errOut = "failed to load TLS key file '" + cfg.tlsKeyPath + "': " + opensslLastError();
            SSL_CTX_free( ctx );
            return nullptr;
        }
        // Both files loaded, but they may simply not belong to each other.
        // Without this check the mismatch surfaces much later, as a
        // handshake failure on every single connection -- an
        // indistinguishable symptom from a broken client.
        if( SSL_CTX_check_private_key( ctx ) != 1 )
        {
            errOut = "TLS certificate and private key do not match: " + opensslLastError();
            SSL_CTX_free( ctx );
            return nullptr;
        }
        return ctx;
    }

    int runHttpTransport( JsonRpcServer& server, const HttpConfig& cfg, std::function<bool()> readinessProbe )
    {
        (void)server;    // dispatch is per-session; this instance only carries the shared registry
        if( !cfg.sessionFactory )
            throw ToolError( ErrorClass::ServerInternal, "runHttpTransport needs a per-session factory" );

#ifdef SIGHUP
        std::signal( SIGHUP, onSighup );
#endif
        std::signal( SIGTERM, onHttpTermSignal );
        std::signal( SIGINT,  onHttpTermSignal );

#ifdef _WIN32
        WSADATA wsa{};
        if( WSAStartup( MAKEWORD( 2, 2 ), &wsa ) != 0 )
            throw ToolError( ErrorClass::ServerInternal, "WSAStartup failed" );
#endif

        // The registry, the token store and the SSL context are held by
        // SHARED pointer and captured BY VALUE by every connection thread.
        // The shutdown path detaches whatever is still in flight (a client
        // that opened a connection and never sent a request must not be
        // able to wedge the server forever), and a detached thread
        // outliving this function would otherwise touch stack objects
        // that are already gone.
        std::shared_ptr<TokenStore> tokens = std::make_shared<TokenStore>( cfg );
        std::shared_ptr<ClientRegistry> reg = std::make_shared<ClientRegistry>( cfg );
        std::shared_ptr<SSL_CTX> sslCtx;
        if( cfg.tlsEnabled )
        {
            std::string tlsErr;
            SSL_CTX* ctx = makeSslCtx( cfg, tlsErr );
            if( !ctx )
                throw ToolError( ErrorClass::ServerInternal, "TLS enabled but cert/key failed to load: " + tlsErr );
            // The deleter is OpenSSL's, not delete's: an SSL_CTX is not a
            // C++ object and must go through SSL_CTX_free.
            sslCtx.reset( ctx, []( SSL_CTX* c ) { if( c ) SSL_CTX_free( c ); } );
        }

        const int listenFd = static_cast<int>( ::socket( AF_INET, SOCK_STREAM, 0 ) );
        if( listenFd < 0 )
            throw ToolError( ErrorClass::ServerInternal, "socket() failed" );
        int one = 1;
        setsockopt( listenFd, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>( &one ), sizeof( one ) );
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons( static_cast<unsigned short>( cfg.port ) );
        // The bind address comes from FSQL_MCP_BIND / --bind and defaults to
        // the loopback interface. Binding INADDR_ANY here would expose an
        // authenticated-but-otherwise-open JSON-RPC surface on every
        // interface of the host, which is not what "off by default" has to
        // mean for a server that ships with a Bearer token and no TLS.
        if( !resolveBindAddr( cfg.host, addr ) )
            // The message says what is ACCEPTED, not what was attempted:
            // no name resolution happens here, so a message about
            // "resolving" an address the code never tries to resolve
            // sends the operator looking for a DNS problem that is not
            // there.
            throw ToolError( ErrorClass::ServerInternal,
                             "the HTTP bind address '" + cfg.host + "' is not accepted: "
                             "use an IPv4 dotted quad (127.0.0.1), 'localhost', '*' "
                             "for every interface, or an empty value for the loopback" );
        if( ::bind( listenFd, reinterpret_cast<sockaddr*>( &addr ), sizeof( addr ) ) != 0 ||
            ::listen( listenFd, 16 ) != 0 )
            throw ToolError( ErrorClass::ServerInternal, "cannot bind the HTTP listener" );
        if( !sslCtx && !hostIsLoopback( cfg.host ) )
        {
            logging::logInfo( "WARNING: the HTTP transport is bound to non-loopback address '" + cfg.host +
                              "' WITHOUT TLS; the bearer token and all results travel in clear text (set FSQL_MCP_HTTP_TLS=true)" );
            const char* allowPlain = std::getenv( "FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK" );
            if( !( allowPlain && *allowPlain && std::string( allowPlain ) != "0" && std::string( allowPlain ) != "false" ) )
                throw ToolError( ErrorClass::ServerInternal, "refusing a non-loopback HTTP bind without TLS (set FSQL_MCP_HTTP_TLS=true, or FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK=true to accept the risk)" );
        }
        logging::logInfo( "http transport listening on " + cfg.host + ":" + std::to_string( cfg.port ) +
                          ( sslCtx ? " (TLS)" : " (plain)" ) );

        // Every connection gets its own thread, and the thread objects are
        // REAPED as they finish. Keeping every thread object for the life
        // of the process (the old behaviour) grew the vector without bound
        // on a long-running server: a std::thread that has been joined
        // still occupies its stack handle, and an unjoined one occupies its
        // whole stack allocation.
        struct Conn
        {
            std::thread t;
            // Shared, not a plain member: a thread that is detached at
            // shutdown may outlive this function, and it still has to be
            // able to set the flag without touching freed memory.
            std::shared_ptr<std::atomic<bool>> done = std::make_shared<std::atomic<bool>>( false );
        };

        // The bookkeeping lives in a SHARED object rather than in locals,
        // because the reaper thread and the connection threads both reach
        // it, and a connection thread that is detached at shutdown can
        // outlive this function. The stop flag is shared for the same
        // reason: the reaper is joined on every path out of here, but a
        // std::thread constructor that throws would leave it running
        // against a stack object that no longer exists.
        struct ConnState
        {
            std::mutex mu;
            std::condition_variable cv;
            std::vector<std::unique_ptr<Conn>> conns;
        };
        auto state = std::make_shared<ConnState>();
        auto reaperStop = std::make_shared<std::atomic<bool>>( false );
        // Refusals still delivering themselves (past the connection limit).
        auto refusalsInFlight = std::make_shared<std::atomic<int>>( 0 );

        // Joins and drops the connections that have already finished.
        // Called with state->mu held.
        auto reapLocked = [ state ]()
        {
            for( auto it = state->conns.begin(); it != state->conns.end(); )
            {
                if( ( *it )->done->load() )
                {
                    if( ( *it )->t.joinable() ) ( *it )->t.join();
                    it = state->conns.erase( it );
                }
                else ++it;
            }
        };
        auto reap = [ state, reapLocked ]()
        {
            std::lock_guard<std::mutex> lk( state->mu );
            reapLocked();
        };

        // A connection that finishes while the server is IDLE has to be
        // reclaimed too, and the accept loop cannot do it: it only wakes
        // for a new connection or the next poll slice. Without
        // this thread, a burst of N requests followed by a quiet period
        // left N finished-but-unjoined threads (each keeping its stack
        // allocated) and N stale entries in the vector until the next
        // request came in. The reaper waits on a condition variable that
        // a finishing connection signals, and also on a timeout so it
        // cannot miss a signal.
        std::thread reaper( [ state, reaperStop, reapLocked ]()
        {
            std::unique_lock<std::mutex> lk( state->mu );
            while( !reaperStop->load() )
            {
                state->cv.wait_for( lk, std::chrono::milliseconds( 250 ) );
                reapLocked();
            }
        } );

        const std::size_t connLimit = maxConnections();
        logging::logInfo( "http max connections: " + std::to_string( connLimit ) );

        while( !g_httpSignalled.load() )
        {
            if( !waitForConnection( listenFd, 250 ) ) continue;
            sockaddr_in peer{}; socklen_t plen = sizeof( peer );
            const int fd = static_cast<int>( ::accept( listenFd, reinterpret_cast<sockaddr*>( &peer ), &plen ) );
            if( fd < 0 )
            {
                // Out of descriptors, an aborted connection: keep serving.
                if( g_httpSignalled.load() ) break;
                std::this_thread::sleep_for( std::chrono::milliseconds( 10 ) );
                continue;
            }
            bool overLimit = false;
            {
                std::lock_guard<std::mutex> lk( state->mu );
                reapLocked();
                overLimit = state->conns.size() >= connLimit;
            }
            if( overLimit )
            {
                // Over the limit: refuse before spending a thread on it. A
                // TLS client cannot read a plaintext reply; it just sees the close.
                if( !sslCtx )
                {
                    static const char kBusy[] = "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 1\r\n"
                                                "Content-Length: 0\r\nConnection: close\r\n\r\n";
                    ::send( fd, kBusy, static_cast<int>( sizeof( kBusy ) - 1 ), 0 );
                    // The refusal is finished on its own short-lived thread:
                    // draining the peer's request takes a moment, and the
                    // accept loop must keep accepting while it does.
                    if( refusalsInFlight->fetch_add( 1 ) < kMaxRefusalsInFlight )
                    {
                        std::thread( [ fd, refusalsInFlight ] {
                            fsqlCloseAfterReply( fd, kRefusalLingerMs );
                            refusalsInFlight->fetch_sub( 1 );
                        } ).detach();
                    }
                    else
                    {
                        refusalsInFlight->fetch_sub( 1 );
                        fsqlCloseSocket( fd );
                    }
                }
                else
                    fsqlCloseSocket( fd );
                continue;
            }
            // Everything the thread touches is captured BY VALUE (shared
            // pointers for the registry, the token store, the SSL context
            // and the connection bookkeeping; the config by copy), so a
            // thread that is still running when this function returns
            // keeps every object it needs alive.
            const HttpConfig cfgCopy = cfg;
            auto conn = std::unique_ptr<Conn>( new Conn );
            auto done = conn->done;
            conn->t = std::thread( [ fd, reg, tokens, sslCtx, cfgCopy, readinessProbe, done, state ]()
            {
                WirePtr wire;
                setSocketTimeoutMs( fd, 15000 );    // TLS handshake and request head
                if( sslCtx )
                {
                    TlsWire* t = new TlsWire( fd, sslCtx.get() );
                    if( !t->ok() || !t->accept() ) { delete t; done->store( true ); state->cv.notify_one(); return; }
                    wire.reset( t );
                }
                else wire.reset( new PlainWire( fd ) );
                try
                {
                    serveConnection( wire, *reg, *tokens, cfgCopy, readinessProbe );
                }
                catch( const std::exception& e )
                {
                    // An exception escaping this thread is std::terminate:
                    // one bad connection must degrade to a closed socket
                    // instead of taking the whole server down.
                    logging::exceptionDetail( "http_conn_thread", sanitizeSecrets( e.what() ) );
                }
                catch( ... )
                {
                    logging::exceptionDetail( "http_conn_thread", "unknown exception" );
                }
                wire->closeWire();
                done->store( true );
                state->cv.notify_one();
            } );
            {
                std::lock_guard<std::mutex> lk( state->mu );
                state->conns.emplace_back( std::move( conn ) );
            }
            reap();
        }

        server.beginShutdown();
        g_httpDraining.store( true );
        reg->endAll();
        fsqlCloseSocket( listenFd );
        {
            // Stop the reaper before the drain: it shares the bookkeeping
            // with the drain loop, and the drain loop reaps on its own.
            reaperStop->store( true );
            state->cv.notify_all();
            if( reaper.joinable() ) reaper.join();
        }
        const auto deadline = std::chrono::steady_clock::now() +
                               std::chrono::milliseconds( cfg.shutdownDrainMs );
        while( std::chrono::steady_clock::now() < deadline )
        {
            reap();
            bool alive = false;
            { std::lock_guard<std::mutex> lk( state->mu ); alive = !state->conns.empty(); }
            // A refusal that is still delivering itself counts as alive: the
            // process must not exit while a client is owed its 503.
            if( !alive && refusalsInFlight->load() == 0 ) break;
            std::this_thread::sleep_for( std::chrono::milliseconds( 50 ) );
        }
        {
            // Whatever is still in flight is detached rather than joined:
            // a client that opened a connection and never sent a request
            // would otherwise wedge the shutdown for good. Detaching is
            // safe because the thread owns every object it touches.
            std::lock_guard<std::mutex> lk( state->mu );
            for( auto& c : state->conns ) if( c->t.joinable() ) c->t.detach();
        }
#ifdef _WIN32
        WSACleanup();
#endif
        return 0;
    }
}
