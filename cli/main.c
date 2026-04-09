/*
 * docscan CLI — C entry point that dogfoods the C FFI.
 * All I/O lives here; the Zig core is pure computation.
 *
 * This file is intentionally monolithic: it is the I/O orchestration layer
 * that handles argument parsing, directory walking, HTTP (Ollama), progress
 * reporting, and output formatting.
 */

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <stdarg.h>
#include <errno.h>
#include <time.h>
#include <ctype.h>

/* POSIX */
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/utsname.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <fcntl.h>

#include "docscan_core.h"

/* ── Constants ──────────────────────────────────────────────────────── */

#define DOCSCAN_VERSION       "0.1.0"
#define DEFAULT_MODEL         "nomic-embed-text"
#define DEFAULT_EMBEDDING_DIM 768
#define DEFAULT_MAX_TOKENS    1500
#define DEFAULT_LIMIT         10
#define DEFAULT_DB_SUBDIR     ".docscan"
#define DEFAULT_DB_FILENAME   "index.db"
#define ERR_BUF_LEN           1024
#define MAX_PATH_LEN          4096
#define HTTP_BUF_SIZE         (4 * 1024 * 1024)  /* 4 MiB response buffer */
#define MAX_CHUNKS_PER_FILE   4096
#define SHA256_DIGEST_LEN     32
#define SHA256_HEX_LEN        64

/* ── Embedding API dialect ─────────────────────────────────────────── */

typedef enum {
	API_OLLAMA = 0,
	API_OPENAI = 1,
} ApiDialect;

static ApiDialect g_api_dialect = API_OLLAMA;
static char g_embedding_url[512] = "http://127.0.0.1:11434";
static char g_api_key[512] = "";

/* ── Color / formatting ─────────────────────────────────────────────── */

static int g_use_color  = 1;
static int g_use_simple = 0;
static int g_show_progress = 1;
static int g_json_output = 0;

#define ANSI_RESET   "\033[0m"
#define ANSI_BOLD    "\033[1m"
#define ANSI_DIM     "\033[2m"
#define ANSI_RED     "\033[31m"
#define ANSI_GREEN   "\033[32m"
#define ANSI_YELLOW  "\033[33m"
#define ANSI_BLUE    "\033[34m"
#define ANSI_MAGENTA "\033[35m"
#define ANSI_CYAN    "\033[36m"

static const char* color(const char* code) {
	return (g_use_color && !g_use_simple) ? code : "";
}

/* ── Utility: stderr messaging ──────────────────────────────────────── */

static void err_msg(const char* fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "%serror:%s ", color(ANSI_RED), color(ANSI_RESET));
	vfprintf(stderr, fmt, ap);
	fprintf(stderr, "\n");
	va_end(ap);
}

static void warn_msg(const char* fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "%swarn:%s ", color(ANSI_YELLOW), color(ANSI_RESET));
	vfprintf(stderr, fmt, ap);
	fprintf(stderr, "\n");
	va_end(ap);
}

static void info_msg(const char* fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	fprintf(stderr, "\n");
	va_end(ap);
}

/* ── SHA-256 ────────────────────────────────────────────────────────── */
/* Minimal, correct SHA-256 implementation (FIPS 180-4). */

static const uint32_t sha256_k[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
	0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
	0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
	0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
	0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
	0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
	0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
	0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
	0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define SHA_RR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define SHA_CH(x,y,z) (((x) & (y)) ^ (~(x) & (z)))
#define SHA_MAJ(x,y,z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define SHA_EP0(x) (SHA_RR(x, 2) ^ SHA_RR(x,13) ^ SHA_RR(x,22))
#define SHA_EP1(x) (SHA_RR(x, 6) ^ SHA_RR(x,11) ^ SHA_RR(x,25))
#define SHA_SIG0(x) (SHA_RR(x, 7) ^ SHA_RR(x,18) ^ ((x) >> 3))
#define SHA_SIG1(x) (SHA_RR(x,17) ^ SHA_RR(x,19) ^ ((x) >> 10))

typedef struct {
	uint32_t state[8];
	uint64_t bitlen;
	uint8_t  data[64];
	uint32_t datalen;
} sha256_ctx;

static void sha256_init(sha256_ctx* ctx) {
	ctx->datalen = 0;
	ctx->bitlen = 0;
	ctx->state[0] = 0x6a09e667;
	ctx->state[1] = 0xbb67ae85;
	ctx->state[2] = 0x3c6ef372;
	ctx->state[3] = 0xa54ff53a;
	ctx->state[4] = 0x510e527f;
	ctx->state[5] = 0x9b05688c;
	ctx->state[6] = 0x1f83d9ab;
	ctx->state[7] = 0x5be0cd19;
}

static void sha256_transform(sha256_ctx* ctx, const uint8_t* d) {
	uint32_t w[64], a, b, c, e, f, g, h, t1, t2;
	for (int i = 0; i < 16; i++)
		w[i] = ((uint32_t)d[i*4] << 24) | ((uint32_t)d[i*4+1] << 16)
		     | ((uint32_t)d[i*4+2] << 8) | (uint32_t)d[i*4+3];
	for (int i = 16; i < 64; i++)
		w[i] = SHA_SIG1(w[i-2]) + w[i-7] + SHA_SIG0(w[i-15]) + w[i-16];

	a = ctx->state[0]; b = ctx->state[1];
	c = ctx->state[2]; /* d shadows param */ e = ctx->state[4];
	f = ctx->state[5]; g = ctx->state[6]; h = ctx->state[7];
	uint32_t dd = ctx->state[3];

	for (int i = 0; i < 64; i++) {
		t1 = h + SHA_EP1(e) + SHA_CH(e,f,g) + sha256_k[i] + w[i];
		t2 = SHA_EP0(a) + SHA_MAJ(a,b,c);
		h = g; g = f; f = e; e = dd + t1;
		dd = c; c = b; b = a; a = t1 + t2;
	}
	ctx->state[0] += a; ctx->state[1] += b;
	ctx->state[2] += c; ctx->state[3] += dd;
	ctx->state[4] += e; ctx->state[5] += f;
	ctx->state[6] += g; ctx->state[7] += h;
}

static void sha256_update(sha256_ctx* ctx, const uint8_t* data, size_t len) {
	for (size_t i = 0; i < len; i++) {
		ctx->data[ctx->datalen++] = data[i];
		if (ctx->datalen == 64) {
			sha256_transform(ctx, ctx->data);
			ctx->bitlen += 512;
			ctx->datalen = 0;
		}
	}
}

static void sha256_final(sha256_ctx* ctx, uint8_t hash[32]) {
	uint32_t i = ctx->datalen;
	ctx->data[i++] = 0x80;
	if (i > 56) {
		while (i < 64) ctx->data[i++] = 0;
		sha256_transform(ctx, ctx->data);
		i = 0;
	}
	while (i < 56) ctx->data[i++] = 0;

	ctx->bitlen += (uint64_t)ctx->datalen * 8;
	ctx->data[63] = (uint8_t)(ctx->bitlen);
	ctx->data[62] = (uint8_t)(ctx->bitlen >> 8);
	ctx->data[61] = (uint8_t)(ctx->bitlen >> 16);
	ctx->data[60] = (uint8_t)(ctx->bitlen >> 24);
	ctx->data[59] = (uint8_t)(ctx->bitlen >> 32);
	ctx->data[58] = (uint8_t)(ctx->bitlen >> 40);
	ctx->data[57] = (uint8_t)(ctx->bitlen >> 48);
	ctx->data[56] = (uint8_t)(ctx->bitlen >> 56);
	sha256_transform(ctx, ctx->data);

	for (int j = 0; j < 8; j++) {
		hash[j*4]   = (uint8_t)(ctx->state[j] >> 24);
		hash[j*4+1] = (uint8_t)(ctx->state[j] >> 16);
		hash[j*4+2] = (uint8_t)(ctx->state[j] >> 8);
		hash[j*4+3] = (uint8_t)(ctx->state[j]);
	}
}

/* Compute SHA-256 of a buffer and return hex string (caller provides 65+ byte out). */
static void sha256_hex(const uint8_t* data, size_t len, char out[SHA256_HEX_LEN + 1]) {
	sha256_ctx ctx;
	uint8_t hash[SHA256_DIGEST_LEN];
	sha256_init(&ctx);
	sha256_update(&ctx, data, len);
	sha256_final(&ctx, hash);
	for (int i = 0; i < SHA256_DIGEST_LEN; i++)
		sprintf(out + i*2, "%02x", hash[i]);
	out[SHA256_HEX_LEN] = '\0';
}

/* ── URL parsing ───────────────────────────────────────────────────── */

/*
 * Parse "http://host:port" into host string and port integer.
 * Default port: 80 for http (HTTPS not supported in v1).
 */
static void parse_url(const char* url, char* host, int host_len, int* port) {
	*port = 80;
	host[0] = '\0';

	const char* p = url;
	/* Skip scheme */
	if (strncmp(p, "http://", 7) == 0) {
		p += 7;
	} else if (strncmp(p, "https://", 8) == 0) {
		p += 8;
		*port = 443;
	}

	/* Find end of host (port separator or path or end of string) */
	const char* colon = strchr(p, ':');
	const char* slash = strchr(p, '/');

	if (colon && (!slash || colon < slash)) {
		/* host:port */
		int hlen = (int)(colon - p);
		if (hlen >= host_len) hlen = host_len - 1;
		memcpy(host, p, (size_t)hlen);
		host[hlen] = '\0';
		*port = atoi(colon + 1);
	} else if (slash) {
		/* host/path (no port) */
		int hlen = (int)(slash - p);
		if (hlen >= host_len) hlen = host_len - 1;
		memcpy(host, p, (size_t)hlen);
		host[hlen] = '\0';
	} else {
		/* Just host */
		int hlen = (int)strlen(p);
		if (hlen >= host_len) hlen = host_len - 1;
		memcpy(host, p, (size_t)hlen);
		host[hlen] = '\0';
	}
}

/* ── File I/O helpers ───────────────────────────────────────────────── */

/* Read entire file into malloc'd buffer. Sets *out_len. Returns NULL on error. */
static uint8_t* read_file(const char* path, size_t* out_len) {
	FILE* f = fopen(path, "rb");
	if (!f) return NULL;

	fseek(f, 0, SEEK_END);
	long sz = ftell(f);
	if (sz < 0) { fclose(f); return NULL; }
	fseek(f, 0, SEEK_SET);

	uint8_t* buf = malloc((size_t)sz);
	if (!buf) { fclose(f); return NULL; }

	size_t rd = fread(buf, 1, (size_t)sz, f);
	fclose(f);
	if (rd != (size_t)sz) { free(buf); return NULL; }

	*out_len = (size_t)sz;
	return buf;
}

/* ── Format detection ───────────────────────────────────────────────── */

/* Return the format string for a file extension, or NULL if unsupported. */
static const char* format_for_ext(const char* path) {
	const char* dot = strrchr(path, '.');
	if (!dot) return NULL;
	dot++;
	if (strcasecmp(dot, "md") == 0 || strcasecmp(dot, "markdown") == 0) return "md";
	if (strcasecmp(dot, "docx") == 0) return "docx";
	if (strcasecmp(dot, "pdf") == 0) return "pdf";
	if (strcasecmp(dot, "doc") == 0) return "doc";
	return NULL;
}

/* ── Minimal HTTP client for Ollama ─────────────────────────────────── */

/*
 * Simple HTTP POST to Ollama's embedding API.
 * Returns malloc'd response body, or NULL on error.
 * Sets *out_len to response body length.
 */
static char* http_post(const char* host, int port, const char* path_url,
                        const char* body, size_t body_len, size_t* out_len,
                        const char* auth_header)
{
	int sockfd = socket(AF_INET, SOCK_STREAM, 0);
	if (sockfd < 0) return NULL;

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons((uint16_t)port);

	if (inet_pton(AF_INET, host, &addr.sin_addr) <= 0) {
		/* Try DNS resolution */
		struct hostent* he = gethostbyname(host);
		if (!he) { close(sockfd); return NULL; }
		memcpy(&addr.sin_addr, he->h_addr_list[0], (size_t)he->h_length);
	}

	/* Set a connect timeout via non-blocking + select */
	{
		int flags = fcntl(sockfd, F_GETFL, 0);
		fcntl(sockfd, F_SETFL, flags | O_NONBLOCK);

		int rc = connect(sockfd, (struct sockaddr*)&addr, sizeof(addr));
		if (rc < 0 && errno != EINPROGRESS) {
			close(sockfd);
			return NULL;
		}

		fd_set wfds;
		FD_ZERO(&wfds);
		FD_SET(sockfd, &wfds);
		struct timeval tv = { .tv_sec = 10, .tv_usec = 0 };
		rc = select(sockfd + 1, NULL, &wfds, NULL, &tv);
		if (rc <= 0) {
			close(sockfd);
			return NULL;
		}

		/* Check for connect error */
		int err = 0;
		socklen_t elen = sizeof(err);
		getsockopt(sockfd, SOL_SOCKET, SO_ERROR, &err, &elen);
		if (err != 0) {
			close(sockfd);
			return NULL;
		}

		/* Back to blocking for read/write */
		fcntl(sockfd, F_SETFL, flags);
	}

	/* Build HTTP request */
	char header[1024];
	int hlen;
	if (auth_header && auth_header[0]) {
		hlen = snprintf(header, sizeof(header),
			"POST %s HTTP/1.1\r\n"
			"Host: %s:%d\r\n"
			"Content-Type: application/json\r\n"
			"Content-Length: %zu\r\n"
			"Authorization: %s\r\n"
			"Connection: close\r\n"
			"\r\n",
			path_url, host, port, body_len, auth_header);
	} else {
		hlen = snprintf(header, sizeof(header),
			"POST %s HTTP/1.1\r\n"
			"Host: %s:%d\r\n"
			"Content-Type: application/json\r\n"
			"Content-Length: %zu\r\n"
			"Connection: close\r\n"
			"\r\n",
			path_url, host, port, body_len);
	}

	/* Send header + body */
	if (write(sockfd, header, (size_t)hlen) != hlen) { close(sockfd); return NULL; }
	size_t sent = 0;
	while (sent < body_len) {
		ssize_t n = write(sockfd, body + sent, body_len - sent);
		if (n <= 0) { close(sockfd); return NULL; }
		sent += (size_t)n;
	}

	/* Read response */
	char* resp = malloc(HTTP_BUF_SIZE);
	if (!resp) { close(sockfd); return NULL; }
	size_t total = 0;
	for (;;) {
		ssize_t n = read(sockfd, resp + total, HTTP_BUF_SIZE - total - 1);
		if (n <= 0) break;
		total += (size_t)n;
		if (total >= HTTP_BUF_SIZE - 1) break;
	}
	close(sockfd);
	resp[total] = '\0';

	/* Find body (after \r\n\r\n) */
	char* body_start = strstr(resp, "\r\n\r\n");
	if (!body_start) { free(resp); return NULL; }
	body_start += 4;

	/* Check for HTTP 200 */
	if (strncmp(resp, "HTTP/1.1 200", 12) != 0 && strncmp(resp, "HTTP/1.0 200", 12) != 0) {
		/* Try to extract error message for user */
		free(resp);
		return NULL;
	}

	size_t blen = total - (size_t)(body_start - resp);
	char* result = malloc(blen + 1);
	if (!result) { free(resp); return NULL; }
	memcpy(result, body_start, blen);
	result[blen] = '\0';
	*out_len = blen;
	free(resp);
	return result;
}

/* ── Minimal JSON extraction for Ollama responses ───────────────────── */

/*
 * Parse the "embeddings" array from Ollama's JSON response.
 * Expected format: {"model":"...","embeddings":[[0.1,0.2,...],[0.3,0.4,...]]}
 *
 * Writes flat float array into out_embeddings.
 * Returns number of embedding vectors found.
 * out_dim is set to the dimension of each vector.
 */
static int parse_embeddings_json(const char* json, float* out_embeddings,
                                  int max_floats, int* out_dim)
{
	*out_dim = 0;
	const char* key = "\"embeddings\"";
	const char* p = strstr(json, key);
	if (!p) return 0;
	p += strlen(key);

	/* Skip to the outer [ */
	while (*p && *p != '[') p++;
	if (!*p) return 0;
	p++; /* past outer [ */

	int num_vectors = 0;
	int float_idx = 0;

	while (*p) {
		/* Skip whitespace/commas */
		while (*p && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == ',')) p++;
		if (*p == ']') break; /* end of outer array */
		if (*p != '[') break; /* expected inner array start */
		p++; /* past inner [ */

		int this_dim = 0;
		while (*p) {
			while (*p && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == ',')) p++;
			if (*p == ']') { p++; break; }

			char* end = NULL;
			float val = strtof(p, &end);
			if (end == p) break; /* parse error */
			if (float_idx < max_floats) {
				out_embeddings[float_idx++] = val;
			}
			this_dim++;
			p = end;
		}

		if (num_vectors == 0) *out_dim = this_dim;
		num_vectors++;
	}

	return num_vectors;
}

