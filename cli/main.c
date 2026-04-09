/*
 * docscan CLI — C entry point that dogfoods the C FFI.
 * All I/O lives here; the Zig core is pure computation.
 */

#include <stdio.h>
#include "docscan_core.h"

int main(int argc, char** argv) {
	(void)argc;
	(void)argv;

#ifndef NDEBUG
	fprintf(stderr, "\033[33mDEBUG BUILD\033[0m\n");
#endif

	printf("docscan %s\n", docscan_version());
	return 0;
}
