/*
 * docscan CLI — C entry point that dogfoods the C FFI.
 * All I/O lives here; the Zig core is pure computation.
 *
 * This file is intentionally monolithic: it is the I/O orchestration layer
 * that handles argument parsing, directory walking, HTTP (Ollama), progress
 * reporting, and output formatting.
 */

#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <errno.h>
#include <time.h>
#include <ctype.h>

#ifdef _WIN32
  #include <winsock2.h>
  #include <ws2tcpip.h>
  #include <windows.h>
  #include <io.h>
  #include <direct.h>
  #pragma comment(lib, "ws2_32.lib")
  #include <sys/stat.h>
  #include <sys/types.h>
  typedef int socklen_t;
  #ifndef __MINGW32__
  typedef int ssize_t;
  #endif
  #define close(s) closesocket(s)
  #define isatty(fd) _isatty(fd)
  #ifndef STDOUT_FILENO
  #define STDOUT_FILENO 1
  #endif
  #ifndef STDERR_FILENO
  #define STDERR_FILENO 2
  #endif
  #define strcasecmp  _stricmp
  #define strncasecmp _strnicmp
  #define getcwd      _getcwd
  #define mkdir(p, m) _mkdir(p)
  #ifndef S_ISDIR
  #define S_ISDIR(m)  (((m) & S_IFMT) == S_IFDIR)
  #endif
  #ifndef S_ISREG
  #define S_ISREG(m)  (((m) & S_IFMT) == S_IFREG)
  #endif
  static int g_wsa_init = 0;
  static void ensure_wsa(void) {
    if (!g_wsa_init) { WSADATA w; WSAStartup(MAKEWORD(2,2), &w); g_wsa_init = 1; }
  }
#else
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
  #include <strings.h>
  #include <pthread.h>
  static void ensure_wsa(void) {}
#endif

#include <stdatomic.h>
#include "docscan_core.h"

/* Cross-platform absolute path check */
static int is_absolute_path(const char* p) {
#ifdef _WIN32
	/* C:\ or C:/ or \\ UNC */
	if (p[0] && p[1] == ':' && (p[2] == '\\' || p[2] == '/')) return 1;
	if (p[0] == '\\' && p[1] == '\\') return 1;
	return 0;
#else
	return (p[0] == '/');
#endif
}

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
#define HTTP_BUF_SIZE         (16 * 1024 * 1024)  /* 16 MiB response buffer */
#define MAX_CHUNKS_PER_FILE   4096
#define SHA256_DIGEST_LEN     32
#define SHA256_HEX_LEN        64
#define DEFAULT_THREADS       4
#define MAX_THREADS           32
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
static int g_num_threads = DEFAULT_THREADS;
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
	if (strcasecmp(dot, "txt") == 0 || strcasecmp(dot, "text") == 0) return "txt";
	if (strcasecmp(dot, "docx") == 0) return "docx";
	if (strcasecmp(dot, "pdf") == 0) return "pdf";
	if (strcasecmp(dot, "doc") == 0) return "doc";
	if (strcasecmp(dot, "rtf") == 0) return "rtf";
	if (strcasecmp(dot, "epub") == 0) return "epub";
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
	ensure_wsa();
	int sockfd = socket(AF_INET, SOCK_STREAM, 0);
	if (sockfd < 0) return NULL;

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons((uint16_t)port);

	if (inet_pton(AF_INET, host, &addr.sin_addr) <= 0) {
		/* DNS resolution via getaddrinfo (portable across musl/glibc/Windows) */
		struct addrinfo hints, *res;
		memset(&hints, 0, sizeof(hints));
		hints.ai_family = AF_INET;
		hints.ai_socktype = SOCK_STREAM;
		if (getaddrinfo(host, NULL, &hints, &res) != 0 || !res) { close(sockfd); return NULL; }
		memcpy(&addr.sin_addr, &((struct sockaddr_in*)res->ai_addr)->sin_addr, sizeof(addr.sin_addr));
		freeaddrinfo(res);
	}

	/* Set a connect timeout via non-blocking + select */
	{
#ifdef _WIN32
		unsigned long nonblock = 1;
		ioctlsocket(sockfd, FIONBIO, &nonblock);
#else
		int flags = fcntl(sockfd, F_GETFL, 0);
		fcntl(sockfd, F_SETFL, flags | O_NONBLOCK);
#endif

		int rc = connect(sockfd, (struct sockaddr*)&addr, sizeof(addr));
#ifdef _WIN32
		if (rc < 0 && WSAGetLastError() != WSAEWOULDBLOCK) {
#else
		if (rc < 0 && errno != EINPROGRESS) {
#endif
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
#ifdef _WIN32
		getsockopt(sockfd, SOL_SOCKET, SO_ERROR, (char*)&err, &elen);
#else
		getsockopt(sockfd, SOL_SOCKET, SO_ERROR, &err, &elen);
#endif
		if (err != 0) {
			close(sockfd);
			return NULL;
		}

		/* Back to blocking for read/write */
#ifdef _WIN32
		nonblock = 0;
		ioctlsocket(sockfd, FIONBIO, &nonblock);
#else
		fcntl(sockfd, F_SETFL, flags);
#endif
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
#ifdef _WIN32
	if (send(sockfd, header, hlen, 0) != hlen) { close(sockfd); return NULL; }
#else
	if (write(sockfd, header, (size_t)hlen) != hlen) { close(sockfd); return NULL; }
#endif
	size_t sent = 0;
	while (sent < body_len) {
#ifdef _WIN32
		ssize_t n = send(sockfd, body + sent, (int)(body_len - sent), 0);
#else
		ssize_t n = write(sockfd, body + sent, body_len - sent);
#endif
		if (n <= 0) { close(sockfd); return NULL; }
		sent += (size_t)n;
	}

	/* Read response */
	char* resp = malloc(HTTP_BUF_SIZE);
	if (!resp) { close(sockfd); return NULL; }
	size_t total = 0;
	for (;;) {
#ifdef _WIN32
		ssize_t n = recv(sockfd, resp + total, (int)(HTTP_BUF_SIZE - total - 1), 0);
#else
		ssize_t n = read(sockfd, resp + total, HTTP_BUF_SIZE - total - 1);
#endif
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
		if (!text) goto cleanup_on_error;
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
				if (len + 1 >= cap) {
					cap *= 2;
					char* nt = realloc(text, cap);
					if (!nt) { free(text); goto cleanup_on_error; }
					text = nt;
				}
				text[len++] = ch;
			} else {
				if (len + 1 >= cap) {
					cap *= 2;
					char* nt = realloc(text, cap);
					if (!nt) { free(text); goto cleanup_on_error; }
					text = nt;
				}
				text[len++] = *p;
			}
			p++;
		}
		text[len] = '\0';

		if (*out_count >= capacity) {
			capacity *= 2;
			char** nt = realloc(texts, sizeof(char*) * (size_t)capacity);
			if (!nt) { free(text); goto cleanup_on_error; }
			texts = nt;
		}
		texts[(*out_count)++] = text;
	}

	return texts;

cleanup_on_error:
	for (int i = 0; i < *out_count; i++) free(texts[i]);
	free(texts);
	*out_count = 0;
	return NULL;
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
		/* Escape the text for JSON, handling invalid UTF-8 gracefully */
		for (const char* s = texts[i]; *s; s++) {
			if ((size_t)off >= body_cap - 16) {
				body_cap *= 2;
				char* new_body = realloc(body, body_cap);
				if (!new_body) { free(body); return NULL; }
				body = new_body;
			}
			unsigned char uc = (unsigned char)*s;
			switch (*s) {
				case '"':  body[off++] = '\\'; body[off++] = '"'; break;
				case '\\': body[off++] = '\\'; body[off++] = '\\'; break;
				case '\n': body[off++] = '\\'; body[off++] = 'n'; break;
				case '\r': body[off++] = '\\'; body[off++] = 'r'; break;
				case '\t': body[off++] = '\\'; body[off++] = 't'; break;
				default:
					if (uc < 0x20) {
						/* Control character */
						off += snprintf(body + off, body_cap - (size_t)off,
						                "\\u%04x", uc);
					} else if (uc >= 0x80) {
						/* High byte — validate UTF-8 sequence */
						int seq_len = 0;
						if ((uc & 0xE0) == 0xC0) seq_len = 2;
						else if ((uc & 0xF0) == 0xE0) seq_len = 3;
						else if ((uc & 0xF8) == 0xF0) seq_len = 4;

						int valid = (seq_len >= 2);
						if (valid) {
							for (int k = 1; k < seq_len; k++) {
								if (((unsigned char)s[k] & 0xC0) != 0x80) {
									valid = 0;
									break;
								}
							}
						}
						if (valid) {
							/* Valid UTF-8 multi-byte — copy through */
							if ((size_t)off + (size_t)seq_len >= body_cap - 4) {
								body_cap *= 2;
								char* new_body = realloc(body, body_cap);
								if (!new_body) { free(body); return NULL; }
								body = new_body;
							}
							for (int k = 0; k < seq_len; k++)
								body[off++] = s[k];
							s += seq_len - 1; /* -1 because loop increments */
						} else {
							/* Invalid/lone high byte — escape as \uXXXX */
							off += snprintf(body + off, body_cap - (size_t)off,
							                "\\u%04x", uc);
						}
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
	int max_dim = DEFAULT_EMBEDDING_DIM > 1024 ? DEFAULT_EMBEDDING_DIM : 1024;
	int max_floats = num_texts * max_dim * 2; /* generous */
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
	ensure_wsa();
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
		struct addrinfo hints, *res;
		memset(&hints, 0, sizeof(hints));
		hints.ai_family = AF_INET;
		hints.ai_socktype = SOCK_STREAM;
		if (getaddrinfo(host, NULL, &hints, &res) != 0 || !res) { close(sockfd); return 0; }
		memcpy(&addr.sin_addr, &((struct sockaddr_in*)res->ai_addr)->sin_addr, sizeof(addr.sin_addr));
		freeaddrinfo(res);
	}

	/* Non-blocking connect with short timeout */
#ifdef _WIN32
	unsigned long nonblock = 1;
	ioctlsocket(sockfd, FIONBIO, &nonblock);
#else
	int flags = fcntl(sockfd, F_GETFL, 0);
	fcntl(sockfd, F_SETFL, flags | O_NONBLOCK);
#endif

	int rc = connect(sockfd, (struct sockaddr*)&addr, sizeof(addr));
	if (rc == 0) { close(sockfd); return 1; }
#ifdef _WIN32
	if (WSAGetLastError() != WSAEWOULDBLOCK) { close(sockfd); return 0; }
#else
	if (errno != EINPROGRESS) { close(sockfd); return 0; }
#endif

	fd_set wfds;
	FD_ZERO(&wfds);
	FD_SET(sockfd, &wfds);
	struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
	rc = select(sockfd + 1, NULL, &wfds, NULL, &tv);
	if (rc <= 0) { close(sockfd); return 0; }

	int err = 0;
	socklen_t elen = sizeof(err);
#ifdef _WIN32
	getsockopt(sockfd, SOL_SOCKET, SO_ERROR, (char*)&err, &elen);
#else
	getsockopt(sockfd, SOL_SOCKET, SO_ERROR, &err, &elen);
#endif
	close(sockfd);
	return (err == 0);
}

/* ── Directory walking ──────────────────────────────────────────────── */

typedef struct {
	char**  paths;
	int     count;
	int     capacity;
} file_list;

static int file_list_cmp(const void* a, const void* b) {
	return strcmp(*(const char**)a, *(const char**)b);
}

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
#ifdef _WIN32
	char search_path[MAX_PATH_LEN];
	snprintf(search_path, sizeof(search_path), "%s\\*", dir_path);

	WIN32_FIND_DATAA fdata;
	HANDLE hFind = FindFirstFileA(search_path, &fdata);
	if (hFind == INVALID_HANDLE_VALUE) return;

	do {
		const char* name = fdata.cFileName;
		/* Skip hidden files and . / .. */
		if (name[0] == '.') continue;

		char full_path[MAX_PATH_LEN];
		snprintf(full_path, sizeof(full_path), "%s\\%s", dir_path, name);

		if (fdata.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
			/* Skip common noise directories */
			if (strcmp(name, "node_modules") == 0) continue;
			if (strcmp(name, "__pycache__") == 0) continue;
			if (strcmp(name, ".git") == 0) continue;
			if (strcmp(name, ".jj") == 0) continue;
			if (strcmp(name, "zig-cache") == 0) continue;
			if (strcmp(name, "zig-out") == 0) continue;
			walk_dir(full_path, fl);
		} else {
			if (format_for_ext(full_path) != NULL) {
				file_list_add(fl, full_path);
			}
		}
	} while (FindNextFileA(hFind, &fdata));
	FindClose(hFind);
#else
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
#endif
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

	/* Clear to end of line (ANSI escape) to remove previous longer text */
	fprintf(stderr, "\033[K");
	fflush(stderr);
}

static void progress_finish(progress_t* p) {
	if (!g_show_progress || !p->is_tty) return;
	fprintf(stderr, "\r\033[K");
	/* Clear the line */
	for (int i = 0; i < 100; i++) fputc(' ', stderr);
	fprintf(stderr, "\r");
	fflush(stderr);
}

/* ── Database path resolution ───────────────────────────────────────── */

/* Default config.ini template — also used in the INI config section below */
static const char* DEFAULT_CONFIG_TEMPLATE_EARLY =
	"# docscan project configuration\n"
	"# Edit values below. Changes take effect on next command.\n"
	"# See: docscan --help\n"
	"\n"
	"[embedding]\n"
	"# Embedding provider: ollama (default) or openai (for oMLX, LiteLLM, vLLM)\n"
	"#api = ollama\n"
	"#url = http://127.0.0.1:11434\n"
	"#model = nomic-embed-text\n"
	"#api_key =\n"
	"#dim = 768\n"
	"\n"
	"[search]\n"
	"#limit = 10\n"
	"#weight_vector = 0.7\n"
	"#weight_lexical = 0.3\n"
	"\n"
	"[index]\n"
	"#max_chunk_tokens = 1500\n";

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
		/* Find last path separator */
		const char* slash = strrchr(target_path, '/');
#ifdef _WIN32
		const char* bslash = strrchr(target_path, '\\');
		if (!slash || (bslash && bslash > slash)) slash = bslash;
#endif
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

	/* Create default config.ini if it doesn't exist */
	{
		char ini_path[MAX_PATH_LEN];
		snprintf(ini_path, sizeof(ini_path), "%s/config.ini", docscan_dir);
		struct stat ini_st;
		if (stat(ini_path, &ini_st) != 0) {
			/* File doesn't exist — create with default template */
			FILE* ini_f = fopen(ini_path, "w");
			if (ini_f) {
				fprintf(ini_f, "%s", DEFAULT_CONFIG_TEMPLATE_EARLY);
				fclose(ini_f);
			}
		}
	}

	char* db_path = malloc(MAX_PATH_LEN);
	snprintf(db_path, MAX_PATH_LEN, "%s/%s", docscan_dir, DEFAULT_DB_FILENAME);
	return db_path;
}