/*
 * Parse the "data" array from an OpenAI-compatible JSON response.
 * Expected format: {"data":[{"embedding":[0.1,0.2,...],"index":0},...],"model":"..."}
 *
 * Writes flat float array into out_embeddings.
 * Returns number of embedding vectors found.
 * out_dim is set to the dimension of each vector.
 */
static int parse_openai_embeddings_json(const char* json, float* out_embeddings,
                                         int max_floats, int* out_dim)
{
	*out_dim = 0;
	const char* key = "\"data\"";
	const char* p = strstr(json, key);
	if (!p) return 0;
	p += strlen(key);

	/* Skip to the outer [ */
	while (*p && *p != '[') p++;
	if (!*p) return 0;
	p++; /* past outer [ */

	int num_vectors = 0;
	int float_idx = 0;

	/* Walk through objects in the data array */
	while (*p) {
		/* Skip whitespace/commas */
		while (*p && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == ',')) p++;
		if (*p == ']') break; /* end of data array */
		if (*p != '{') break; /* expected object start */

		/* Find "embedding" key within this object */
		const char* emb = strstr(p, "\"embedding\"");
		if (!emb) break;
		emb += 11; /* past "embedding" */
		while (*emb && *emb != '[') emb++;
		if (!*emb) break;
		emb++; /* past [ */

		int this_dim = 0;
		while (*emb) {
			while (*emb && (*emb == ' ' || *emb == '\t' || *emb == '\n' || *emb == '\r' || *emb == ',')) emb++;
			if (*emb == ']') { emb++; break; }

			char* end = NULL;
			float val = strtof(emb, &end);
			if (end == emb) break; /* parse error */
			if (float_idx < max_floats) {
				out_embeddings[float_idx++] = val;
			}
			this_dim++;
			emb = end;
		}

		if (num_vectors == 0) *out_dim = this_dim;
		num_vectors++;

		/* Advance p past the closing } of this object */
		p = emb;
		while (*p && *p != '}') p++;
		if (*p == '}') p++;
	}

	return num_vectors;
}

/* ── Minimal JSON array counting (for chunk count from docscan_chunk) ── */

/* Count top-level objects in a JSON array: [{"..."},{"..."},...] */
static int count_json_array_objects(const char* json) {
	if (!json || json[0] != '[') return 0;
	if (json[1] == ']') return 0; /* empty array */
	int count = 0;
	int depth = 0;
	for (const char* p = json; *p; p++) {
		if (*p == '{') {
			if (depth == 1) count++; /* top-level object inside the array */
			depth++;
		} else if (*p == '}') {
			depth--;
		} else if (*p == '[') {
			depth++;
		} else if (*p == ']') {
			depth--;
			if (depth == 0) break;
		} else if (*p == '"') {
			/* skip string contents */
			p++;
			while (*p && *p != '"') {
				if (*p == '\\') p++; /* skip escaped char */
				p++;
			}
		}
	}
	return count;
}

/* ── Extract text fields from chunk JSON for embedding ──────────────── */

/*
 * Extract "text" values from chunk JSON array.
 * Returns array of malloc'd strings. Caller frees each + the array.
 * Sets *out_count.
 */
static char** extract_chunk_texts(const char* json, int* out_count) {
	*out_count = 0;
	int capacity = 64;
	char** texts = malloc(sizeof(char*) * (size_t)capacity);
	if (!texts) return NULL;

	const char* p = json;
	while ((p = strstr(p, "\"text\"")) != NULL) {
		p += 6; /* past "text" */
		/* Skip : and whitespace */
		while (*p && (*p == ':' || *p == ' ' || *p == '\t')) p++;
		if (*p != '"') continue;
		p++; /* past opening quote */

		/* Find end of string, handling escapes */
		size_t cap = 4096;
		char* text = malloc(cap);
		if (!text) break;
		size_t len = 0;

		while (*p && *p != '"') {
			if (*p == '\\' && *(p+1)) {
				p++;
				char ch;
				switch (*p) {
					case 'n': ch = '\n'; break;
					case 'r': ch = '\r'; break;
					case 't': ch = '\t'; break;
					case '"': ch = '"'; break;
					case '\\': ch = '\\'; break;
					default: ch = *p; break;
				}
				if (len + 1 >= cap) { cap *= 2; text = realloc(text, cap); }
				text[len++] = ch;
			} else {
				if (len + 1 >= cap) { cap *= 2; text = realloc(text, cap); }
				text[len++] = *p;
			}
			p++;
		}
		text[len] = '\0';

		if (*out_count >= capacity) {
			capacity *= 2;
			texts = realloc(texts, sizeof(char*) * (size_t)capacity);
		}
		texts[(*out_count)++] = text;
	}

	return texts;
}

