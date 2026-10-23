# Hermetic embedding server for black-box suites (source this file).
# Compiles tests/integration/mock-embed-server.c once per WORKDIR and starts it on
# a free local port so indexing never depends on whatever Ollama/oMLX the host
# happens to run. FAIL_CSV/STALL_CSV list 1-based request numbers the server
# answers with HTTP 503 or never answers (request 1 is docscan's dimension probe).
#
#   mock_embed_start WORKDIR [FAIL_CSV [STALL_CSV]]   # sets MOCK_EMBED_PID, _PORT, _URL
#   mock_embed_stop
#   "${MOCK_EMBED_FLAGS[@]}"   # docscan index flags that target the mock

MOCK_EMBED_PID=""
MOCK_EMBED_PORT=""
MOCK_EMBED_URL=""
MOCK_EMBED_FLAGS=()

mock_embed_start() {
	local work="$1" fail_csv="${2:-}" stall_csv="${3:-}"
	local src
	src="$(cd "$(dirname "${BASH_SOURCE[0]}")/../integration" && pwd)/mock-embed-server.c"
	local bin="$work/mock-embed"
	if [ ! -x "$bin" ] && ! "${CC:-cc}" -std=c11 -O2 "$src" -o "$bin"; then
		echo "mock_embed_start: failed to compile $src" >&2
		return 1
	fi
	local attempt port i
	for attempt in 1 2 3 4 5; do
		port=$(( 20000 + (RANDOM % 20000) ))
		"$bin" "$port" 8 "$fail_csv" "$stall_csv" > "$work/mock-embed.out" 2> "$work/mock-embed.err" &
		MOCK_EMBED_PID=$!
		# Readiness is the server's own LISTENING line, polled with a bound.
		for i in $(seq 1 100); do
			if grep -q "LISTENING $port" "$work/mock-embed.out" 2>/dev/null; then
				MOCK_EMBED_PORT=$port
				MOCK_EMBED_URL="http://127.0.0.1:$port"
				MOCK_EMBED_FLAGS=(--embedding-api openai --embedding-url "$MOCK_EMBED_URL" --model mock)
				return 0
			fi
			kill -0 "$MOCK_EMBED_PID" 2>/dev/null || break
			sleep 0.02
		done
		kill "$MOCK_EMBED_PID" 2>/dev/null
		MOCK_EMBED_PID=""
	done
	echo "mock_embed_start: could not start mock server" >&2
	return 1
}

mock_embed_stop() {
	if [ -n "$MOCK_EMBED_PID" ]; then
		kill "$MOCK_EMBED_PID" 2>/dev/null
		wait "$MOCK_EMBED_PID" 2>/dev/null
	fi
	MOCK_EMBED_PID=""
}
