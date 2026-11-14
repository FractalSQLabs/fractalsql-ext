#include "transport_stdio.h"
#include "resources.h"
#include "db.h"
#include <openssl/rand.h>
#include <cstdio>
#include <thread>
#include <memory>
#include <atomic>
#include <csignal>
#include <chrono>
#include <vector>
#include <mutex>

namespace fsqlmcp
{
    static std::atomic<bool> g_signalled{ false };
    static void onTermSignal( int ) { g_signalled.store( true ); }

    // A context handle: 128 bits of randomness, hex.
    static std::string mintContextHandle()
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

    // Byte-safe bounded line reader, NEVER std::getline(std::cin,...), which
    // narrows int_type->char and can abort a sanitizer build on a single
    // 0x80-0xFF byte.
    static bool readLineBounded( std::string& out, std::size_t maxBytes )
    {
        out.clear();
        int c;
        while( ( c = std::fgetc( stdin ) ) != EOF )
        {
            if( c == '\n' ) return true;
            if( out.size() < maxBytes )
                out.push_back( static_cast<char>( static_cast<unsigned char>( c ) ) );
        }
        return !out.empty();
    }

    // One response, one line, one write. Workers answer concurrently; with separate
    // fputs + fputc calls two responses could interleave on stdout (A, B, '\n', '\n'),
    // gluing two JSON objects onto one line and corrupting the client's framing.
    static void writeLine( const std::string& response )
    {
        static std::mutex outMu;
        std::string line;
        line.reserve( response.size() + 1 );
        line += response;
        line += '\n';
        std::lock_guard<std::mutex> lk( outMu );
        std::fwrite( line.data(), 1, line.size(), stdout );
        std::fflush( stdout );
    }

    int runStdioTransport( JsonRpcServer& server, const StdioConfig& cfg )
    {
        std::signal( SIGTERM, onTermSignal );
        std::signal( SIGINT,  onTermSignal );

        // One worker per input line, but BOUNDED: at most kMaxLiveWorkers run at once (the reader
        // blocks, i.e. applies back-pressure to the client, until one finishes) and finished threads
        // are reaped as we go, so neither the thread count nor this vector grows with the input.
        constexpr std::size_t kMaxLiveWorkers = 64;
        struct Worker { std::thread th; std::shared_ptr<std::atomic<bool>> done; };
        std::vector<Worker> workers;
        std::mutex workersMu;

        // The stdio transport has ONE engine context for the whole run: the
        // process has a single engine connection, so every request shares the
        // same engine state. The handle names that context.
        const std::string implicitContext = mintContextHandle();

        // Resources/prompts read live engine state through the module-level
        // thread-db hook (resources.h); stdio has exactly one DB ever.
        std::string line;
        while( !g_signalled.load() && readLineBounded( line, 8 * 1024 * 1024 ) )
        {
            if( line.find_first_not_of( " \t\r\n" ) == std::string::npos )
                continue;
            if( server.isShuttingDown() )
                continue;    // new requests rejected inline; EOF/signal path below still drains

            const std::string lineCopy = line;
            std::lock_guard<std::mutex> lk( workersMu );
            for( ;; )
            {
                for( auto it = workers.begin(); it != workers.end(); )
                    if( it->done->load() ) { if( it->th.joinable() ) it->th.join(); it = workers.erase( it ); }
                    else ++it;
                if( workers.size() < kMaxLiveWorkers || g_signalled.load() ) break;
                std::this_thread::sleep_for( std::chrono::milliseconds( 2 ) );
            }
            auto done = std::make_shared<std::atomic<bool>>( false );
            workers.push_back( Worker{ std::thread( [ &server, lineCopy, done, implicitContext ]
            {
                CallOptions opts;
                opts.era = ProtocolEra::Legacy;
                opts.contextId = implicitContext;
                auto resp = server.handleLine( lineCopy, "stdio", opts );
                if( resp )
                {
                    writeLine( *resp );
                }
                done->store( true );
            } ), done } );
        }

        // The requests that were read before the input ended are answered
        // BEFORE the shutdown begins: a client that writes its last message
        // and then closes its end still gets the replies. The shutdown flag
        // only turns away requests that arrive after it, and no more can
        // arrive here: the input is closed and the reading loop has ended.
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds( cfg.shutdownDrainMs );
        for( ;; )
        {
            bool live = false;
            {
                std::lock_guard<std::mutex> lk( workersMu );
                for( const Worker& w : workers )
                    if( !w.done->load() ) { live = true; break; }
            }
            if( !live ) break;
            if( std::chrono::steady_clock::now() >= deadline ) break;
            std::this_thread::sleep_for( std::chrono::milliseconds( 10 ) );
        }
        {
            std::lock_guard<std::mutex> lk( workersMu );
            for( auto& w : workers ) if( w.th.joinable() ) w.th.join();
            workers.clear();
        }

        server.beginShutdown();
        return 0;
    }
}