/* ── Embedding (Ollama / OpenAI-compatible) ────────────────────────── */

/*
 * Call an embedding server to embed an array of text chunks.
 * Dialect-aware: uses g_api_dialect to select endpoint, auth, and parser.
 * Returns malloc'd flat float array (num_chunks * dim), or NULL on error.
 * Sets *out_dim to the embedding dimension.
 */
static float* embed_texts(const char* model, char** texts, int num_texts,
                           int* out_dim)
{
	*out_dim = 0;
	if (num_texts == 0) return NULL;

	/* Parse URL from global config */
	char host[256];
	int port;
	parse_url(g_embedding_url, host, sizeof(host), &port);

	/* Select endpoint path based on dialect */
	const char* path_url = (g_api_dialect == API_OPENAI)
		? "/v1/embeddings" : "/api/embed";

	/* Build auth header for OpenAI dialect */
	char auth_hdr[600] = "";
	if (g_api_dialect == API_OPENAI && g_api_key[0]) {
		snprintf(auth_hdr, sizeof(auth_hdr), "Bearer %s", g_api_key);
	}

	/* Build JSON request body: {"model":"...","input":["t1","t2",...]} */
	/* (Same format for both Ollama and OpenAI) */
	size_t body_cap = 256;
	for (int i = 0; i < num_texts; i++)
		body_cap += strlen(texts[i]) * 2 + 4; /* worst case with escaping */

	char* body = malloc(body_cap);
	if (!body) return NULL;

	int off = snprintf(body, body_cap, "{\"model\":\"%s\",\"input\":[", model);

	for (int i = 0; i < num_texts; i++) {
		if (i > 0) body[off++] = ',';
		body[off++] = '"';
		/* Escape the text */
		for (const char* s = texts[i]; *s; s++) {
			if ((size_t)off >= body_cap - 16) {
				body_cap *= 2;
				body = realloc(body, body_cap);
				if (!body) return NULL;
			}
			switch (*s) {
				case '"':  body[off++] = '\\'; body[off++] = '"'; break;
				case '\\': body[off++] = '\\'; body[off++] = '\\'; break;
				case '\n': body[off++] = '\\'; body[off++] = 'n'; break;
				case '\r': body[off++] = '\\'; body[off++] = 'r'; break;
				case '\t': body[off++] = '\\'; body[off++] = 't'; break;
				default:
					if ((unsigned char)*s < 0x20) {
						off += snprintf(body + off, body_cap - (size_t)off,
						                "\\u%04x", (unsigned char)*s);
					} else {
						body[off++] = *s;
					}
					break;
			}
		}
		body[off++] = '"';
	}
	off += snprintf(body + off, body_cap - (size_t)off, "]}");
	body[off] = '\0';

	/* Send request */
	size_t resp_len = 0;
	char* resp = http_post(host, port, path_url, body, (size_t)off, &resp_len,
	                        auth_hdr[0] ? auth_hdr : NULL);
	free(body);

	if (!resp) return NULL;

	/* Parse embeddings from response — dialect-specific */
	int max_floats = num_texts * DEFAULT_EMBEDDING_DIM * 2; /* generous */
	float* embeddings = malloc(sizeof(float) * (size_t)max_floats);
	if (!embeddings) { free(resp); return NULL; }

	int dim = 0;
	int nvecs;
	if (g_api_dialect == API_OPENAI) {
		nvecs = parse_openai_embeddings_json(resp, embeddings, max_floats, &dim);
	} else {
		nvecs = parse_embeddings_json(resp, embeddings, max_floats, &dim);
	}
	free(resp);

	if (nvecs == 0 || dim == 0) {
		free(embeddings);
		return NULL;
	}

	*out_dim = dim;
	return embeddings;
}

/* Check if the embedding server is reachable by connecting to its port. */
static int embedding_server_available(void) {
	char host[256];
	int port;
	parse_url(g_embedding_url, host, sizeof(host), &port);

	int sockfd = socket(AF_INET, SOCK_STREAM, 0);
	if (sockfd < 0) return 0;

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons((uint16_t)port);

	if (inet_pton(AF_INET, host, &addr.sin_addr) <= 0) {
		/* Try DNS resolution */
		struct hostent* he = gethostbyname(host);
		if (!he) { close(sockfd); return 0; }
		memcpy(&addr.sin_addr, he->h_addr_list[0], (size_t)he->h_length);
	}

	/* Non-blocking connect with short timeout */
	int flags = fcntl(sockfd, F_GETFL, 0);
	fcntl(sockfd, F_SETFL, flags | O_NONBLOCK);

	int rc = connect(sockfd, (struct sockaddr*)&addr, sizeof(addr));
	if (rc == 0) { close(sockfd); return 1; }
	if (errno != EINPROGRESS) { close(sockfd); return 0; }

	fd_set wfds;
	FD_ZERO(&wfds);
	FD_SET(sockfd, &wfds);
	struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
	rc = select(sockfd + 1, NULL, &wfds, NULL, &tv);
	if (rc <= 0) { close(sockfd); return 0; }

	int err = 0;
	socklen_t elen = sizeof(err);
	getsockopt(sockfd, SOL_SOCKET, SO_ERROR, &err, &elen);
	close(sockfd);
	return (err == 0);
}

/* ── Directory walking ──────────────────────────────────────────────── */

typedef struct {
	char**  paths;
	int     count;
	int     capacity;
} file_list;

static void file_list_init(file_list* fl) {
	fl->count = 0;
	fl->capacity = 256;
	fl->paths = malloc(sizeof(char*) * (size_t)fl->capacity);
}

static void file_list_add(file_list* fl, const char* path) {
	if (fl->count >= fl->capacity) {
		fl->capacity *= 2;
		fl->paths = realloc(fl->paths, sizeof(char*) * (size_t)fl->capacity);
	}
	fl->paths[fl->count++] = strdup(path);
}

static void file_list_free(file_list* fl) {
	for (int i = 0; i < fl->count; i++)
		free(fl->paths[i]);
	free(fl->paths);
	fl->paths = NULL;
	fl->count = 0;
}

/* Recursively collect supported files from a directory. */
static void walk_dir(const char* dir_path, file_list* fl) {
	DIR* d = opendir(dir_path);
	if (!d) return;

	struct dirent* ent;
	while ((ent = readdir(d)) != NULL) {
		/* Skip hidden files and . / .. */
		if (ent->d_name[0] == '.') continue;

		char full_path[MAX_PATH_LEN];
		snprintf(full_path, sizeof(full_path), "%s/%s", dir_path, ent->d_name);

		struct stat st;
		if (stat(full_path, &st) != 0) continue;

		if (S_ISDIR(st.st_mode)) {
			/* Skip common noise directories */
			if (strcmp(ent->d_name, "node_modules") == 0) continue;
			if (strcmp(ent->d_name, "__pycache__") == 0) continue;
			if (strcmp(ent->d_name, ".git") == 0) continue;
			if (strcmp(ent->d_name, ".jj") == 0) continue;
			if (strcmp(ent->d_name, "zig-cache") == 0) continue;
			if (strcmp(ent->d_name, "zig-out") == 0) continue;
			walk_dir(full_path, fl);
		} else if (S_ISREG(st.st_mode)) {
			if (format_for_ext(full_path) != NULL) {
				file_list_add(fl, full_path);
			}
		}
	}
	closedir(d);
}

/* Collect files: if path is a directory, walk it; if a file, add it directly. */
static void collect_files(const char* path, file_list* fl) {
	struct stat st;
	if (stat(path, &st) != 0) {
		err_msg("cannot access '%s': %s", path, strerror(errno));
		return;
	}
	if (S_ISDIR(st.st_mode)) {
		walk_dir(path, fl);
	} else if (S_ISREG(st.st_mode)) {
		if (format_for_ext(path) != NULL) {
			file_list_add(fl, path);
		} else {
			warn_msg("skipping unsupported file: %s", path);
		}
	}
}

/* ── Progress bar ───────────────────────────────────────────────────── */

typedef struct {
	int      total;
	int      current;
	time_t   start_time;
	int      is_tty;
} progress_t;

static void progress_init(progress_t* p, int total) {
	p->total = total;
	p->current = 0;
	p->start_time = time(NULL);
	p->is_tty = isatty(STDERR_FILENO);
}

static void progress_update(progress_t* p, int current, const char* filename) {
	p->current = current;
	if (!g_show_progress || !p->is_tty) return;

	time_t now = time(NULL);
	double elapsed = difftime(now, p->start_time);
	double rate = (elapsed > 0) ? (double)current / elapsed : 0.0;

	int bar_width = 20;
	int filled = (p->total > 0) ? (current * bar_width / p->total) : 0;

	fprintf(stderr, "\r  [");
	for (int i = 0; i < bar_width; i++) {
		if (i < filled)
			fprintf(stderr, "%s%s%s",
				color(ANSI_GREEN), g_use_simple ? "#" : "\xe2\x96\x88", color(ANSI_RESET));
		else
			fprintf(stderr, "%s%s%s",
				color(ANSI_DIM), g_use_simple ? "." : "\xe2\x96\x91", color(ANSI_RESET));
	}
	fprintf(stderr, "] %d/%d", current, p->total);

	if (rate > 0.01) {
		fprintf(stderr, " | %.1f files/sec", rate);
		if (current < p->total) {
			int eta = (int)((double)(p->total - current) / rate);
			fprintf(stderr, " | ETA %ds", eta);
		}
	}

	/* Show truncated filename */
	if (filename) {
		const char* base = strrchr(filename, '/');
		base = base ? base + 1 : filename;
		fprintf(stderr, " %s%s%s", color(ANSI_DIM), base, color(ANSI_RESET));
	}

	/* Pad with spaces to clear previous longer line */
	fprintf(stderr, "   ");
	fflush(stderr);
}

static void progress_finish(progress_t* p) {
	if (!g_show_progress || !p->is_tty) return;
	fprintf(stderr, "\r");
	/* Clear the line */
	for (int i = 0; i < 100; i++) fputc(' ', stderr);
	fprintf(stderr, "\r");
	fflush(stderr);
}

/* ── Database path resolution ───────────────────────────────────────── */

/*
 * Resolve the database path.
 * If --db was given, use that.
 * Otherwise: <target_dir>/.docscan/index.db
 * Creates the .docscan directory if needed.
 */