/* ── INI config file (.docscan/config.ini) ─────────────────────────── */

/*
 * Persistent project-level settings stored in .docscan/config.ini.
 * Override precedence (highest to lowest):
 *   1. CLI flags
 *   2. Environment variables
 *   3. .docscan/config.ini
 *   4. Hardcoded defaults
 */

typedef struct {
	/* [embedding] */
	char embedding_api[64];
	char embedding_url[512];
	char embedding_model[256];
	char embedding_api_key[512];
	int  embedding_dim;

	/* [search] */
	int   search_limit;
	float weight_vector;
	float weight_lexical;

	/* [index] */
	int max_chunk_tokens;
} DocscanConfig;

/* Parallel struct tracking where each config value came from */
typedef struct {
	char api[128];
	char url[128];
	char model[128];
	char api_key[128];
	char dim[128];
	char limit[128];
	char weight_vector[128];
	char weight_lexical[128];
	char max_chunk_tokens[128];
} ConfigSources;

static void config_sources_defaults(ConfigSources* src) {
	snprintf(src->api, sizeof(src->api), "default");
	snprintf(src->url, sizeof(src->url), "default");
	snprintf(src->model, sizeof(src->model), "default");
	snprintf(src->api_key, sizeof(src->api_key), "default");
	snprintf(src->dim, sizeof(src->dim), "default");
	snprintf(src->limit, sizeof(src->limit), "default");
	snprintf(src->weight_vector, sizeof(src->weight_vector), "default");
	snprintf(src->weight_lexical, sizeof(src->weight_lexical), "default");
	snprintf(src->max_chunk_tokens, sizeof(src->max_chunk_tokens), "default");
}

/* Initialize config with defaults */
static void config_defaults(DocscanConfig* cfg) {
	snprintf(cfg->embedding_api, sizeof(cfg->embedding_api), "ollama");
	snprintf(cfg->embedding_url, sizeof(cfg->embedding_url), "http://127.0.0.1:11434");
	snprintf(cfg->embedding_model, sizeof(cfg->embedding_model), "%s", DEFAULT_MODEL);
	cfg->embedding_api_key[0] = '\0';
	cfg->embedding_dim = DEFAULT_EMBEDDING_DIM;
	cfg->search_limit = DEFAULT_LIMIT;
	cfg->weight_vector = 0.7f;
	cfg->weight_lexical = 0.3f;
	cfg->max_chunk_tokens = DEFAULT_MAX_TOKENS;
}

/* Trim leading/trailing whitespace in-place, return pointer into buf */
static char* str_trim(char* s) {
	while (*s && (*s == ' ' || *s == '\t')) s++;
	if (!*s) return s;
	char* end = s + strlen(s) - 1;
	while (end > s && (*end == ' ' || *end == '\t' || *end == '\r' || *end == '\n'))
		*end-- = '\0';
	return s;
}

/* Derive config.ini path from a .docscan directory path.
 * If db_path ends with /index.db, strip that to get the dir.
 * Returns malloc'd string. Caller frees. */
