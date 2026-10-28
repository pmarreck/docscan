# Selects a real local embedding server for the integration suite (source this file).
# Order: explicit DOCSCAN_INTEG_API/URL/MODEL, then oMLX (OpenAI-compatible), then
# Ollama. A server only counts if it reports an embedding model.
#
#   real_embed_select    # 0: sets REAL_EMBED_FLAGS, REAL_EMBED_DESC
#                        # 1: sets REAL_EMBED_REASON (nothing usable found)
#
# Environment:
#   DOCSCAN_INTEG_API, DOCSCAN_INTEG_URL, DOCSCAN_INTEG_MODEL  use exactly this server
#   DOCSCAN_INTEG_OMLX_URL    oMLX base URL (default http://127.0.0.1:8000)
#   DOCSCAN_INTEG_OLLAMA_URL  Ollama base URL (default http://127.0.0.1:11434)
#   OMLX_API_KEY or DOCSCAN_EMBEDDING_API_KEY  bearer key for oMLX; passed to docscan
#                             through the environment, never on the command line

REAL_EMBED_FLAGS=()
REAL_EMBED_DESC=""
REAL_EMBED_REASON=""

# Choose an embedding model from server-reported names (one per line on stdin).
# Name heuristic: "embed", bge, e5 or gte families count, rerankers never do.
# Preference: bge-m3, then nomic-embed-text, then the first match in server order.
real_embed_pick_model() {
	awk '
		{ n = tolower($0) }
		n == "" || n ~ /rerank/ { next }
		n ~ /embed/ || n ~ /(^|[-_\/])bge([-_]|$)/ || n ~ /(^|[-_\/])e5([-_]|$)/ || n ~ /(^|[-_\/])gte([-_]|$)/ {
			if (n ~ /bge-m3/ && bge == "") bge = $0
			else if (n ~ /nomic-embed-text/ && nomic == "") nomic = $0
			else if (first == "") first = $0
		}
		END {
			if (bge != "") print bge
			else if (nomic != "") print nomic
			else if (first != "") print first
		}
	'
}

real_embed_select() {
	local key="${OMLX_API_KEY:-${DOCSCAN_EMBEDDING_API_KEY:-}}"
	local model

	if [ -n "${DOCSCAN_INTEG_API:-}${DOCSCAN_INTEG_URL:-}${DOCSCAN_INTEG_MODEL:-}" ]; then
		if [ -z "${DOCSCAN_INTEG_API:-}" ] || [ -z "${DOCSCAN_INTEG_URL:-}" ] || [ -z "${DOCSCAN_INTEG_MODEL:-}" ]; then
			REAL_EMBED_REASON="DOCSCAN_INTEG_API, DOCSCAN_INTEG_URL and DOCSCAN_INTEG_MODEL must be set together"
			return 1
		fi
		[ -n "$key" ] && export DOCSCAN_EMBEDDING_API_KEY="$key"
		REAL_EMBED_FLAGS=(--embedding-api "$DOCSCAN_INTEG_API" --embedding-url "$DOCSCAN_INTEG_URL" --model "$DOCSCAN_INTEG_MODEL")
		REAL_EMBED_DESC="$DOCSCAN_INTEG_API at $DOCSCAN_INTEG_URL, model $DOCSCAN_INTEG_MODEL (from environment)"
		return 0
	fi

	local omlx="${DOCSCAN_INTEG_OMLX_URL:-http://127.0.0.1:8000}"
	local auth=()
	[ -n "$key" ] && auth=(-H "Authorization: Bearer $key")
	model="$(curl -sf -m 5 "${auth[@]}" "$omlx/v1/models" 2>/dev/null | jq -r '.data[]?.id // empty' 2>/dev/null | real_embed_pick_model)"
	if [ -n "$model" ]; then
		[ -n "$key" ] && export DOCSCAN_EMBEDDING_API_KEY="$key"
		REAL_EMBED_FLAGS=(--embedding-api openai --embedding-url "$omlx" --model "$model")
		REAL_EMBED_DESC="oMLX at $omlx, model $model"
		return 0
	fi

	local ollama="${DOCSCAN_INTEG_OLLAMA_URL:-http://127.0.0.1:11434}"
	model="$(curl -sf -m 5 "$ollama/api/tags" 2>/dev/null | jq -r '.models[]?.name // empty' 2>/dev/null | real_embed_pick_model)"
	if [ -n "$model" ]; then
		REAL_EMBED_FLAGS=(--embedding-api ollama --embedding-url "$ollama" --model "$model")
		REAL_EMBED_DESC="Ollama at $ollama, model $model"
		return 0
	fi

	REAL_EMBED_REASON="no embedding model reported by oMLX ($omlx) or Ollama ($ollama)"
	return 1
}