static char* resolve_db_path(const char* explicit_db, const char* target_path) {
	if (explicit_db) return strdup(explicit_db);

	/* Use env var if set */
	const char* env_db = getenv("DOCSCAN_DB");
	if (env_db && env_db[0]) return strdup(env_db);

	/* Default: <target_path>/.docscan/index.db */
	char dir[MAX_PATH_LEN];

	/* If target_path is a file, use its directory */
	struct stat st;
	if (stat(target_path, &st) == 0 && S_ISREG(st.st_mode)) {
		/* Find last / */
		const char* slash = strrchr(target_path, '/');
		if (slash) {
			size_t dlen = (size_t)(slash - target_path);
			memcpy(dir, target_path, dlen);
			dir[dlen] = '\0';
		} else {
			strcpy(dir, ".");
		}
	} else {
		/* It's a directory (or doesn't exist yet) */
		snprintf(dir, sizeof(dir), "%s", target_path);
	}

	/* Create .docscan subdir */
	char docscan_dir[MAX_PATH_LEN];
	snprintf(docscan_dir, sizeof(docscan_dir), "%s/%s", dir, DEFAULT_DB_SUBDIR);
	mkdir(docscan_dir, 0755); /* ignore error if exists */

	char* db_path = malloc(MAX_PATH_LEN);
	snprintf(db_path, MAX_PATH_LEN, "%s/%s", docscan_dir, DEFAULT_DB_FILENAME);
	return db_path;
}

/* ── Help / About ───────────────────────────────────────────────────── */

static void print_help(void) {
	printf(
		"%sdocscan%s — document indexing and semantic search\n"
		"\n"
		"%sUSAGE%s\n"
		"  docscan <command> [args...] [flags...]\n"
		"\n"
		"%sCOMMANDS%s\n"
		"  index <path>          Index a directory or file\n"
		"  update [path]         Re-index changed files only\n"
		"  search <query>        Search indexed documents\n"
		"  status                Show index statistics\n"
		"  config [key] [value]  Get/set configuration\n"
		"  mcp-serve             Start MCP server (stdio)\n"
		"\n"
		"%sFLAGS%s\n"
		"  -h, --help            Show this help\n"
		"  --about               Show version and platform info\n"
		"  --json                Output as JSON\n"
		"  --limit N             Limit search results (default: 10)\n"
		"  --exact               Exact (FTS5-only) search\n"
		"  --similar             Similar (vector-only) search\n"
		"  --model <name>        Embedding model name (default: nomic-embed-text)\n"
		"  --db <path>           Database path (default: .docscan/index.db)\n"
		"  --embedding-api <dialect>  Embedding API: ollama or openai (default: ollama)\n"
		"  --embedding-url <url>      Embedding server URL (default: http://127.0.0.1:11434)\n"
		"  --embedding-api-key <key>  API key for OpenAI-compatible servers\n"
		"  --no-color            Disable ANSI colors\n"
		"  --no-progress         Disable progress bar\n"
		"  --simple              Plain output (no color, no emoji)\n"
		"  --lang <code>         Language override\n"
		"\n"
		"%sENVIRONMENT%s\n"
		"  DOCSCAN_MODEL              Default embedding model\n"
		"  DOCSCAN_DB                 Default database path\n"
		"  DOCSCAN_EMBEDDING_API      Embedding API dialect: ollama or openai\n"
		"  DOCSCAN_EMBEDDING_URL      Embedding server URL\n"
		"  DOCSCAN_EMBEDDING_API_KEY  API key for OpenAI-compatible servers\n"
		"  DOCSCAN_LANG               Language override\n"
		"\n"
		"%sEXAMPLES%s\n"
		"  docscan index ~/Documents\n"
		"  docscan search \"contract renewal terms\"\n"
		"  docscan search --exact \"indemnification clause\"\n"
		"  docscan update ~/Documents\n"
		"  docscan status\n"
		"  docscan config model nomic-embed-text\n",
		color(ANSI_BOLD), color(ANSI_RESET),
		color(ANSI_BOLD), color(ANSI_RESET),
		color(ANSI_BOLD), color(ANSI_RESET),
		color(ANSI_BOLD), color(ANSI_RESET),
		color(ANSI_BOLD), color(ANSI_RESET),
		color(ANSI_BOLD), color(ANSI_RESET)
	);
}

static void print_about(void) {
	struct utsname uname_buf;
	const char* os = "unknown";
	const char* arch = "unknown";
	if (uname(&uname_buf) == 0) {
		os = uname_buf.sysname;
		arch = uname_buf.machine;
	}
	/* Normalize: "Darwin" -> "darwin", "x86_64" stays, "arm64" stays */
	char os_lower[64];
	for (int i = 0; i < 63 && os[i]; i++) {
		os_lower[i] = (char)tolower((unsigned char)os[i]);
		os_lower[i+1] = '\0';
	}

	printf("docscan %s %s/%s — document indexing and semantic search\n",
	       docscan_version(), os_lower, arch);
}

/* ── Command: status ────────────────────────────────────────────────── */

static int cmd_status(const char* db_path_arg) {
	char err_buf[ERR_BUF_LEN];

	/* For status, we need an existing DB. Try to find one. */
	char* db_path = resolve_db_path(db_path_arg, ".");
	if (!db_path) {
		err_msg("could not determine database path");
		return 1;
	}

	/* Check if DB file exists */
	struct stat st;
	if (stat(db_path, &st) != 0) {
		if (g_json_output) {
			printf("{\"error\":\"no database found at %s\"}\n", db_path);
		} else {
			fprintf(stderr, "No database found at %s\n", db_path);
			fprintf(stderr, "Run 'docscan index <path>' first.\n");
		}
		free(db_path);
		return 1;
	}

	docscan_db* db = docscan_open(db_path, DEFAULT_EMBEDDING_DIM, err_buf, sizeof(err_buf));
	if (!db) {
		err_msg("failed to open database: %s", err_buf);
		free(db_path);
		return 1;
	}

	char* status_json = docscan_status(db, err_buf, sizeof(err_buf));
	docscan_close(db);

	if (!status_json) {
		err_msg("failed to get status: %s", err_buf);
		free(db_path);
		return 1;
	}

	if (g_json_output) {
		printf("%s\n", status_json);
	} else {
		/* Pretty-print the status JSON */
		/* Parse doc_count, chunk_count, last_indexed from the JSON */
		int doc_count = 0, chunk_count = 0;
		long long last_indexed = 0;

		/* Minimal JSON number extraction */
		const char* p;
		p = strstr(status_json, "\"doc_count\":");
		if (p) doc_count = atoi(p + 12);
		p = strstr(status_json, "\"chunk_count\":");
		if (p) chunk_count = atoi(p + 14);
		p = strstr(status_json, "\"last_indexed\":");
		if (p) last_indexed = atoll(p + 15);

		printf("%s%sdocscan index status%s\n", color(ANSI_BOLD), color(ANSI_CYAN), color(ANSI_RESET));
		printf("  Database: %s\n", db_path);
		printf("  Documents: %s%d%s\n", color(ANSI_GREEN), doc_count, color(ANSI_RESET));
		printf("  Chunks: %s%d%s\n", color(ANSI_GREEN), chunk_count, color(ANSI_RESET));
		if (last_indexed > 0) {
			time_t t = (time_t)last_indexed;
			char timebuf[64];
			struct tm* tm = localtime(&t);
			strftime(timebuf, sizeof(timebuf), "%Y-%m-%d %H:%M:%S", tm);
			printf("  Last indexed: %s\n", timebuf);
		} else {
			printf("  Last indexed: never\n");
		}
	}

	docscan_free(status_json);
	free(db_path);
	return 0;
}

/* ── Command: config ────────────────────────────────────────────────── */

static int cmd_config(const char* db_path_arg, const char* key, const char* value) {
	char err_buf[ERR_BUF_LEN];

	char* db_path = resolve_db_path(db_path_arg, ".");
	if (!db_path) {
		err_msg("could not determine database path");
		return 1;
	}

	docscan_db* db = docscan_open(db_path, DEFAULT_EMBEDDING_DIM, err_buf, sizeof(err_buf));
	if (!db) {
		err_msg("failed to open database: %s", err_buf);
		free(db_path);
		return 1;
	}

	if (key == NULL) {
		/* Show all config — just show known keys */
		const char* known_keys[] = { "model", "embedding_dim", "max_chunk_tokens", "lang", NULL };
		if (g_json_output) printf("{");
		int first = 1;
		for (int i = 0; known_keys[i]; i++) {
			char* val = docscan_config_get(db, known_keys[i], err_buf, sizeof(err_buf));
			if (val) {
				if (g_json_output) {
					printf("%s\"%s\":\"%s\"", first ? "" : ",", known_keys[i], val);
				} else {
					printf("  %s%s%s = %s\n", color(ANSI_CYAN), known_keys[i], color(ANSI_RESET), val);
				}
				docscan_free(val);
				first = 0;
			}
		}
		if (g_json_output) printf("}\n");
		if (first && !g_json_output) {
			printf("  (no configuration set)\n");
		}
	} else if (value == NULL) {
		/* Get single key */
		char* val = docscan_config_get(db, key, err_buf, sizeof(err_buf));
		if (val) {
			if (g_json_output) {
				printf("{\"%s\":\"%s\"}\n", key, val);
			} else {
				printf("%s\n", val);
			}
			docscan_free(val);
		} else {
			if (g_json_output) {
				printf("{\"error\":\"key not found: %s\"}\n", key);
			} else {
				fprintf(stderr, "Key '%s' not set\n", key);
			}
			docscan_close(db);
			free(db_path);
			return 1;
		}
	} else {
		/* Set key=value */
		int rc = docscan_config_set(db, key, value, err_buf, sizeof(err_buf));
		if (rc != 0) {
			err_msg("failed to set config: %s", err_buf);
			docscan_close(db);
			free(db_path);
			return 1;
		}
		if (!g_json_output) {
			printf("Set %s%s%s = %s\n", color(ANSI_CYAN), key, color(ANSI_RESET), value);
		} else {
			printf("{\"ok\":true}\n");
		}
	}

	docscan_close(db);
	free(db_path);
	return 0;
}

/* ── Command: search ────────────────────────────────────────────────── */