static char* config_ini_path_from_db(const char* db_path) {
	char dir[MAX_PATH_LEN];

	/* If db_path ends with "/index.db", use the directory part */
	const char* suffix = "/index.db";
	size_t db_len = strlen(db_path);
	size_t suf_len = strlen(suffix);
	if (db_len > suf_len && strcmp(db_path + db_len - suf_len, suffix) == 0) {
		size_t dlen = db_len - suf_len;
		if (dlen >= sizeof(dir)) dlen = sizeof(dir) - 1;
		memcpy(dir, db_path, dlen);
		dir[dlen] = '\0';
	} else {
		/* Fallback: use db_path's parent directory */
		const char* slash = strrchr(db_path, '/');
#ifdef _WIN32
		const char* bslash = strrchr(db_path, '\\');
		if (!slash || (bslash && bslash > slash)) slash = bslash;
#endif
		if (slash) {
			size_t dlen = (size_t)(slash - db_path);
			if (dlen >= sizeof(dir)) dlen = sizeof(dir) - 1;
			memcpy(dir, db_path, dlen);
			dir[dlen] = '\0';
		} else {
			snprintf(dir, sizeof(dir), ".");
		}
	}

	char* path = malloc(MAX_PATH_LEN);
	if (!path) return NULL;
	snprintf(path, MAX_PATH_LEN, "%s/config.ini", dir);
	return path;
}

/* Load config from .ini file. Returns 0 on success, -1 if file not found. */
static int load_config(const char* config_path, DocscanConfig* cfg) {
	FILE* f = fopen(config_path, "r");
	if (!f) return -1;

	char section[64] = "";
	char line[1024];

	while (fgets(line, sizeof(line), f)) {
		char* s = str_trim(line);
		/* Skip empty lines and comments */
		if (!*s || *s == '#' || *s == ';') continue;

		/* Section header */
		if (*s == '[') {
			char* end = strchr(s, ']');
			if (end) {
				*end = '\0';
				snprintf(section, sizeof(section), "%s", s + 1);
			}
			continue;
		}

		/* key = value */
		char* eq = strchr(s, '=');
		if (!eq) continue;

		*eq = '\0';
		char* key = str_trim(s);
		char* val = str_trim(eq + 1);

		/* Strip surrounding quotes if present */
		size_t vlen = strlen(val);
		if (vlen >= 2 && ((val[0] == '"' && val[vlen-1] == '"') ||
		                   (val[0] == '\'' && val[vlen-1] == '\''))) {
			val[vlen-1] = '\0';
			val++;
		}

		/* Map section.key -> config field */
		if (strcmp(section, "embedding") == 0) {
			if (strcmp(key, "api") == 0) {
				snprintf(cfg->embedding_api, sizeof(cfg->embedding_api), "%s", val);
			} else if (strcmp(key, "url") == 0) {
				snprintf(cfg->embedding_url, sizeof(cfg->embedding_url), "%s", val);
			} else if (strcmp(key, "model") == 0) {
				snprintf(cfg->embedding_model, sizeof(cfg->embedding_model), "%s", val);
			} else if (strcmp(key, "api_key") == 0) {
				snprintf(cfg->embedding_api_key, sizeof(cfg->embedding_api_key), "%s", val);
			} else if (strcmp(key, "dim") == 0) {
				int d = atoi(val);
				if (d > 0) cfg->embedding_dim = d;
			}
			/* Unknown keys: silently ignore */
		} else if (strcmp(section, "search") == 0) {
			if (strcmp(key, "limit") == 0) {
				int v = atoi(val);
				if (v > 0) cfg->search_limit = v;
			} else if (strcmp(key, "weight_vector") == 0) {
				float v = strtof(val, NULL);
				if (v >= 0.0f && v <= 1.0f) cfg->weight_vector = v;
			} else if (strcmp(key, "weight_lexical") == 0) {
				float v = strtof(val, NULL);
				if (v >= 0.0f && v <= 1.0f) cfg->weight_lexical = v;
			}
		} else if (strcmp(section, "index") == 0) {
			if (strcmp(key, "max_chunk_tokens") == 0) {
				int v = atoi(val);
				if (v > 0) cfg->max_chunk_tokens = v;
			}
		}
		/* Unknown sections: silently ignore */
	}

	fclose(f);
	return 0;
}

/* Load config from INI file, tracking which fields were set and their source.
 * source_label should be e.g. "global: ~/.config/docscan/config.ini"
 * or "project: /path/.docscan/config.ini". */
static int load_config_tracked(const char* config_path, DocscanConfig* cfg,
                               ConfigSources* src, const char* source_label) {
	DocscanConfig before = *cfg;
	int rc = load_config(config_path, cfg);
	if (rc != 0) return rc;

	/* Compare each field — if it changed, record the source */
	if (strcmp(cfg->embedding_api, before.embedding_api) != 0)
		snprintf(src->api, sizeof(src->api), "%s", source_label);
	if (strcmp(cfg->embedding_url, before.embedding_url) != 0)
		snprintf(src->url, sizeof(src->url), "%s", source_label);
	if (strcmp(cfg->embedding_model, before.embedding_model) != 0)
		snprintf(src->model, sizeof(src->model), "%s", source_label);
	if (strcmp(cfg->embedding_api_key, before.embedding_api_key) != 0)
		snprintf(src->api_key, sizeof(src->api_key), "%s", source_label);
	if (cfg->embedding_dim != before.embedding_dim)
		snprintf(src->dim, sizeof(src->dim), "%s", source_label);
	if (cfg->search_limit != before.search_limit)
		snprintf(src->limit, sizeof(src->limit), "%s", source_label);
	if (cfg->weight_vector != before.weight_vector)
		snprintf(src->weight_vector, sizeof(src->weight_vector), "%s", source_label);
	if (cfg->weight_lexical != before.weight_lexical)
		snprintf(src->weight_lexical, sizeof(src->weight_lexical), "%s", source_label);
	if (cfg->max_chunk_tokens != before.max_chunk_tokens)
		snprintf(src->max_chunk_tokens, sizeof(src->max_chunk_tokens), "%s", source_label);
	return 0;
}

/* Save config to .ini file. Writes all non-default values as active lines,
 * commented defaults for unset values. */
static int save_config(const char* config_path, const DocscanConfig* cfg) {
	FILE* f = fopen(config_path, "w");
	if (!f) return -1;

	DocscanConfig defaults;
	config_defaults(&defaults);

	fprintf(f, "# docscan project configuration\n");
	fprintf(f, "# Edit values below. Changes take effect on next command.\n");
	fprintf(f, "# See: docscan --help\n");
	fprintf(f, "\n");

	fprintf(f, "[embedding]\n");
	fprintf(f, "# Embedding provider: ollama (default) or openai (for oMLX, LiteLLM, vLLM)\n");
	if (strcmp(cfg->embedding_api, defaults.embedding_api) != 0)
		fprintf(f, "api = %s\n", cfg->embedding_api);
	else
		fprintf(f, "#api = ollama\n");

	if (strcmp(cfg->embedding_url, defaults.embedding_url) != 0)
		fprintf(f, "url = %s\n", cfg->embedding_url);
	else
		fprintf(f, "#url = http://127.0.0.1:11434\n");

	if (strcmp(cfg->embedding_model, defaults.embedding_model) != 0)
		fprintf(f, "model = %s\n", cfg->embedding_model);
	else
		fprintf(f, "#model = nomic-embed-text\n");

	if (cfg->embedding_api_key[0])
		fprintf(f, "api_key = %s\n", cfg->embedding_api_key);
	else
		fprintf(f, "#api_key =\n");

	if (cfg->embedding_dim != defaults.embedding_dim)
		fprintf(f, "dim = %d\n", cfg->embedding_dim);
	else
		fprintf(f, "#dim = 768\n");

	fprintf(f, "\n");
	fprintf(f, "[search]\n");

	if (cfg->search_limit != defaults.search_limit)
		fprintf(f, "limit = %d\n", cfg->search_limit);
	else
		fprintf(f, "#limit = 10\n");

	if (cfg->weight_vector != defaults.weight_vector)
		fprintf(f, "weight_vector = %.1f\n", (double)cfg->weight_vector);
	else
		fprintf(f, "#weight_vector = 0.7\n");

	if (cfg->weight_lexical != defaults.weight_lexical)
		fprintf(f, "weight_lexical = %.1f\n", (double)cfg->weight_lexical);
	else
		fprintf(f, "#weight_lexical = 0.3\n");

	fprintf(f, "\n");
	fprintf(f, "[index]\n");

	if (cfg->max_chunk_tokens != defaults.max_chunk_tokens)
		fprintf(f, "max_chunk_tokens = %d\n", cfg->max_chunk_tokens);
	else
		fprintf(f, "#max_chunk_tokens = 1500\n");

	fclose(f);
	return 0;
}

/* Set a single config key using dot notation (e.g., "embedding.api").
 * Loads the current config, modifies, and saves. Returns 0 on success. */
