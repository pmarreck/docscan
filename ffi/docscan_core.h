/*
 * docscan_core.h — C FFI header for docscan
 *
 * This is the public API boundary. The C CLI and any external consumers
 * include this header and link against libdocscan_core.a.
 */

#ifndef DOCSCAN_CORE_H
#define DOCSCAN_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Return the docscan version string (statically allocated, do not free). */
const char* docscan_version(void);

#ifdef __cplusplus
}
#endif

#endif /* DOCSCAN_CORE_H */