static int cmd_search(const char* db_path_arg, const char* query,
                       const char* mode, int limit, const char* model)
{
	char err_buf[ERR_BUF_LEN];

	if (!query || !query[0]) {
		err_msg("search requires a query string");
		return 1;
	}

	char* db_path = resolve_db_path(db_path_arg, ".");
	if (!db_path) {
		err_msg("could not determine database path");
		return 1;
	}

	struct stat st;
	if (stat(db_path, &st) != 0) {
		err_msg("no database found at %s — run 'docscan index <path>' first", db_path);
		free(db_path);
		return 1;
	}

	docscan_db* db = docscan_open(db_path, DEFAULT_EMBEDDING_DIM, err_buf, sizeof(err_buf));
	if (!db) {
		err_msg("failed to open database: %s", err_buf);
		free(db_path);
		return 1;
	}

	/* Embed the query unless exact mode */
	float* query_emb = NULL;
	int emb_dim = 0;

	if (strcmp(mode, "exact") != 0) {
		/* Need embedding server for semantic search */
		if (!embedding_server_available()) {
			if (strcmp(mode, "similar") == 0) {
				err_msg("Embedding server is not running at %s (needed for vector search).\n"
				        "  Start it, or use --exact for text-only search.",
				        g_embedding_url);
				docscan_close(db);
				free(db_path);
				return 1;
			}
			/* Hybrid mode: fall back to exact */
			warn_msg("Embedding server not available, falling back to text-only search");
			mode = "exact";
		} else {
			char* texts[1];
			texts[0] = (char*)query;
			query_emb = embed_texts(model, texts, 1, &emb_dim);
			if (!query_emb) {
				if (strcmp(mode, "similar") == 0) {
					err_msg("failed to embed query via %s",
					        g_api_dialect == API_OPENAI ? "OpenAI-compatible API" : "Ollama");
					docscan_close(db);
					free(db_path);
					return 1;
				}
				warn_msg("embedding failed, falling back to text-only search");
				mode = "exact";
			}
		}
	}

	char* results_json = docscan_search(db, query,
	                                     query_emb, (uint32_t)emb_dim,
	                                     mode, (uint32_t)limit, NULL,
	                                     err_buf, sizeof(err_buf));
	free(query_emb);
	docscan_close(db);

	if (!results_json) {
		err_msg("search failed: %s", err_buf);
		free(db_path);
		return 1;
	}

	if (g_json_output) {
		printf("%s\n", results_json);
	} else {
		/* Pretty-print search results */
		/* Check if empty */
		if (strcmp(results_json, "[]") == 0) {
			printf("No results found for \"%s\"\n", query);
		} else {
			/* Parse and display results */
			printf("%sSearch results for%s \"%s%s%s\" %s(%s mode, limit %d)%s\n\n",
				color(ANSI_DIM), color(ANSI_RESET),
				color(ANSI_BOLD), query, color(ANSI_RESET),
				color(ANSI_DIM), mode, limit, color(ANSI_RESET));

			/* Walk through JSON array and extract fields for display */
			int result_num = 0;
			const char* p = results_json;
			while ((p = strstr(p, "{\"document_path\"")) != NULL) {
				result_num++;

				/* Extract document_path */
				const char* dp_start = strstr(p, "\"document_path\":\"");
				char doc_path[MAX_PATH_LEN] = "";
				if (dp_start) {
					dp_start += 17;
					const char* dp_end = strchr(dp_start, '"');
					if (dp_end) {
						size_t len = (size_t)(dp_end - dp_start);
						if (len < sizeof(doc_path)) {
							memcpy(doc_path, dp_start, len);
							doc_path[len] = '\0';
						}
					}
				}

				/* Extract heading */
				char heading[512] = "";
				const char* h_start = strstr(p, "\"heading\":\"");
				if (h_start) {
					h_start += 11;
					const char* h_end = strchr(h_start, '"');
					if (h_end) {
						size_t len = (size_t)(h_end - h_start);
						if (len < sizeof(heading)) {
							memcpy(heading, h_start, len);
							heading[len] = '\0';
						}
					}
				}

				/* Extract score */
				float score = 0.0f;
				const char* sc_start = strstr(p, "\"score\":");
				if (sc_start) score = strtof(sc_start + 8, NULL);

				/* Extract text snippet (first 200 chars) */
				char snippet[256] = "";
				const char* t_start = strstr(p, "\"text\":\"");
				if (t_start) {
					t_start += 8;
					size_t len = 0;
					const char* t = t_start;
					while (*t && *t != '"' && len < sizeof(snippet) - 1) {
						if (*t == '\\' && *(t+1)) {
							t++; /* skip escape */
							switch (*t) {
								case 'n': snippet[len++] = ' '; break;
								case 't': snippet[len++] = ' '; break;
								default: snippet[len++] = *t; break;
							}
						} else {
							snippet[len++] = *t;
						}
						t++;
					}
					snippet[len] = '\0';
				}

				/* Display result */
				printf("  %s%d.%s %s%s%s",
					color(ANSI_DIM), result_num, color(ANSI_RESET),
					color(ANSI_BOLD), doc_path, color(ANSI_RESET));
				if (heading[0]) {
					printf(" %s> %s%s", color(ANSI_CYAN), heading, color(ANSI_RESET));
				}
				printf("\n");
				printf("     %sscore: %.4f%s\n", color(ANSI_DIM), score, color(ANSI_RESET));
				if (snippet[0]) {
					printf("     %s\n", snippet);
				}
				printf("\n");

				p++; /* advance past current match */
			}
		}
	}

	docscan_free(results_json);
	free(db_path);
	return 0;
}

/* ── Command: index / update ────────────────────────────────────────── */

static int cmd_index(const char* db_path_arg, const char* target_path,
                      const char* model, int update_only)
{
	char err_buf[ERR_BUF_LEN];

	if (!target_path || !target_path[0]) {
		err_msg("%s requires a path argument", update_only ? "update" : "index");
		return 1;
	}

	/* Resolve to absolute path */
	char abs_path[MAX_PATH_LEN];
	if (target_path[0] != '/') {
		char cwd[MAX_PATH_LEN];
		if (getcwd(cwd, sizeof(cwd))) {
			snprintf(abs_path, sizeof(abs_path), "%s/%s", cwd, target_path);
		} else {
			snprintf(abs_path, sizeof(abs_path), "%s", target_path);
		}
	} else {
		snprintf(abs_path, sizeof(abs_path), "%s", target_path);
	}

	/* Remove trailing slash */
	size_t plen = strlen(abs_path);
	if (plen > 1 && abs_path[plen - 1] == '/') abs_path[plen - 1] = '\0';

	/* Collect files */
	file_list fl;
	file_list_init(&fl);
	collect_files(abs_path, &fl);

	if (fl.count == 0) {
		if (g_json_output) {
			printf("{\"indexed\":0,\"skipped\":0,\"errors\":0}\n");
		} else {
			printf("No supported files found in %s\n", abs_path);
		}
		file_list_free(&fl);
		return 0;
	}

	info_msg("Found %d supported file%s in %s",
	         fl.count, fl.count == 1 ? "" : "s", abs_path);

	/* Resolve DB path relative to the target directory */
	char* db_path = resolve_db_path(db_path_arg, abs_path);
	if (!db_path) {
		err_msg("could not determine database path");
		file_list_free(&fl);
		return 1;
	}

	/* Check embedding server availability */
	int have_embedder = embedding_server_available();
	if (!have_embedder) {
		warn_msg("Embedding server is not running at %s", g_embedding_url);
		warn_msg("Documents will be indexed without embeddings (text search only).");
	}

	/* Open/create database */
	docscan_db* db = docscan_open(db_path, DEFAULT_EMBEDDING_DIM, err_buf, sizeof(err_buf));
	if (!db) {
		err_msg("failed to open database: %s", err_buf);
		free(db_path);
		file_list_free(&fl);
		return 1;
	}

	/* Store model in config */
	docscan_config_set(db, "model", model, err_buf, sizeof(err_buf));

	/* Process files */
	progress_t prog;
	progress_init(&prog, fl.count);

	int indexed = 0, skipped = 0, errors = 0;

	for (int i = 0; i < fl.count; i++) {
		progress_update(&prog, i, fl.paths[i]);

		const char* fpath = fl.paths[i];
		const char* fmt = format_for_ext(fpath);
		if (!fmt) { skipped++; continue; }

		/* Read file */
		size_t file_len = 0;
		uint8_t* file_data = read_file(fpath, &file_len);
		if (!file_data) {
			warn_msg("could not read: %s", fpath);
			errors++;
			continue;
		}

		/* Compute hash */
		char hash_hex[SHA256_HEX_LEN + 1];
		sha256_hex(file_data, file_len, hash_hex);

		/* Check if reindex needed */
		int needs = docscan_needs_reindex(db, fpath, hash_hex);
		if (needs == 0) {
			/* Up to date */
			free(file_data);
			skipped++;
			continue;
		}
		if (needs < 0) {
			warn_msg("error checking reindex status for %s", fpath);
			free(file_data);
			errors++;
			continue;
		}

		/* If update_only mode and document doesn't need reindex, skip.
		 * (Already handled above — needs_reindex == 0 means skip.) */

		/* Remove old document if it exists (for re-indexing) */
		docscan_remove_document(db, fpath, err_buf, sizeof(err_buf));

		/* Get chunk count by calling docscan_chunk */
		float* embeddings = NULL;
		uint32_t num_chunks = 0;

		if (have_embedder) {
			char* chunks_json = docscan_chunk(file_data, file_len, fpath, fmt,
			                                   DEFAULT_MAX_TOKENS, err_buf, sizeof(err_buf));
			if (chunks_json) {
				/* Count chunks and extract text for embedding */
				num_chunks = (uint32_t)count_json_array_objects(chunks_json);

				if (num_chunks > 0) {
					int text_count = 0;
					char** texts = extract_chunk_texts(chunks_json, &text_count);
					if (texts && text_count > 0) {
						int dim = 0;
						embeddings = embed_texts(model, texts, text_count, &dim);
						if (embeddings) {
							num_chunks = (uint32_t)text_count;
						}
						/* Free texts */
						for (int t = 0; t < text_count; t++) free(texts[t]);
						free(texts);
					}
				}
				docscan_free(chunks_json);
			}
		}

		/* Index the file */
		int rc = docscan_index_file(db, file_data, file_len, fpath, fmt,
		                             hash_hex, embeddings, num_chunks,
		                             DEFAULT_MAX_TOKENS, err_buf, sizeof(err_buf));
		free(file_data);
		free(embeddings);

		if (rc == 0) {
			indexed++;
		} else {
			warn_msg("failed to index %s: %s", fpath, err_buf);
			errors++;
		}
	}

	progress_update(&prog, fl.count, NULL);
	progress_finish(&prog);

	docscan_close(db);

	/* Summary */
	if (g_json_output) {
		printf("{\"indexed\":%d,\"skipped\":%d,\"errors\":%d}\n",
		       indexed, skipped, errors);
	} else {
		time_t now = time(NULL);
		double elapsed = difftime(now, prog.start_time);

		printf("\n%s%s complete%s\n",
			color(ANSI_BOLD),
			update_only ? "Update" : "Indexing",
			color(ANSI_RESET));
		printf("  %s%s%s%d indexed%s",
			g_use_simple ? "" : "\xe2\x9c\x93 ",  /* checkmark */
			color(ANSI_GREEN), color(ANSI_BOLD), indexed, color(ANSI_RESET));
		if (skipped > 0)
			printf(", %s%d skipped%s (up to date)",
				color(ANSI_DIM), skipped, color(ANSI_RESET));
		if (errors > 0)
			printf(", %s%s%d errors%s",
				color(ANSI_RED), color(ANSI_BOLD), errors, color(ANSI_RESET));
		printf("\n");
		if (elapsed >= 1.0) {
			printf("  Time: %.1fs", elapsed);
			if (indexed > 0)
				printf(" (%.1f files/sec)", (double)indexed / elapsed);
			printf("\n");
		}
		printf("  Database: %s\n", db_path);
		if (!have_embedder) {
			printf("  %sNote: no embeddings stored (embedding server was not running)%s\n",
				color(ANSI_YELLOW), color(ANSI_RESET));
		}
	}

	free(db_path);
	file_list_free(&fl);
	return (errors > 0 && indexed == 0) ? 1 : 0;
}