static int config_ini_set(const char* config_path, const char* dotkey, const char* value) {
	DocscanConfig cfg;
	config_defaults(&cfg);
	load_config(config_path, &cfg); /* OK if file doesn't exist yet */

	/* Parse section.key */
	char section[64] = "";
	char key[64] = "";
	const char* dot = strchr(dotkey, '.');
	if (dot) {
		size_t slen = (size_t)(dot - dotkey);
		if (slen >= sizeof(section)) slen = sizeof(section) - 1;
		memcpy(section, dotkey, slen);
		section[slen] = '\0';
		snprintf(key, sizeof(key), "%s", dot + 1);
	} else {
		/* No dot: treat as a legacy DB-config key (model, etc.) */
		/* Map legacy keys to their INI equivalents */
		if (strcmp(dotkey, "model") == 0) {
			snprintf(section, sizeof(section), "embedding");
			snprintf(key, sizeof(key), "model");
		} else if (strcmp(dotkey, "embedding_dim") == 0) {
			snprintf(section, sizeof(section), "embedding");
			snprintf(key, sizeof(key), "dim");
		} else if (strcmp(dotkey, "max_chunk_tokens") == 0) {
			snprintf(section, sizeof(section), "index");
			snprintf(key, sizeof(key), "max_chunk_tokens");
		} else {
			return -1; /* unknown key */
		}
	}

	/* Apply to the config struct */
	if (strcmp(section, "embedding") == 0) {
		if (strcmp(key, "api") == 0) {
			snprintf(cfg.embedding_api, sizeof(cfg.embedding_api), "%s", value);
		} else if (strcmp(key, "url") == 0) {
			snprintf(cfg.embedding_url, sizeof(cfg.embedding_url), "%s", value);
		} else if (strcmp(key, "model") == 0) {
			snprintf(cfg.embedding_model, sizeof(cfg.embedding_model), "%s", value);
		} else if (strcmp(key, "api_key") == 0) {
			snprintf(cfg.embedding_api_key, sizeof(cfg.embedding_api_key), "%s", value);
		} else if (strcmp(key, "dim") == 0) {
			int d = atoi(value);
			if (d > 0) cfg.embedding_dim = d;
		} else {
			return -1;
		}
	} else if (strcmp(section, "search") == 0) {
		if (strcmp(key, "limit") == 0) {
			int v = atoi(value);
			if (v > 0) cfg.search_limit = v;
		} else if (strcmp(key, "weight_vector") == 0) {
			cfg.weight_vector = strtof(value, NULL);
		} else if (strcmp(key, "weight_lexical") == 0) {
			cfg.weight_lexical = strtof(value, NULL);
		} else {
			return -1;
		}
	} else if (strcmp(section, "index") == 0) {
		if (strcmp(key, "max_chunk_tokens") == 0) {
			int v = atoi(value);
			if (v > 0) cfg.max_chunk_tokens = v;
		} else {
			return -1;
		}
	} else {
		return -1;
	}

	return save_config(config_path, &cfg);
}

/* Get a single config value by dot notation. Returns malloc'd string or NULL. */
static char* config_ini_get(const char* config_path, const char* dotkey) {
	DocscanConfig cfg;
	config_defaults(&cfg);
	if (load_config(config_path, &cfg) != 0) return NULL;

	/* Parse section.key */
	char section[64] = "";
	char key[64] = "";
	const char* dot = strchr(dotkey, '.');
	if (dot) {
		size_t slen = (size_t)(dot - dotkey);
		if (slen >= sizeof(section)) slen = sizeof(section) - 1;
		memcpy(section, dotkey, slen);
		section[slen] = '\0';
		snprintf(key, sizeof(key), "%s", dot + 1);
	} else {
		/* Legacy key mapping */
		if (strcmp(dotkey, "model") == 0) {
			snprintf(section, sizeof(section), "embedding");
			snprintf(key, sizeof(key), "model");
		} else if (strcmp(dotkey, "embedding_dim") == 0) {
			snprintf(section, sizeof(section), "embedding");
			snprintf(key, sizeof(key), "dim");
		} else if (strcmp(dotkey, "max_chunk_tokens") == 0) {
			snprintf(section, sizeof(section), "index");
			snprintf(key, sizeof(key), "max_chunk_tokens");
		} else {
			return NULL;
		}
	}

	char buf[512];
	if (strcmp(section, "embedding") == 0) {
		if (strcmp(key, "api") == 0) snprintf(buf, sizeof(buf), "%s", cfg.embedding_api);
		else if (strcmp(key, "url") == 0) snprintf(buf, sizeof(buf), "%s", cfg.embedding_url);
		else if (strcmp(key, "model") == 0) snprintf(buf, sizeof(buf), "%s", cfg.embedding_model);
		else if (strcmp(key, "api_key") == 0) snprintf(buf, sizeof(buf), "%s", cfg.embedding_api_key);
		else if (strcmp(key, "dim") == 0) snprintf(buf, sizeof(buf), "%d", cfg.embedding_dim);
		else return NULL;
	} else if (strcmp(section, "search") == 0) {
		if (strcmp(key, "limit") == 0) snprintf(buf, sizeof(buf), "%d", cfg.search_limit);
		else if (strcmp(key, "weight_vector") == 0) snprintf(buf, sizeof(buf), "%.1f", (double)cfg.weight_vector);
		else if (strcmp(key, "weight_lexical") == 0) snprintf(buf, sizeof(buf), "%.1f", (double)cfg.weight_lexical);
		else return NULL;
	} else if (strcmp(section, "index") == 0) {
		if (strcmp(key, "max_chunk_tokens") == 0) snprintf(buf, sizeof(buf), "%d", cfg.max_chunk_tokens);
		else return NULL;
	} else {
		return NULL;
	}

	return strdup(buf);
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
		"  config debug          Show effective config with sources\n"
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
		"  --threads N           Number of indexing threads (default: 4)\n"
		"\n"
		"%sENVIRONMENT%s\n"
		"  DOCSCAN_MODEL              Default embedding model\n"
		"  DOCSCAN_DB                 Default database path\n"
		"  DOCSCAN_EMBEDDING_API      Embedding API dialect: ollama or openai\n"
		"  DOCSCAN_EMBEDDING_URL      Embedding server URL\n"
		"  DOCSCAN_EMBEDDING_API_KEY  API key for OpenAI-compatible servers\n"
		"  DOCSCAN_LANG               Language override\n"
		"  DOCSCAN_THREADS            Number of indexing threads (default: 4)\n"		"\n"
		"%sCONFIG FILE%s\n"
		"  Settings are saved in .docscan/config.ini (created on first index).\n"
		"  Use dot notation: docscan config embedding.api openai\n"
		"  Override precedence: CLI flags > env vars > config.ini > defaults\n"
		"\n"
		"%sEXAMPLES%s\n"
		"  docscan index ~/Documents\n"
		"  docscan search \"contract renewal terms\"\n"
		"  docscan search --exact \"indemnification clause\"\n"
		"  docscan update ~/Documents\n"
		"  docscan status\n"
		"  docscan config embedding.model bge-m3\n"
		"  docscan config embedding.api openai\n",
		color(ANSI_BOLD), color(ANSI_RESET),
		color(ANSI_BOLD), color(ANSI_RESET),
		color(ANSI_BOLD), color(ANSI_RESET),
		color(ANSI_BOLD), color(ANSI_RESET),
		color(ANSI_BOLD), color(ANSI_RESET),
		color(ANSI_BOLD), color(ANSI_RESET),
		color(ANSI_BOLD), color(ANSI_RESET)
	);
}

