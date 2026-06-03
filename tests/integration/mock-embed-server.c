/* mock-embed-server — a minimal, scriptable OpenAI-dialect embedding server
 * for deterministically testing docscan's embedding-failure handling (retry +
 * mark-for-reindex). No dependencies; compiled with the system C compiler.
 *
 * Usage: mock-embed-server <port> <dim> <fail_csv>
 *   port     TCP port to bind on 127.0.0.1
 *   dim      embedding dimension to return (small, e.g. 8, for speed)
 *   fail_csv comma-separated 1-based request numbers to answer with HTTP 503
 *            (empty string = never fail). Each HTTP request increments the
 *            counter, so retries (fresh connections) get successive numbers.
 *
 * On a 200 it returns exactly as many `dim`-length vectors as there are strings
 * in the request's "input" array, matching docscan's nvecs==num_texts check.
 * Prints "LISTENING <port>" once bound so a test can wait for readiness. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <signal.h>

/* Count top-level strings in the "input":[...] array of an OpenAI embeddings
 * request body. docscan only ever sends a flat array of strings, so counting
 * string literals at array depth handles it (respecting JSON escapes). */
static int count_input_strings(const char* body) {
	const char* p = strstr(body, "\"input\"");
	if (!p) return 0;
	while (*p && *p != '[') p++;
	if (*p != '[') return 0;
	p++; /* past [ */
	int count = 0, depth = 1, in_str = 0, esc = 0;
	for (; *p && depth > 0; p++) {
		if (in_str) {
			if (esc) esc = 0;
			else if (*p == '\\') esc = 1;
			else if (*p == '"') in_str = 0;
		} else if (*p == '"') {
			in_str = 1;
			count++;
		} else if (*p == '[') depth++;
		else if (*p == ']') depth--;
	}
	return count;
}

static int in_fail_list(const char* csv, int n) {
	if (!csv || !*csv) return 0;
	const char* p = csv;
	while (*p) {
		int v = atoi(p);
		if (v == n) return 1;
		while (*p && *p != ',') p++;
		if (*p == ',') p++;
	}
	return 0;
}

int main(int argc, char** argv) {
	if (argc < 4) {
		fprintf(stderr, "usage: %s <port> <dim> <fail_csv>\n", argv[0]);
		return 2;
	}
	int port = atoi(argv[1]);
	int dim = atoi(argv[2]);
	const char* fail_csv = argv[3];
	const char* stall_csv = (argc > 4) ? argv[4] : "";
	if (dim < 1) dim = 8;

	signal(SIGPIPE, SIG_IGN);

	int srv = socket(AF_INET, SOCK_STREAM, 0);
	if (srv < 0) { perror("socket"); return 1; }
	int yes = 1;
	setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	addr.sin_port = htons((unsigned short)port);
	if (bind(srv, (struct sockaddr*)&addr, sizeof(addr)) < 0) { perror("bind"); return 1; }
	if (listen(srv, 16) < 0) { perror("listen"); return 1; }

	printf("LISTENING %d\n", port);
	fflush(stdout);

	int request_no = 0;
	for (;;) {
		int cl = accept(srv, NULL, NULL);
		if (cl < 0) continue;

		/* Read request: headers until \r\n\r\n, then Content-Length bytes. */
		/* 8 MiB static buffer (single-threaded server) — large embedding
		 * batches produce multi-MB request bodies; a small buffer would
		 * truncate and force an early close, SIGPIPE-killing the client. */
		static char buf[8 << 20];
		size_t total = 0;
		ssize_t n;
		char* hdr_end = NULL;
		while (total < sizeof(buf) - 1 &&
		       (n = read(cl, buf + total, sizeof(buf) - 1 - total)) > 0) {
			total += (size_t)n;
			buf[total] = '\0';
			hdr_end = strstr(buf, "\r\n\r\n");
			if (hdr_end) {
				/* Ensure we've read the full declared body. */
				const char* clh = strcasestr(buf, "content-length:");
				long want = clh ? atol(clh + 15) : 0;
				size_t have = total - (size_t)(hdr_end + 4 - buf);
				if ((long)have >= want) break;
			}
		}

		/* A bare TCP availability probe (docscan's embedding_server_available)
		 * connects without sending an embeddings body. Do not count it as a
		 * request, so fail-plan numbering tracks only real embed calls. */
		if (!strstr(buf, "\"input\"")) {
			close(cl);
			continue;
		}
		request_no++;
		/* Stalled request: hold the connection open without responding so the
		 * client blocks in read() — exercises the read-timeout path. */
		if (in_fail_list(stall_csv, request_no)) {
			sleep(3600);
			close(cl);
			continue;
		}
		int ninputs = count_input_strings(buf);
		if (ninputs < 1) ninputs = 1;

		char resp[1 << 16];
		if (in_fail_list(fail_csv, request_no)) {
			const char* msg = "{\"error\":{\"message\":\"mock transient failure\"}}";
			int rl = snprintf(resp, sizeof(resp),
				"HTTP/1.1 503 Service Unavailable\r\n"
				"Content-Type: application/json\r\n"
				"Content-Length: %zu\r\n"
				"Connection: close\r\n\r\n%s", strlen(msg), msg);
			(void)write(cl, resp, (size_t)rl);
			close(cl);
			continue;
		}

		/* Build a valid OpenAI embeddings response with `ninputs` vectors. */
		char* body = malloc((size_t)ninputs * (size_t)dim * 8 + 4096);
		size_t off = 0;
		off += (size_t)sprintf(body + off, "{\"object\":\"list\",\"data\":[");
		for (int i = 0; i < ninputs; i++) {
			off += (size_t)sprintf(body + off,
				"%s{\"object\":\"embedding\",\"index\":%d,\"embedding\":[",
				i ? "," : "", i);
			for (int d = 0; d < dim; d++)
				off += (size_t)sprintf(body + off, "%s0.01", d ? "," : "");
			off += (size_t)sprintf(body + off, "]}");
		}
		off += (size_t)sprintf(body + off, "],\"model\":\"mock\"}");

		int rl = snprintf(resp, sizeof(resp),
			"HTTP/1.1 200 OK\r\n"
			"Content-Type: application/json\r\n"
			"Content-Length: %zu\r\n"
			"Connection: close\r\n\r\n", off);
		(void)write(cl, resp, (size_t)rl);
		(void)write(cl, body, off);
		free(body);
		close(cl);
	}
	return 0;
}