/* ── Command: mcp-serve — JSON-RPC 2.0 / MCP over stdio ────────────── */

/*
 * Minimal JSON extraction helpers.
 * These are NOT general-purpose JSON parsers — they handle the specific
 * shapes that MCP clients send (flat objects, no nested keys with the
 * same name, no arrays-of-objects as values for extracted keys).
 */

/* Extract a string value for "key" from a JSON object. Writes into buf,
 * returns buf on success, NULL if not found. Handles \" escapes. */
static const char* mcp_json_get_string(const char* json, const char* key,
                                        char* buf, size_t buf_len)
{
	if (!json || !key || !buf || buf_len == 0) return NULL;

	/* Build search pattern: "key" */
	char pattern[256];
	int plen = snprintf(pattern, sizeof(pattern), "\"%s\"", key);
	if (plen <= 0 || (size_t)plen >= sizeof(pattern)) return NULL;

	const char* p = strstr(json, pattern);
	if (!p) return NULL;
	p += plen;

	/* Skip whitespace and colon */
	while (*p && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
	if (*p != ':') return NULL;
	p++;
	while (*p && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;

	if (*p == 'n' && strncmp(p, "null", 4) == 0) return NULL;
	if (*p != '"') return NULL;
	p++; /* past opening quote */

	size_t i = 0;
	while (*p && *p != '"' && i + 1 < buf_len) {
		if (*p == '\\' && *(p + 1)) {
			p++;
			switch (*p) {
				case 'n': buf[i++] = '\n'; break;
				case 'r': buf[i++] = '\r'; break;
				case 't': buf[i++] = '\t'; break;
				case '"': buf[i++] = '"';  break;
				case '\\': buf[i++] = '\\'; break;
				case '/': buf[i++] = '/';  break;
				default: buf[i++] = *p;    break;
			}
		} else {
			buf[i++] = *p;
		}
		p++;
	}
	buf[i] = '\0';
	return buf;
}

/* Extract an integer value for "key" from a JSON object.
 * Returns default_val if not found. */
static int mcp_json_get_int(const char* json, const char* key, int default_val) {
	if (!json || !key) return default_val;

	char pattern[256];
	int plen = snprintf(pattern, sizeof(pattern), "\"%s\"", key);
	if (plen <= 0 || (size_t)plen >= sizeof(pattern)) return default_val;

	const char* p = strstr(json, pattern);
	if (!p) return default_val;
	p += plen;

	while (*p && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
	if (*p != ':') return default_val;
	p++;
	while (*p && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;

	if (*p == '"') {
		/* Quoted number: "123" — parse the integer inside */
		p++;
		return atoi(p);
	}
	if (*p == '-' || (*p >= '0' && *p <= '9')) {
		return atoi(p);
	}
	return default_val;
}

/* Check whether a key exists and its value is absent/null (for distinguishing
 * "key omitted" from "key present with value"). */
static int mcp_json_has_key(const char* json, const char* key) {
	if (!json || !key) return 0;
	char pattern[256];
	snprintf(pattern, sizeof(pattern), "\"%s\"", key);
	return strstr(json, pattern) != NULL;
}

/* Extract the "params" sub-object from a JSON-RPC request.
 * Returns pointer into the original string at the opening '{' of params,
 * or NULL if not found. */
static const char* mcp_json_get_params(const char* json) {
	const char* p = strstr(json, "\"params\"");
	if (!p) return NULL;
	p += 8;
	while (*p && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
	if (*p != ':') return NULL;
	p++;
	while (*p && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
	if (*p == '{') return p;
	return NULL;
}

/* Extract the "arguments" sub-object from within params.
 * Returns pointer to opening '{', or NULL. */
static const char* mcp_json_get_arguments(const char* params) {
	const char* p = strstr(params, "\"arguments\"");
	if (!p) return NULL;
	p += 11;
	while (*p && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
	if (*p != ':') return NULL;
	p++;
	while (*p && (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
	if (*p == '{') return p;
	return NULL;
}

/* ── MCP response helpers ───────────────────────────────────────────── */

/* Write a JSON-RPC success response wrapping MCP content.
 * The text is JSON-escaped before embedding. */
static void mcp_write_result_text(const char* id_str, const char* text) {
	/* Escape the text for embedding in JSON string */
	size_t text_len = text ? strlen(text) : 0;
	size_t esc_cap = text_len * 6 + 16; /* worst case: every char becomes \uXXXX */
	char* escaped = malloc(esc_cap);
	if (!escaped) return;

	size_t j = 0;
	for (size_t i = 0; i < text_len && j + 7 < esc_cap; i++) {
		switch (text[i]) {
			case '"':  escaped[j++] = '\\'; escaped[j++] = '"'; break;
			case '\\': escaped[j++] = '\\'; escaped[j++] = '\\'; break;
			case '\n': escaped[j++] = '\\'; escaped[j++] = 'n'; break;
			case '\r': escaped[j++] = '\\'; escaped[j++] = 'r'; break;
			case '\t': escaped[j++] = '\\'; escaped[j++] = 't'; break;
			default:
				if ((unsigned char)text[i] < 0x20) {
					j += (size_t)snprintf(escaped + j, esc_cap - j,
					                       "\\u%04x", (unsigned char)text[i]);
				} else {
					escaped[j++] = text[i];
				}
				break;
		}
	}
	escaped[j] = '\0';

	printf("{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":"
	       "{\"content\":[{\"type\":\"text\",\"text\":\"%s\"}]}}\n",
	       id_str, escaped);
	fflush(stdout);
	free(escaped);
}

/* Write a raw JSON result (already valid JSON, e.g. from FFI). */
static void mcp_write_result_raw(const char* id_str, const char* raw_json) {
	/* Embed the raw JSON as the text content (escaped) */
	mcp_write_result_text(id_str, raw_json);
}

/* Write a JSON-RPC success response with a raw result object (not MCP content). */
static void mcp_write_raw_result(const char* id_str, const char* result_json) {
	/* Strip any embedded newlines from result_json to keep response on one line */
	size_t len = strlen(result_json);
	char* clean = malloc(len + 1);
	if (!clean) return;
	size_t j = 0;
	for (size_t i = 0; i < len; i++) {
		if (result_json[i] == '\n' || result_json[i] == '\r') {
			clean[j++] = ' ';
		} else {
			clean[j++] = result_json[i];
		}
	}
	clean[j] = '\0';

	printf("{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":%s}\n", id_str, clean);
	fflush(stdout);
	free(clean);
}

/* Write a JSON-RPC error response. */
static void mcp_write_error(const char* id_str, int code, const char* message) {
	/* Escape the message */
	size_t mlen = message ? strlen(message) : 0;
	size_t esc_cap = mlen * 6 + 16;
	char* escaped = malloc(esc_cap);
	if (!escaped) return;

	size_t j = 0;
	for (size_t i = 0; i < mlen && j + 7 < esc_cap; i++) {
		switch (message[i]) {
			case '"':  escaped[j++] = '\\'; escaped[j++] = '"'; break;
			case '\\': escaped[j++] = '\\'; escaped[j++] = '\\'; break;
			case '\n': escaped[j++] = '\\'; escaped[j++] = 'n'; break;
			case '\r': escaped[j++] = '\\'; escaped[j++] = 'r'; break;
			default:   escaped[j++] = message[i]; break;
		}
	}
	escaped[j] = '\0';

	printf("{\"jsonrpc\":\"2.0\",\"id\":%s,\"error\":{\"code\":%d,\"message\":\"%s\"}}\n",
	       id_str, code, escaped);
	fflush(stdout);
	free(escaped);
}

/* ── MCP tool definitions ───────────────────────────────────────────── */

#define MCP_TOOLS_JSON \
	"[" \
	"{" \
		"\"name\":\"docscan_search\"," \
		"\"description\":\"Search indexed documents using hybrid vector+lexical, exact, or similar mode\"," \
		"\"inputSchema\":{" \
			"\"type\":\"object\"," \
			"\"properties\":{" \
				"\"query\":{\"type\":\"string\",\"description\":\"Search query text\"}," \
				"\"mode\":{\"type\":\"string\",\"enum\":[\"hybrid\",\"exact\",\"similar\"],\"default\":\"hybrid\"}," \
				"\"limit\":{\"type\":\"integer\",\"default\":10}," \
				"\"format_filter\":{\"type\":\"string\",\"description\":\"Filter by format (md, docx, pdf, doc)\"}" \
			"}," \
			"\"required\":[\"query\"]" \
		"}" \
	"}," \
	"{" \
		"\"name\":\"docscan_status\"," \
		"\"description\":\"Show index statistics (document count, chunk count, last indexed)\"," \
		"\"inputSchema\":{\"type\":\"object\",\"properties\":{}}" \
	"}," \
	"{" \
		"\"name\":\"docscan_read_chunk\"," \
		"\"description\":\"Retrieve full text of a specific chunk by ID\"," \
		"\"inputSchema\":{" \
			"\"type\":\"object\"," \
			"\"properties\":{" \
				"\"chunk_id\":{\"type\":\"integer\",\"description\":\"Chunk ID from search results\"}" \
			"}," \
			"\"required\":[\"chunk_id\"]" \
		"}" \
	"}," \
	"{" \
		"\"name\":\"docscan_list_docs\"," \
		"\"description\":\"List all indexed documents\"," \
		"\"inputSchema\":{\"type\":\"object\",\"properties\":{}}" \
	"}," \
	"{" \
		"\"name\":\"docscan_config\"," \
		"\"description\":\"Get or set configuration values\"," \
		"\"inputSchema\":{" \
			"\"type\":\"object\"," \
			"\"properties\":{" \
				"\"key\":{\"type\":\"string\",\"description\":\"Config key\"}," \
				"\"value\":{\"type\":\"string\",\"description\":\"Value to set (omit to get)\"}" \
			"}," \
			"\"required\":[\"key\"]" \
		"}" \
	"}," \
	"{" \
		"\"name\":\"docscan_index\"," \
		"\"description\":\"Index a file or directory\"," \
		"\"inputSchema\":{" \
			"\"type\":\"object\"," \
			"\"properties\":{" \
				"\"path\":{\"type\":\"string\",\"description\":\"Path to file or directory to index\"}" \
			"}," \
			"\"required\":[\"path\"]" \
		"}" \
	"}," \
	"{" \
		"\"name\":\"docscan_update\"," \
		"\"description\":\"Re-index changed files\"," \
		"\"inputSchema\":{" \
			"\"type\":\"object\"," \
			"\"properties\":{" \
				"\"path\":{\"type\":\"string\",\"description\":\"Path to check for updates\"}" \
			"}" \
		"}" \
	"}" \
	"]"

/* ── MCP tool handlers ──────────────────────────────────────────────── */

static void mcp_handle_search(docscan_db* db, const char* model,
                               const char* args, const char* id_str)
{
	char err_buf[ERR_BUF_LEN];
	char query_buf[4096];
	char mode_buf[32];
	char filter_buf[64];

	const char* query = mcp_json_get_string(args, "query", query_buf, sizeof(query_buf));
	if (!query || !query[0]) {
		mcp_write_error(id_str, -32602, "Missing required parameter: query");
		return;
	}

	const char* mode = mcp_json_get_string(args, "mode", mode_buf, sizeof(mode_buf));
	if (!mode || !mode[0]) mode = "hybrid";

	int limit = mcp_json_get_int(args, "limit", DEFAULT_LIMIT);
	if (limit <= 0) limit = DEFAULT_LIMIT;

	const char* filter = mcp_json_get_string(args, "format_filter",
	                                          filter_buf, sizeof(filter_buf));

	/* Embed query for non-exact modes */
	float* query_emb = NULL;
	int emb_dim = 0;

	if (strcmp(mode, "exact") != 0) {
		if (embedding_server_available()) {
			char* texts[1];
			texts[0] = (char*)query;
			query_emb = embed_texts(model, texts, 1, &emb_dim);
		}
		if (!query_emb && strcmp(mode, "similar") == 0) {
			mcp_write_error(id_str, -32603,
				"Embedding server not available (needed for vector search).");
			return;
		}
		if (!query_emb) {
			/* Hybrid fallback to exact */
			mode = "exact";
		}
	}

	char* results = docscan_search(db, query, query_emb, (uint32_t)emb_dim,
	                                mode, (uint32_t)limit,
	                                (filter && filter[0]) ? filter : NULL,
	                                err_buf, sizeof(err_buf));
	free(query_emb);

	if (!results) {
		mcp_write_error(id_str, -32603, err_buf);
		return;
	}

	mcp_write_result_raw(id_str, results);
	docscan_free(results);
}

static void mcp_handle_status(docscan_db* db, const char* id_str) {
	char err_buf[ERR_BUF_LEN];
	char* status = docscan_status(db, err_buf, sizeof(err_buf));
	if (!status) {
		mcp_write_error(id_str, -32603, err_buf);
		return;
	}
	mcp_write_result_raw(id_str, status);
	docscan_free(status);
}

static void mcp_handle_read_chunk(docscan_db* db, const char* args,
                                   const char* id_str)
{
	char err_buf[ERR_BUF_LEN];
	int chunk_id = mcp_json_get_int(args, "chunk_id", -1);
	if (chunk_id < 0) {
		mcp_write_error(id_str, -32602, "Missing required parameter: chunk_id");
		return;
	}

	char* chunk = docscan_read_chunk(db, (int64_t)chunk_id, err_buf, sizeof(err_buf));
	if (!chunk) {
		mcp_write_error(id_str, -32603, err_buf);
		return;
	}
	mcp_write_result_raw(id_str, chunk);
	docscan_free(chunk);
}

static void mcp_handle_list_docs(docscan_db* db, const char* id_str) {
	char err_buf[ERR_BUF_LEN];
	/* List docs via status — the FFI doesn't have a dedicated list_docs yet.
	 * Return status info which includes document count. */
	char* status = docscan_status(db, err_buf, sizeof(err_buf));
	if (!status) {
		mcp_write_error(id_str, -32603, err_buf);
		return;
	}
	mcp_write_result_raw(id_str, status);
	docscan_free(status);
}

static void mcp_handle_config(docscan_db* db, const char* args,
                               const char* id_str)
{
	char err_buf[ERR_BUF_LEN];
	char key_buf[256];
	char val_buf[4096];

	const char* key = mcp_json_get_string(args, "key", key_buf, sizeof(key_buf));
	if (!key || !key[0]) {
		mcp_write_error(id_str, -32602, "Missing required parameter: key");
		return;
	}

	/* Check if value is present (set) vs absent (get) */
	if (mcp_json_has_key(args, "value")) {
		const char* value = mcp_json_get_string(args, "value",
		                                         val_buf, sizeof(val_buf));
		if (!value) value = "";
		int rc = docscan_config_set(db, key, value, err_buf, sizeof(err_buf));
		if (rc != 0) {
			mcp_write_error(id_str, -32603, err_buf);
			return;
		}
		mcp_write_result_text(id_str, "ok");
	} else {
		char* val = docscan_config_get(db, key, err_buf, sizeof(err_buf));
		if (!val) {
			char msg[512];
			snprintf(msg, sizeof(msg), "Key not found: %s", key);
			mcp_write_result_text(id_str, msg);
			return;
		}
		mcp_write_result_text(id_str, val);
		docscan_free(val);
	}
}

static void mcp_handle_index(docscan_db* db, const char* model,
                              const char* args, const char* id_str)
{
	char err_buf[ERR_BUF_LEN];
	char path_buf[MAX_PATH_LEN];

	const char* path = mcp_json_get_string(args, "path", path_buf, sizeof(path_buf));
	if (!path || !path[0]) {
		mcp_write_error(id_str, -32602, "Missing required parameter: path");
		return;
	}

	/* Resolve to absolute path */
	char abs_path[MAX_PATH_LEN];
	if (path[0] != '/') {
		char cwd[MAX_PATH_LEN];
		if (getcwd(cwd, sizeof(cwd))) {
			snprintf(abs_path, sizeof(abs_path), "%s/%s", cwd, path);
		} else {
			snprintf(abs_path, sizeof(abs_path), "%s", path);
		}
	} else {
		snprintf(abs_path, sizeof(abs_path), "%s", path);
	}

	/* Collect files */
	file_list fl;
	file_list_init(&fl);
	collect_files(abs_path, &fl);

	if (fl.count == 0) {
		mcp_write_result_text(id_str, "No supported files found");
		file_list_free(&fl);
		return;
	}

	int have_embedder = embedding_server_available();
	int indexed = 0, skipped = 0, errors = 0;

	for (int i = 0; i < fl.count; i++) {
		const char* fpath = fl.paths[i];
		const char* fmt = format_for_ext(fpath);
		if (!fmt) { skipped++; continue; }

		size_t file_len = 0;
		uint8_t* file_data = read_file(fpath, &file_len);
		if (!file_data) { errors++; continue; }

		char hash_hex[SHA256_HEX_LEN + 1];
		sha256_hex(file_data, file_len, hash_hex);

		int needs = docscan_needs_reindex(db, fpath, hash_hex);
		if (needs == 0) { free(file_data); skipped++; continue; }
		if (needs < 0) { free(file_data); errors++; continue; }

		docscan_remove_document(db, fpath, err_buf, sizeof(err_buf));

		float* embeddings = NULL;
		uint32_t num_chunks = 0;

		if (have_embedder) {
			char* chunks_json = docscan_chunk(file_data, file_len, fpath, fmt,
			                                   DEFAULT_MAX_TOKENS, err_buf, sizeof(err_buf));
			if (chunks_json) {
				num_chunks = (uint32_t)count_json_array_objects(chunks_json);
				if (num_chunks > 0) {
					int text_count = 0;
					char** texts = extract_chunk_texts(chunks_json, &text_count);
					if (texts && text_count > 0) {
						int dim = 0;
						embeddings = embed_texts(model, texts, text_count, &dim);
						if (embeddings) num_chunks = (uint32_t)text_count;
						for (int t = 0; t < text_count; t++) free(texts[t]);
						free(texts);
					}
				}
				docscan_free(chunks_json);
			}
		}

		int rc = docscan_index_file(db, file_data, file_len, fpath, fmt,
		                             hash_hex, embeddings, num_chunks,
		                             DEFAULT_MAX_TOKENS, err_buf, sizeof(err_buf));
		free(file_data);
		free(embeddings);

		if (rc == 0) indexed++;
		else errors++;
	}

	file_list_free(&fl);

	char result[256];
	snprintf(result, sizeof(result),
	         "{\"indexed\":%d,\"skipped\":%d,\"errors\":%d}",
	         indexed, skipped, errors);
	mcp_write_result_text(id_str, result);
}

static void mcp_handle_update(docscan_db* db, const char* model,
                               const char* args, const char* id_str)
{
	/* Update is index with reindex check (same behavior — needs_reindex
	 * already handles the skip logic in mcp_handle_index). */
	mcp_handle_index(db, model, args, id_str);
}

/* ── MCP main loop ──────────────────────────────────────────────────── */

static int cmd_mcp_serve(const char* db_path_arg, const char* model) {
	char err_buf[ERR_BUF_LEN];

	/* Resolve database path */
	char* db_path = resolve_db_path(db_path_arg, ".");
	if (!db_path) {
		fprintf(stderr, "mcp-serve: could not determine database path\n");
		return 1;
	}

	docscan_db* db = docscan_open(db_path, DEFAULT_EMBEDDING_DIM,
	                               err_buf, sizeof(err_buf));
	if (!db) {
		fprintf(stderr, "mcp-serve: failed to open database: %s\n", err_buf);
		free(db_path);
		return 1;
	}

	fprintf(stderr, "docscan MCP server running (db: %s)\n", db_path);

	/* 1 MiB line buffer — MCP messages can be large */
	size_t line_cap = 1024 * 1024;
	char* line = malloc(line_cap);
	if (!line) {
		docscan_close(db);
		free(db_path);
		return 1;
	}

	while (fgets(line, (int)line_cap, stdin)) {
		/* Strip trailing whitespace/newlines */
		size_t len = strlen(line);
		while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'
		                    || line[len - 1] == ' '))
			line[--len] = '\0';

		if (len == 0) continue; /* skip blank lines */

		/* Extract method */
		char method[128];
		if (!mcp_json_get_string(line, "method", method, sizeof(method))) {
			/* No method — might be a response from client, ignore */
			continue;
		}

		/* Extract id. It can be an int, a string, or absent (notification).
		 * We store it as a raw JSON token for output. */
		char id_str[128];
		int has_id = 0;
		{
			/* Find "id" key and extract the raw value token */
			const char* p = strstr(line, "\"id\"");
			if (p) {
				p += 4;
				while (*p && (*p == ' ' || *p == '\t' || *p == ':')) p++;
				if (*p == '"') {
					/* String id — extract it quoted */
					const char* start = p; /* include the quote */
					p++;
					while (*p && *p != '"') {
						if (*p == '\\') p++;
						p++;
					}
					if (*p == '"') p++; /* include closing quote */
					size_t tok_len = (size_t)(p - start);
					if (tok_len < sizeof(id_str)) {
						memcpy(id_str, start, tok_len);
						id_str[tok_len] = '\0';
						has_id = 1;
					}
				} else if (*p == '-' || (*p >= '0' && *p <= '9')) {
					/* Numeric id */
					const char* start = p;
					if (*p == '-') p++;
					while (*p >= '0' && *p <= '9') p++;
					size_t tok_len = (size_t)(p - start);
					if (tok_len < sizeof(id_str)) {
						memcpy(id_str, start, tok_len);
						id_str[tok_len] = '\0';
						has_id = 1;
					}
				}
				/* null id: treat as notification */
			}
		}

		if (!has_id) {
			/* Notification (no id) — handle known notifications silently */
			if (strcmp(method, "notifications/initialized") == 0 ||
			    strcmp(method, "notifications/cancelled") == 0) {
				continue;
			}
			/* Unknown notification — ignore */
			continue;
		}

		/* Dispatch by method */
		if (strcmp(method, "initialize") == 0) {
			mcp_write_raw_result(id_str,
				"{\"protocolVersion\":\"2024-11-05\","
				"\"serverInfo\":{\"name\":\"docscan\",\"version\":\"" DOCSCAN_VERSION "\"},"
				"\"capabilities\":{\"tools\":{}}}");
			continue;
		}

		if (strcmp(method, "tools/list") == 0) {
			mcp_write_raw_result(id_str,
				"{\"tools\":" MCP_TOOLS_JSON "}");
			continue;
		}

		if (strcmp(method, "tools/call") == 0) {
			const char* params = mcp_json_get_params(line);
			if (!params) {
				mcp_write_error(id_str, -32600, "Invalid request: missing params");
				continue;
			}

			char tool_name[128];
			if (!mcp_json_get_string(params, "name", tool_name, sizeof(tool_name))) {
				mcp_write_error(id_str, -32602, "Missing required parameter: name");
				continue;
			}

			const char* args = mcp_json_get_arguments(params);
			/* Use empty object if no arguments */
			const char* empty_args = "{}";
			if (!args) args = empty_args;

			if (strcmp(tool_name, "docscan_search") == 0) {
				mcp_handle_search(db, model, args, id_str);
			} else if (strcmp(tool_name, "docscan_status") == 0) {
				mcp_handle_status(db, id_str);
			} else if (strcmp(tool_name, "docscan_read_chunk") == 0) {
				mcp_handle_read_chunk(db, args, id_str);
			} else if (strcmp(tool_name, "docscan_list_docs") == 0) {
				mcp_handle_list_docs(db, id_str);
			} else if (strcmp(tool_name, "docscan_config") == 0) {
				mcp_handle_config(db, args, id_str);
			} else if (strcmp(tool_name, "docscan_index") == 0) {
				mcp_handle_index(db, model, args, id_str);
			} else if (strcmp(tool_name, "docscan_update") == 0) {
				mcp_handle_update(db, model, args, id_str);
			} else {
				char msg[256];
				snprintf(msg, sizeof(msg), "Unknown tool: %s", tool_name);
				mcp_write_error(id_str, -32601, msg);
			}
			continue;
		}

		if (strcmp(method, "ping") == 0) {
			mcp_write_raw_result(id_str, "{}");
			continue;
		}

		/* Unknown method */
		char msg[256];
		snprintf(msg, sizeof(msg), "Method not found: %s", method);
		mcp_write_error(id_str, -32601, msg);
	}

	free(line);
	docscan_close(db);
	free(db_path);
	return 0;
}

/* ── Main: argument parsing ─────────────────────────────────────────── */

int main(int argc, char** argv) {
#ifndef NDEBUG
	fprintf(stderr, "\033[33mDEBUG BUILD\033[0m\n");
#endif

	/* Detect terminal for color defaults */
	if (!isatty(STDOUT_FILENO)) {
		g_use_color = 0;
		g_show_progress = 0;
	}

	/* Parse global flags first (can appear anywhere) */
	const char* command = NULL;
	const char* db_path_arg = NULL;
	const char* model = NULL;
	const char* lang = NULL;
	const char* search_query = NULL;
	const char* target_path = NULL;
	const char* config_key = NULL;
	const char* config_value = NULL;
	const char* search_mode = "hybrid";
	int limit = DEFAULT_LIMIT;

	/* Collect positional args after command */
	int positional_count = 0;
	const char* positionals[16] = {0};

	for (int i = 1; i < argc; i++) {
		/* Global flags */
		if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
			print_help();
			return 0;
		}
		if (strcmp(argv[i], "--about") == 0) {
			print_about();
			return 0;
		}
		if (strcmp(argv[i], "--json") == 0) {
			g_json_output = 1;
			continue;
		}
		if (strcmp(argv[i], "--no-color") == 0) {
			g_use_color = 0;
			continue;
		}
		if (strcmp(argv[i], "--no-progress") == 0) {
			g_show_progress = 0;
			continue;
		}
		if (strcmp(argv[i], "--simple") == 0) {
			g_use_simple = 1;
			g_use_color = 0;
			continue;
		}
		if (strcmp(argv[i], "--exact") == 0) {
			search_mode = "exact";
			continue;
		}
		if (strcmp(argv[i], "--similar") == 0) {
			search_mode = "similar";
			continue;
		}

		/* Named flags with values */
		if (strcmp(argv[i], "--db") == 0 && i + 1 < argc) {
			db_path_arg = argv[++i];
			continue;
		}
		if (strcmp(argv[i], "--model") == 0 && i + 1 < argc) {
			model = argv[++i];
			continue;
		}
		if (strcmp(argv[i], "--limit") == 0 && i + 1 < argc) {
			limit = atoi(argv[++i]);
			if (limit <= 0) limit = DEFAULT_LIMIT;
			continue;
		}
		if (strcmp(argv[i], "--lang") == 0 && i + 1 < argc) {
			lang = argv[++i];
			continue;
		}
		if (strcmp(argv[i], "--embedding-api") == 0 && i + 1 < argc) {
			const char* val = argv[++i];
			if (strcasecmp(val, "openai") == 0) {
				g_api_dialect = API_OPENAI;
			} else if (strcasecmp(val, "ollama") == 0) {
				g_api_dialect = API_OLLAMA;
			} else {
				err_msg("unknown embedding API dialect: %s (expected: ollama or openai)", val);
				return 1;
			}
			continue;
		}
		if (strcmp(argv[i], "--embedding-url") == 0 && i + 1 < argc) {
			snprintf(g_embedding_url, sizeof(g_embedding_url), "%s", argv[++i]);
			continue;
		}
		if (strcmp(argv[i], "--embedding-api-key") == 0 && i + 1 < argc) {
			snprintf(g_api_key, sizeof(g_api_key), "%s", argv[++i]);
			continue;
		}

		/* Command or positional arg */
		if (argv[i][0] == '-') {
			err_msg("unknown flag: %s", argv[i]);
			fprintf(stderr, "Run 'docscan --help' for usage.\n");
			return 1;
		}

		if (!command) {
			command = argv[i];
		} else {
			if (positional_count < 16) {
				positionals[positional_count++] = argv[i];
			}
		}
	}

	/* Apply environment variable defaults */
	if (!model) {
		const char* env_model = getenv("DOCSCAN_MODEL");
		model = (env_model && env_model[0]) ? env_model : DEFAULT_MODEL;
	}
	if (!lang) {
		const char* env_lang = getenv("DOCSCAN_LANG");
		if (env_lang && env_lang[0]) lang = env_lang;
	}

	/* Embedding API env vars (CLI flags override these) */
	{
		const char* env_api = getenv("DOCSCAN_EMBEDDING_API");
		if (env_api && env_api[0] && g_api_dialect == API_OLLAMA) {
			/* Only apply if CLI flag didn't already set it */
			if (strcasecmp(env_api, "openai") == 0) {
				g_api_dialect = API_OPENAI;
			}
		}
		const char* env_url = getenv("DOCSCAN_EMBEDDING_URL");
		if (env_url && env_url[0] &&
		    strcmp(g_embedding_url, "http://127.0.0.1:11434") == 0) {
			/* Only apply if CLI flag didn't already set it */
			snprintf(g_embedding_url, sizeof(g_embedding_url), "%s", env_url);
		}
		const char* env_key = getenv("DOCSCAN_EMBEDDING_API_KEY");
		if (env_key && env_key[0] && !g_api_key[0]) {
			/* Only apply if CLI flag didn't already set it */
			snprintf(g_api_key, sizeof(g_api_key), "%s", env_key);
		}
	}

	/* No command? */
	if (!command) {
		print_help();
		return 0;
	}

	/* Dispatch command */
	if (strcmp(command, "index") == 0) {
		target_path = (positional_count > 0) ? positionals[0] : NULL;
		if (!target_path) {
			err_msg("index requires a path argument");
			fprintf(stderr, "Usage: docscan index <path>\n");
			return 1;
		}
		return cmd_index(db_path_arg, target_path, model, 0);
	}

	if (strcmp(command, "update") == 0) {
		target_path = (positional_count > 0) ? positionals[0] : ".";
		return cmd_index(db_path_arg, target_path, model, 1);
	}

	if (strcmp(command, "search") == 0) {
		search_query = (positional_count > 0) ? positionals[0] : NULL;
		if (!search_query) {
			err_msg("search requires a query string");
			fprintf(stderr, "Usage: docscan search <query>\n");
			return 1;
		}
		return cmd_search(db_path_arg, search_query, search_mode, limit, model);
	}

	if (strcmp(command, "status") == 0) {
		return cmd_status(db_path_arg);
	}

	if (strcmp(command, "config") == 0) {
		config_key = (positional_count > 0) ? positionals[0] : NULL;
		config_value = (positional_count > 1) ? positionals[1] : NULL;
		return cmd_config(db_path_arg, config_key, config_value);
	}

	if (strcmp(command, "mcp-serve") == 0) {
		return cmd_mcp_serve(db_path_arg, model);
	}

	/* Unknown command */
	err_msg("unknown command: %s", command);
	fprintf(stderr, "Run 'docscan --help' for usage.\n");
	return 1;
}