static void print_about(void) {
	const char* os = "unknown";
	const char* arch = "unknown";
#ifdef _WIN32
	os = "windows";
	#if defined(_M_AMD64) || defined(__x86_64__)
	arch = "x86_64";
	#elif defined(_M_ARM64) || defined(__aarch64__)
	arch = "aarch64";
	#endif
#else
	struct utsname uname_buf;
	if (uname(&uname_buf) == 0) {
		os = uname_buf.sysname;
		arch = uname_buf.machine;
	}
#endif
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

	/* Derive config.ini path from the DB path */
	char* cfg_path = config_ini_path_from_db(db_path);
	if (!cfg_path) {
		err_msg("could not determine config path");
		free(db_path);
		return 1;
	}

	if (key != NULL && strcmp(key, "debug") == 0) {
		/* ── config debug: show effective values with sources ── */
		DocscanConfig cfg;
		config_defaults(&cfg);
		ConfigSources src;
		config_sources_defaults(&src);

		/* Layer 1: global config */
		char global_cfg[MAX_PATH_LEN];
		const char* xdg = getenv("XDG_CONFIG_HOME");
		if (xdg && xdg[0]) {
			snprintf(global_cfg, sizeof(global_cfg), "%s/docscan/config.ini", xdg);
		} else {
			const char* home = getenv("HOME");
			if (home)
				snprintf(global_cfg, sizeof(global_cfg), "%s/.config/docscan/config.ini", home);
			else
				global_cfg[0] = '\0';
		}
		if (global_cfg[0]) {
			char global_label[MAX_PATH_LEN];
			snprintf(global_label, sizeof(global_label), "global: %s", global_cfg);
			load_config_tracked(global_cfg, &cfg, &src, global_label);
		}

		/* Layer 2: project config */
		{
			char project_label[MAX_PATH_LEN];
			snprintf(project_label, sizeof(project_label), "project: %s", cfg_path);
			load_config_tracked(cfg_path, &cfg, &src, project_label);
		}

		/* Layer 3: environment variables */
		{
			const char* env_api = getenv("DOCSCAN_EMBEDDING_API");
			if (env_api && env_api[0]) {
				snprintf(cfg.embedding_api, sizeof(cfg.embedding_api), "%s", env_api);
				snprintf(src.api, sizeof(src.api), "env: DOCSCAN_EMBEDDING_API");
			}
			const char* env_url = getenv("DOCSCAN_EMBEDDING_URL");
			if (env_url && env_url[0]) {
				snprintf(cfg.embedding_url, sizeof(cfg.embedding_url), "%s", env_url);
				snprintf(src.url, sizeof(src.url), "env: DOCSCAN_EMBEDDING_URL");
			}
			const char* env_model = getenv("DOCSCAN_MODEL");
			if (env_model && env_model[0]) {
				snprintf(cfg.embedding_model, sizeof(cfg.embedding_model), "%s", env_model);
				snprintf(src.model, sizeof(src.model), "env: DOCSCAN_MODEL");
			}
			const char* env_key = getenv("DOCSCAN_EMBEDDING_API_KEY");
			if (env_key && env_key[0]) {
				snprintf(cfg.embedding_api_key, sizeof(cfg.embedding_api_key), "%s", env_key);
				snprintf(src.api_key, sizeof(src.api_key), "env: DOCSCAN_EMBEDDING_API_KEY");
			}
		}

		/* Note: CLI flag sources are not tracked here because cmd_config
		 * doesn't receive CLI flags — those override the globals before
		 * dispatch. In the future, a more comprehensive approach could
		 * thread cli_set_* flags through, but for now this covers the
		 * config file and env var layers. */

		/* Mask api_key: show first 8 chars + *** */
		char masked_key[520];
		if (cfg.embedding_api_key[0]) {
			size_t klen = strlen(cfg.embedding_api_key);
			if (klen > 8) {
				snprintf(masked_key, sizeof(masked_key), "%.8s***", cfg.embedding_api_key);
			} else {
				snprintf(masked_key, sizeof(masked_key), "%s", cfg.embedding_api_key);
			}
		} else {
			snprintf(masked_key, sizeof(masked_key), "(not set)");
		}

		if (g_json_output) {
			printf("{\n");
			printf("  \"embedding.api\":{\"value\":\"%s\",\"source\":\"%s\"},\n", cfg.embedding_api, src.api);
			printf("  \"embedding.url\":{\"value\":\"%s\",\"source\":\"%s\"},\n", cfg.embedding_url, src.url);
			printf("  \"embedding.model\":{\"value\":\"%s\",\"source\":\"%s\"},\n", cfg.embedding_model, src.model);
			printf("  \"embedding.api_key\":{\"value\":\"%s\",\"source\":\"%s\"},\n", masked_key, src.api_key);
			printf("  \"embedding.dim\":{\"value\":%d,\"source\":\"%s\"},\n", cfg.embedding_dim, src.dim);
			printf("  \"search.limit\":{\"value\":%d,\"source\":\"%s\"},\n", cfg.search_limit, src.limit);
			printf("  \"search.weight_vector\":{\"value\":%.1f,\"source\":\"%s\"},\n", (double)cfg.weight_vector, src.weight_vector);
			printf("  \"search.weight_lexical\":{\"value\":%.1f,\"source\":\"%s\"},\n", (double)cfg.weight_lexical, src.weight_lexical);
			printf("  \"index.max_chunk_tokens\":{\"value\":%d,\"source\":\"%s\"}\n", cfg.max_chunk_tokens, src.max_chunk_tokens);
			printf("}\n");
		} else {
			printf("Configuration debug — showing effective values with sources\n\n");
			printf("%s[embedding]%s\n", color(ANSI_BOLD), color(ANSI_RESET));
			printf("  %sapi%s      = %-20s (%s)\n", color(ANSI_CYAN), color(ANSI_RESET), cfg.embedding_api, src.api);
			printf("  %surl%s      = %-20s (%s)\n", color(ANSI_CYAN), color(ANSI_RESET), cfg.embedding_url, src.url);
			printf("  %smodel%s    = %-20s (%s)\n", color(ANSI_CYAN), color(ANSI_RESET), cfg.embedding_model, src.model);
			printf("  %sapi_key%s  = %-20s (%s)\n", color(ANSI_CYAN), color(ANSI_RESET), masked_key, src.api_key);
			printf("  %sdim%s      = %-20d (%s)\n", color(ANSI_CYAN), color(ANSI_RESET), cfg.embedding_dim, src.dim);
			printf("\n%s[search]%s\n", color(ANSI_BOLD), color(ANSI_RESET));
			printf("  %slimit%s    = %-20d (%s)\n", color(ANSI_CYAN), color(ANSI_RESET), cfg.search_limit, src.limit);
			printf("  %sweight_vector%s = %-14.1f (%s)\n", color(ANSI_CYAN), color(ANSI_RESET), (double)cfg.weight_vector, src.weight_vector);
			printf("  %sweight_lexical%s = %-13.1f (%s)\n", color(ANSI_CYAN), color(ANSI_RESET), (double)cfg.weight_lexical, src.weight_lexical);
			printf("\n%s[index]%s\n", color(ANSI_BOLD), color(ANSI_RESET));
			printf("  %smax_chunk_tokens%s = %-10d (%s)\n", color(ANSI_CYAN), color(ANSI_RESET), cfg.max_chunk_tokens, src.max_chunk_tokens);
		}

		free(cfg_path);
		free(db_path);
		return 0;
	}

	if (key == NULL) {
		/* Show all config — load from INI file */
		DocscanConfig cfg;
		config_defaults(&cfg);
		load_config(cfg_path, &cfg); /* OK if missing, we show defaults */

		/* Also pull any legacy DB config values */
		docscan_db* db = docscan_open(db_path, DEFAULT_EMBEDDING_DIM, err_buf, sizeof(err_buf));
		if (db) {
			char* db_model = docscan_config_get(db, "model", err_buf, sizeof(err_buf));
			if (db_model) {
				/* DB model only applies if INI doesn't have one set already */
				if (strcmp(cfg.embedding_model, DEFAULT_MODEL) == 0) {
					snprintf(cfg.embedding_model, sizeof(cfg.embedding_model), "%s", db_model);
				}
				docscan_free(db_model);
			}
			docscan_close(db);
		}

		if (g_json_output) {
			printf("{");
			printf("\"embedding.api\":\"%s\"", cfg.embedding_api);
			printf(",\"embedding.url\":\"%s\"", cfg.embedding_url);
			printf(",\"embedding.model\":\"%s\"", cfg.embedding_model);
			printf(",\"embedding.api_key\":\"%s\"", cfg.embedding_api_key);
			printf(",\"embedding.dim\":%d", cfg.embedding_dim);
			printf(",\"search.limit\":%d", cfg.search_limit);
			printf(",\"search.weight_vector\":%.1f", (double)cfg.weight_vector);
			printf(",\"search.weight_lexical\":%.1f", (double)cfg.weight_lexical);
			printf(",\"index.max_chunk_tokens\":%d", cfg.max_chunk_tokens);
			printf("}\n");
		} else {
			fprintf(stderr, "Using config: %s\n", cfg_path);
			printf("%s[embedding]%s\n", color(ANSI_BOLD), color(ANSI_RESET));
			printf("  %sapi%s = %s\n", color(ANSI_CYAN), color(ANSI_RESET), cfg.embedding_api);
			printf("  %surl%s = %s\n", color(ANSI_CYAN), color(ANSI_RESET), cfg.embedding_url);
			printf("  %smodel%s = %s\n", color(ANSI_CYAN), color(ANSI_RESET), cfg.embedding_model);
			printf("  %sapi_key%s = %s\n", color(ANSI_CYAN), color(ANSI_RESET),
				cfg.embedding_api_key[0] ? cfg.embedding_api_key : "(not set)");
			printf("  %sdim%s = %d\n", color(ANSI_CYAN), color(ANSI_RESET), cfg.embedding_dim);
			printf("\n%s[search]%s\n", color(ANSI_BOLD), color(ANSI_RESET));
			printf("  %slimit%s = %d\n", color(ANSI_CYAN), color(ANSI_RESET), cfg.search_limit);
			printf("  %sweight_vector%s = %.1f\n", color(ANSI_CYAN), color(ANSI_RESET), (double)cfg.weight_vector);
			printf("  %sweight_lexical%s = %.1f\n", color(ANSI_CYAN), color(ANSI_RESET), (double)cfg.weight_lexical);
			printf("\n%s[index]%s\n", color(ANSI_BOLD), color(ANSI_RESET));
			printf("  %smax_chunk_tokens%s = %d\n", color(ANSI_CYAN), color(ANSI_RESET), cfg.max_chunk_tokens);
		}
	} else if (value == NULL) {
		/* Get single key — try INI first, then legacy DB */
		char* val = config_ini_get(cfg_path, key);
		if (!val) {
			/* Try legacy DB config */
			docscan_db* db = docscan_open(db_path, DEFAULT_EMBEDDING_DIM, err_buf, sizeof(err_buf));
			if (db) {
				char* db_val = docscan_config_get(db, key, err_buf, sizeof(err_buf));
				if (db_val) {
					val = strdup(db_val);
					docscan_free(db_val);
				}
				docscan_close(db);
			}
		}
		if (val) {
			if (g_json_output) {
				printf("{\"%s\":\"%s\"}\n", key, val);
			} else {
				printf("%s\n", val);
			}
			free(val);
		} else {
			if (g_json_output) {
				printf("{\"error\":\"key not found: %s\"}\n", key);
			} else {
				fprintf(stderr, "Key '%s' not set\n", key);
			}
			free(cfg_path);
			free(db_path);
			return 1;
		}
	} else {
		/* Set key=value — write to INI file */
		int rc = config_ini_set(cfg_path, key, value);
		if (rc != 0) {
			/* Fall back to legacy DB config for unknown keys */
			docscan_db* db = docscan_open(db_path, DEFAULT_EMBEDDING_DIM, err_buf, sizeof(err_buf));
			if (db) {
				rc = docscan_config_set(db, key, value, err_buf, sizeof(err_buf));
				docscan_close(db);
			}
			if (rc != 0) {
				err_msg("failed to set config key '%s'", key);
				free(cfg_path);
				free(db_path);
				return 1;
			}
		}
		if (!g_json_output) {
			printf("Set %s%s%s = %s\n", color(ANSI_CYAN), key, color(ANSI_RESET), value);
		} else {
			printf("{\"ok\":true}\n");
		}
	}

	free(cfg_path);
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

	/* Detect embedding dimension from existing DB config */
	int search_dim = DEFAULT_EMBEDDING_DIM;
	{
		docscan_db* tmp_db = docscan_open(db_path, DEFAULT_EMBEDDING_DIM, err_buf, sizeof(err_buf));
		if (tmp_db) {
			char* dim_str = docscan_config_get(tmp_db, "embedding_dim", err_buf, sizeof(err_buf));
			if (dim_str) {
				int d = atoi(dim_str);
				if (d > 0) search_dim = d;
				docscan_free(dim_str);
			}
			docscan_close(tmp_db);
		}
	}

	docscan_db* db = docscan_open(db_path, (uint32_t)search_dim, err_buf, sizeof(err_buf));
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

				/* Extract page (may be null) */
				int page = -1;
				const char* pg_start = strstr(p, "\"page\":");
				if (pg_start) {
					pg_start += 7;
					if (*pg_start != 'n') /* not "null" */
						page = atoi(pg_start);
				}

				/* Extract source_line (may be null) */
				int source_line = -1;
				const char* sl_start = strstr(p, "\"source_line\":");
				if (sl_start) {
					sl_start += 14;
					if (*sl_start != 'n') /* not "null" */
						source_line = atoi(sl_start);
				}

				/* Display result */
				printf("  %s%d.%s %s%s%s",
					color(ANSI_DIM), result_num, color(ANSI_RESET),
					color(ANSI_BOLD), doc_path, color(ANSI_RESET));
				if (heading[0]) {
					printf(" %s> %s%s", color(ANSI_CYAN), heading, color(ANSI_RESET));
				}
				if (page > 0) {
					printf("  %s(page %d)%s", color(ANSI_DIM), page, color(ANSI_RESET));
				} else if (source_line > 0) {
					printf("  %s(line %d)%s", color(ANSI_DIM), source_line, color(ANSI_RESET));
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

/* ── Parallel indexing infrastructure ──────────────────────────────── */

/*
 * Per-file result structure for parallel indexing.
 * Workers fill in: file_data, file_len, hash_hex, embeddings, num_chunks, error.
 * The main thread uses these to insert into SQLite sequentially.
 */
typedef struct {
	const char*  path;
	const char*  fmt;
	uint8_t*     file_data;
	size_t       file_len;
	char         hash_hex[SHA256_HEX_LEN + 1];
	float*       embeddings;
	uint32_t     num_chunks;
	int          needs_index; /* 1=process, 0=skip (no format or read error) */
	int          error;       /* non-zero = failed */
	char         error_msg[256];
	/* Phase 1 output: chunk texts for batched embedding */
	char**       chunk_texts;      /* extracted chunk text array */
	int          chunk_text_count; /* number of chunk texts */
} IndexResult;

/*
 * Shared context for worker threads.
 * Workers atomically grab the next file index, then do I/O-heavy work
 * (read, hash, parse/chunk, embed). FFI calls and SQLite writes are
 * serialized via ffi_mutex.
 */
typedef struct {
	/* Input */
	char**          file_paths;
	int             file_count;
	atomic_int      next_file;    /* shared counter — workers grab next atomically */
	const char*     model;
	int             have_embedder;
	docscan_db*     db;           /* database handle for inserts */

	/* Output — pre-allocated array, one slot per file */
	IndexResult*    results;

	/* Progress */
	atomic_int      completed;

	/* Synchronization */
#ifndef _WIN32
	pthread_mutex_t ffi_mutex;    /* protects docscan_chunk + SQLite (Zig GPA not thread-safe) */
#endif
} IndexWorkerCtx;

#ifndef _WIN32
static void* index_worker(void* arg) {
	IndexWorkerCtx* ctx = (IndexWorkerCtx*)arg;
	char err_buf[ERR_BUF_LEN];

	while (1) {
		int idx = atomic_fetch_add(&ctx->next_file, 1);
		if (idx >= ctx->file_count) break;

		IndexResult* r = &ctx->results[idx];
		r->path = ctx->file_paths[idx];
		r->error_msg[0] = '\0';
		r->chunk_texts = NULL;
		r->chunk_text_count = 0;

		/* Check format */
		r->fmt = format_for_ext(r->path);
		if (!r->fmt) {
			r->needs_index = 0;
			atomic_fetch_add(&ctx->completed, 1);
			continue;
		}

		/* Read file — thread-safe (independent file handles) */
		r->file_len = 0;
		r->file_data = read_file(r->path, &r->file_len);
		if (!r->file_data) {
			r->error = 1;
			r->needs_index = 0;
			atomic_fetch_add(&ctx->completed, 1);
			continue;
		}

		/* Compute hash — thread-safe (stack-local state) */
		sha256_hex(r->file_data, r->file_len, r->hash_hex);

		/* Check reindex (SQLite read — mutex-protected) */
		pthread_mutex_lock(&ctx->ffi_mutex);
		int needs = docscan_needs_reindex(ctx->db, r->path, r->hash_hex);
		pthread_mutex_unlock(&ctx->ffi_mutex);

		if (needs == 0) {
			free(r->file_data);
			r->file_data = NULL;
			r->needs_index = 0;
			atomic_fetch_add(&ctx->completed, 1);
			continue;
		}

		r->needs_index = 1;

		/*
		 * Phase 1: Parse + chunk + extract texts.
		 * Embedding is deferred to Phase 2 (batched on main thread).
		 * file_data is kept alive for Phase 3 insertion.
		 */
		if (ctx->have_embedder) {
			pthread_mutex_lock(&ctx->ffi_mutex);
			char* chunks_json = docscan_chunk(r->file_data, r->file_len,
			                                   r->path, r->fmt,
			                                   DEFAULT_MAX_TOKENS,
			                                   err_buf, sizeof(err_buf));
			pthread_mutex_unlock(&ctx->ffi_mutex);

			if (chunks_json) {
				int text_count = 0;
				char** texts = extract_chunk_texts(chunks_json, &text_count);
				if (texts && text_count > 0) {
					r->chunk_texts = texts;
					r->chunk_text_count = text_count;
					r->num_chunks = (uint32_t)text_count;
				} else {
					r->num_chunks = (uint32_t)count_json_array_objects(chunks_json);
				}
				docscan_free(chunks_json);
			}
		}

		atomic_fetch_add(&ctx->completed, 1);
	}
	return NULL;
}
#endif /* !_WIN32 */

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
	if (!is_absolute_path(target_path)) {
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
	if (plen > 1 && (abs_path[plen - 1] == '/' || abs_path[plen - 1] == '\\'))
		abs_path[plen - 1] = '\0';

	/* Collect files */
	file_list fl;
	file_list_init(&fl);
	collect_files(abs_path, &fl);
	if (fl.count > 1) qsort(fl.paths, (size_t)fl.count, sizeof(char*), file_list_cmp);

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

	/* Check embedding server availability — try configured, then Ollama, then oMLX */
	int have_embedder = embedding_server_available();
	int embedding_dim = DEFAULT_EMBEDDING_DIM;

	if (!have_embedder) {
		/* Try Ollama default if not already configured for it */
		if (strcmp(g_embedding_url, "http://127.0.0.1:11434") != 0) {
			info_msg("Configured embedding server at %s is not running, trying Ollama (localhost:11434)...", g_embedding_url);
			snprintf(g_embedding_url, sizeof(g_embedding_url), "http://127.0.0.1:11434");
			g_api_dialect = API_OLLAMA;
			have_embedder = embedding_server_available();
		}
	}
	if (!have_embedder) {
		/* Try oMLX default */
		info_msg("Ollama not running, trying oMLX (localhost:8000)...");
		snprintf(g_embedding_url, sizeof(g_embedding_url), "http://127.0.0.1:8000");
		g_api_dialect = API_OPENAI;
		have_embedder = embedding_server_available();
		if (have_embedder) {
			info_msg("Found oMLX at localhost:8000");
		}
	}

	if (!have_embedder) {
		warn_msg("No embedding server found (tried configured, Ollama:11434, oMLX:8000).");
		if (isatty(STDERR_FILENO)) {
			fprintf(stderr, "Index without embeddings (text search only)? [y/N] ");
			fflush(stderr);
			int ch = getchar();
			if (ch != 'y' && ch != 'Y') {
				info_msg("Aborted. Start an embedding server and try again.");
				free(db_path);
				file_list_free(&fl);
				return 1;
			}
		} else {
			warn_msg("No interactive terminal — proceeding without embeddings.");
		}
	} else {
		/* Probe the embedding server to detect actual dimension */
		int probe_dim = 0;
		char* probe_texts[] = { "dimension probe" };
		float* probe = embed_texts(model, probe_texts, 1, &probe_dim);
		if (probe && probe_dim > 0) {
			embedding_dim = probe_dim;
			info_msg("Embedding server: %s (dialect: %s, model: %s, dim: %d)",
				g_embedding_url,
				g_api_dialect == API_OPENAI ? "openai" : "ollama",
				model, embedding_dim);
			free(probe);
		}
	}

	/* Open/create database */
	docscan_db* db = docscan_open(db_path, (uint32_t)embedding_dim, err_buf, sizeof(err_buf));
	if (!db) {
		err_msg("failed to open database: %s", err_buf);
		free(db_path);
		file_list_free(&fl);
		return 1;
	}

	/* Store model in config */
	docscan_config_set(db, "model", model, err_buf, sizeof(err_buf));

	/* Save config.ini with current effective settings */
	{
		char* cfg_path = config_ini_path_from_db(db_path);
		if (cfg_path) {
			DocscanConfig cfg;
			config_defaults(&cfg);
			load_config(cfg_path, &cfg); /* Preserve existing settings */

			/* Apply current effective values from globals/args */
			snprintf(cfg.embedding_api, sizeof(cfg.embedding_api),
				"%s", g_api_dialect == API_OPENAI ? "openai" : "ollama");
			snprintf(cfg.embedding_url, sizeof(cfg.embedding_url),
				"%s", g_embedding_url);
			snprintf(cfg.embedding_model, sizeof(cfg.embedding_model),
				"%s", model);
			if (g_api_key[0]) {
				snprintf(cfg.embedding_api_key, sizeof(cfg.embedding_api_key),
					"%s", g_api_key);
			}
			if (embedding_dim != DEFAULT_EMBEDDING_DIM) {
				cfg.embedding_dim = embedding_dim;
			}

			save_config(cfg_path, &cfg);
			free(cfg_path);
		}
	}

	/* Process files */
	progress_t prog;
	progress_init(&prog, fl.count);

	int indexed = 0, skipped = 0, errors = 0;

#ifndef _WIN32
	if (g_num_threads > 1) {
		/*
		 * ── Multi-threaded path (3-phase pipeline) ──
		 *
		 * Phase 1 (parallel): Workers read files, hash, check reindex,
		 *   parse+chunk (mutex-protected FFI). Store chunk texts in results.
		 *
		 * Phase 2 (batched): Main thread collects ALL chunk texts from all
		 *   files into one flat array. Embeds in batches of up to 256 texts
		 *   per HTTP call. Reduces ~N HTTP calls to ceil(total_chunks/256).
		 *
		 * Phase 3 (sequential): Main thread inserts each file into SQLite
		 *   with its pre-computed embedding slice from the global array.
		 */
		int nthreads = g_num_threads;
		if (nthreads > fl.count) nthreads = fl.count;

		info_msg("Indexing with %d threads", nthreads);

		/* Allocate results array */
		IndexResult* results = calloc((size_t)fl.count, sizeof(IndexResult));
		if (!results) {
			err_msg("out of memory allocating result array");
			docscan_close(db);
			free(db_path);
			file_list_free(&fl);
			return 1;
		}

		/* Set up shared context */
		IndexWorkerCtx ctx;
		ctx.file_paths = fl.paths;
		ctx.file_count = fl.count;
		atomic_init(&ctx.next_file, 0);
		ctx.model = model;
		ctx.have_embedder = have_embedder;
		ctx.db = db;
		ctx.results = results;
		atomic_init(&ctx.completed, 0);
		pthread_mutex_init(&ctx.ffi_mutex, NULL);

		/* Spawn worker threads */
		pthread_t* threads = malloc(sizeof(pthread_t) * (size_t)nthreads);
		if (!threads) {
			err_msg("out of memory allocating thread array");
			free(results);
			docscan_close(db);
			free(db_path);
			file_list_free(&fl);
			return 1;
		}

		for (int t = 0; t < nthreads; t++) {
			int rc = pthread_create(&threads[t], NULL, index_worker, &ctx);
			if (rc != 0) {
				err_msg("failed to create thread %d: %s", t, strerror(rc));
				/* Reduce thread count to what we actually created */
				nthreads = t;
				break;
			}
		}

		/* Progress updates while Phase 1 workers run */
		while (atomic_load(&ctx.completed) < fl.count) {
			int done = atomic_load(&ctx.completed);
			/* Find a path to show (approximate — pick the done'th file) */
			const char* show_path = (done < fl.count) ? fl.paths[done] : NULL;
			progress_update(&prog, done, show_path);

			/* Brief sleep to avoid busy-spinning (1ms) */
			struct timespec ts = { .tv_sec = 0, .tv_nsec = 1000000 };
			nanosleep(&ts, NULL);
		}

		/* Wait for all workers to finish */
		for (int t = 0; t < nthreads; t++) {
			pthread_join(threads[t], NULL);
		}
		free(threads);
		pthread_mutex_destroy(&ctx.ffi_mutex);

		progress_finish(&prog);

		/* ── Phase 2: Batched embedding ──────────────────────────── */

		/* Count total chunks across all files that need indexing */
		int total_chunks = 0;
		int files_to_index = 0;
		for (int i = 0; i < fl.count; i++) {
			if (results[i].needs_index && !results[i].error)
				total_chunks += results[i].chunk_text_count;
			if (results[i].needs_index) files_to_index++;
		}

		float* all_embeddings = NULL;
		int emb_dim = 0;

		if (have_embedder && total_chunks > 0) {
			/* Build flat array of ALL chunk texts */
			char** all_texts = malloc(sizeof(char*) * (size_t)total_chunks);
			if (!all_texts) {
				err_msg("out of memory allocating text array for embedding");
				/* Fall through — will insert without embeddings */
			} else {
				/* Also track where each file's chunks start in the global array */
				int* file_chunk_offsets = calloc((size_t)fl.count, sizeof(int));
				int running_offset = 0;
				for (int i = 0; i < fl.count; i++) {
					file_chunk_offsets[i] = running_offset;
					if (results[i].needs_index && !results[i].error) {
						for (int j = 0; j < results[i].chunk_text_count; j++) {
							all_texts[running_offset++] = results[i].chunk_texts[j];
						}
					}
				}

				/* Embed in batches of up to EMBED_BATCH_SIZE texts per HTTP call.
				 * Reduces HTTP overhead (one call per batch vs per file) and
				 * lets the embedding server batch internally on the GPU. */
				#define EMBED_BATCH_SIZE 256
				all_embeddings = malloc(sizeof(float) * (size_t)total_chunks * (size_t)embedding_dim);
				if (!all_embeddings) {
					err_msg("out of memory allocating embedding array");
				} else {
					int total_batches = (total_chunks + EMBED_BATCH_SIZE - 1) / EMBED_BATCH_SIZE;

					info_msg("Embedding %d chunks in %d batch%s...",
						total_chunks, total_batches, total_batches == 1 ? "" : "es");

					progress_init(&prog, total_chunks);

					/* Serialize embedding calls to avoid overloading the server.
					 * The server handles batching internally on the GPU. */
					for (int batch_start = 0; batch_start < total_chunks; batch_start += EMBED_BATCH_SIZE) {
						int batch_size = total_chunks - batch_start;
						if (batch_size > EMBED_BATCH_SIZE) batch_size = EMBED_BATCH_SIZE;
						int batch_idx = batch_start / EMBED_BATCH_SIZE;

						int dim = 0;
						float* batch_emb = embed_texts(model, &all_texts[batch_start],
						                                batch_size, &dim);
						if (batch_emb && dim > 0) {
							emb_dim = dim;
							memcpy(&all_embeddings[batch_start * dim],
							       batch_emb,
							       (size_t)batch_size * (size_t)dim * sizeof(float));
							free(batch_emb);
						} else {
							/* Batch failed — zero-fill so indices stay aligned */
							if (emb_dim > 0) {
								memset(&all_embeddings[batch_start * emb_dim], 0,
								       (size_t)batch_size * (size_t)emb_dim * sizeof(float));
							}
							warn_msg("embedding batch %d/%d failed", batch_idx + 1, total_batches);
						}
						progress_update(&prog, batch_start + batch_size, NULL);
					}

					progress_finish(&prog);
				}

				free(file_chunk_offsets);
				free(all_texts);
			}
		}

		/* ── Phase 3: Sequential insertion + tally ───────────────── */
		int emb_global_offset = 0;
		info_msg("Inserting %d file%s into database...",
			files_to_index, files_to_index == 1 ? "" : "s");
		progress_init(&prog, fl.count);

		for (int i = 0; i < fl.count; i++) {
			IndexResult* r = &results[i];
			progress_update(&prog, i, r->path);

			if (r->error) {
				warn_msg("failed to index %s%s%s", r->path,
					r->error_msg[0] ? ": " : "",
					r->error_msg[0] ? r->error_msg : "");
				errors++;
				continue;
			}

			if (!r->needs_index) {
				skipped++;
				continue;
			}

			/* Get this file's embedding slice */
			float* file_embeddings = NULL;
			uint32_t file_num_chunks = r->num_chunks;
			if (all_embeddings && emb_dim > 0 && r->chunk_text_count > 0) {
				file_embeddings = &all_embeddings[emb_global_offset * emb_dim];
				file_num_chunks = (uint32_t)r->chunk_text_count;
				emb_global_offset += r->chunk_text_count;
			}

			/* Remove old + insert new */
			docscan_remove_document(db, r->path, err_buf, sizeof(err_buf));
			int rc = docscan_index_file(db, r->file_data, r->file_len,
			                             r->path, r->fmt, r->hash_hex,
			                             file_embeddings, file_num_chunks,
			                             DEFAULT_MAX_TOKENS, err_buf, sizeof(err_buf));

			if (rc == 0) {
				indexed++;
			} else {
				warn_msg("failed to index %s: %s", r->path, err_buf);
				errors++;
			}

			/* Free file data after insertion */
			free(r->file_data);
			r->file_data = NULL;

			/* Free chunk texts */
			if (r->chunk_texts) {
				for (int t = 0; t < r->chunk_text_count; t++)
					free(r->chunk_texts[t]);
				free(r->chunk_texts);
				r->chunk_texts = NULL;
			}
		}

		progress_update(&prog, fl.count, NULL);

		free(all_embeddings);
		free(results);

	} else
#endif /* !_WIN32 */
	{
		/* ── Single-threaded path (threads == 1 or Windows) ── */
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

			/* Remove old document if it exists (for re-indexing) */
			docscan_remove_document(db, fpath, err_buf, sizeof(err_buf));

			/* Get chunk count by calling docscan_chunk */
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
							if (embeddings) {
								num_chunks = (uint32_t)text_count;
							}
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
		if (g_num_threads > 1) {
			printf("  Threads: %d\n", g_num_threads);
		}
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
	if (!is_absolute_path(path)) {
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
	if (fl.count > 1) qsort(fl.paths, (size_t)fl.count, sizeof(char*), file_list_cmp);

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

	/* Detect dimension from existing DB, or probe embedding server */
	int mcp_dim = DEFAULT_EMBEDDING_DIM;
	{
		docscan_db* tmp = docscan_open(db_path, DEFAULT_EMBEDDING_DIM, err_buf, sizeof(err_buf));
		if (tmp) {
			char* dim_str = docscan_config_get(tmp, "embedding_dim", err_buf, sizeof(err_buf));
			if (dim_str) {
				int d = atoi(dim_str);
				if (d > 0) mcp_dim = d;
				docscan_free(dim_str);
			}
			docscan_close(tmp);
		}
	}

	docscan_db* db = docscan_open(db_path, (uint32_t)mcp_dim, err_buf, sizeof(err_buf));
	if (!db) {
		fprintf(stderr, "mcp-serve: failed to open database: %s\n", err_buf);
		free(db_path);
		return 1;
	}

	fprintf(stderr, "docscan MCP server running (db: %s, dim: %d)\n", db_path, mcp_dim);

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

	/* Track which settings were explicitly set by CLI flags */
	int cli_set_model = 0;
	int cli_set_api = 0;
	int cli_set_url = 0;
	int cli_set_key = 0;
	int cli_set_limit = 0;

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
			cli_set_model = 1;
			continue;
		}
		if (strcmp(argv[i], "--limit") == 0 && i + 1 < argc) {
			limit = atoi(argv[++i]);
			if (limit <= 0) limit = DEFAULT_LIMIT;
			cli_set_limit = 1;
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
			cli_set_api = 1;
			continue;
		}
		if (strcmp(argv[i], "--embedding-url") == 0 && i + 1 < argc) {
			snprintf(g_embedding_url, sizeof(g_embedding_url), "%s", argv[++i]);
			cli_set_url = 1;
			continue;
		}
		if (strcmp(argv[i], "--embedding-api-key") == 0 && i + 1 < argc) {
			snprintf(g_api_key, sizeof(g_api_key), "%s", argv[++i]);
			cli_set_key = 1;
			continue;
		}
		if (strcmp(argv[i], "--threads") == 0 && i + 1 < argc) {
			g_num_threads = atoi(argv[++i]);
			if (g_num_threads < 1) g_num_threads = 1;
			if (g_num_threads > MAX_THREADS) g_num_threads = MAX_THREADS;
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

	/* ── Load global config (~/.config/docscan/config.ini) first ── */
	{
		char global_cfg[MAX_PATH_LEN];
		const char* xdg = getenv("XDG_CONFIG_HOME");
		if (xdg && xdg[0]) {
			snprintf(global_cfg, sizeof(global_cfg), "%s/docscan/config.ini", xdg);
		} else {
			const char* home = getenv("HOME");
			if (home)
				snprintf(global_cfg, sizeof(global_cfg), "%s/.config/docscan/config.ini", home);
			else
				global_cfg[0] = '\0';
		}
		if (global_cfg[0]) {
			DocscanConfig gcfg;
			config_defaults(&gcfg);
			if (load_config(global_cfg, &gcfg) == 0) {
				/* Apply global config as base defaults */
				if (!cli_set_api && strcasecmp(gcfg.embedding_api, "ollama") != 0) {
					if (strcasecmp(gcfg.embedding_api, "openai") == 0)
						g_api_dialect = API_OPENAI;
				}
				if (!cli_set_url && gcfg.embedding_url[0] &&
				    strcmp(gcfg.embedding_url, "http://127.0.0.1:11434") != 0)
					snprintf(g_embedding_url, sizeof(g_embedding_url), "%s", gcfg.embedding_url);
				if (!cli_set_model && !model && gcfg.embedding_model[0] &&
				    strcmp(gcfg.embedding_model, "nomic-embed-text") != 0) {
					static char global_model[256];
					snprintf(global_model, sizeof(global_model), "%s", gcfg.embedding_model);
					model = global_model;
				}
				if (!cli_set_key && !g_api_key[0] && gcfg.embedding_api_key[0])
					snprintf(g_api_key, sizeof(g_api_key), "%s", gcfg.embedding_api_key);
			}
		}
	}

	/* ── Load project .docscan/config.ini (overrides global) ── */
	/* Try to determine the .docscan/ dir for config loading.
	 * Priority: --db path > first positional for index/update > cwd */
	{
		const char* cfg_target = ".";
		if (positional_count > 0) cfg_target = positionals[0];

		char* early_db = resolve_db_path(db_path_arg, cfg_target);
		if (early_db) {
			char* cfg_path = config_ini_path_from_db(early_db);
			if (cfg_path) {
				DocscanConfig cfg;
				config_defaults(&cfg);
				if (load_config(cfg_path, &cfg) == 0) {
					/* Apply config.ini values only where CLI didn't override */
					if (!cli_set_api) {
						if (strcasecmp(cfg.embedding_api, "openai") == 0) {
							g_api_dialect = API_OPENAI;
						} else {
							g_api_dialect = API_OLLAMA;
						}
					}
					if (!cli_set_url) {
						snprintf(g_embedding_url, sizeof(g_embedding_url),
							"%s", cfg.embedding_url);
					}
					if (!cli_set_model && !model) {
						/* Use a static buffer so the pointer stays valid */
						static char ini_model[256];
						snprintf(ini_model, sizeof(ini_model), "%s", cfg.embedding_model);
						model = ini_model;
					}
					if (!cli_set_key && !g_api_key[0]) {
						snprintf(g_api_key, sizeof(g_api_key),
							"%s", cfg.embedding_api_key);
					}
					if (!cli_set_limit) {
						limit = cfg.search_limit;
					}
				}
				free(cfg_path);
			}
			free(early_db);
		}
	}

	/* Apply environment variable overrides (higher priority than config.ini) */
	{
		const char* env_model = getenv("DOCSCAN_MODEL");
		if (env_model && env_model[0] && !cli_set_model) {
			model = env_model;
		}
	}
	if (!model) {
		model = DEFAULT_MODEL;
	}
	if (!lang) {
		const char* env_lang = getenv("DOCSCAN_LANG");
		if (env_lang && env_lang[0]) lang = env_lang;
	}

	/* Embedding API env vars (override config.ini, but CLI flags override these) */
	{
		const char* env_api = getenv("DOCSCAN_EMBEDDING_API");
		if (env_api && env_api[0] && !cli_set_api) {
			if (strcasecmp(env_api, "openai") == 0) {
				g_api_dialect = API_OPENAI;
			} else if (strcasecmp(env_api, "ollama") == 0) {
				g_api_dialect = API_OLLAMA;
			}
		}
		const char* env_url = getenv("DOCSCAN_EMBEDDING_URL");
		if (env_url && env_url[0] && !cli_set_url) {
			snprintf(g_embedding_url, sizeof(g_embedding_url), "%s", env_url);
		}
		const char* env_key = getenv("DOCSCAN_EMBEDDING_API_KEY");
		if (env_key && env_key[0] && !cli_set_key) {
			snprintf(g_api_key, sizeof(g_api_key), "%s", env_key);
		}
	}

	/* DOCSCAN_THREADS env var (CLI --threads flag overrides) */
	{
		const char* env_threads = getenv("DOCSCAN_THREADS");
		if (env_threads && env_threads[0]) {
			/* Only apply if --threads was not explicitly given on CLI.
			 * We detect this by checking if g_num_threads is still DEFAULT_THREADS.
			 * This is imperfect (user could explicitly pass --threads 4) but
			 * matches the precedence convention: CLI > env > default. */
			int env_t = atoi(env_threads);
			if (env_t >= 1 && env_t <= MAX_THREADS) {
				/* Check if --threads was NOT on the command line by rescanning argv.
				 * This is more correct than guessing from the default value. */
				int cli_set_threads = 0;
				for (int i = 1; i < argc; i++) {
					if (strcmp(argv[i], "--threads") == 0) { cli_set_threads = 1; break; }
				}
				if (!cli_set_threads) {
					g_num_threads = env_t;
				}
			}
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
