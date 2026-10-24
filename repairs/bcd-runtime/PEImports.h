#ifndef BCD_PE_IMPORTS_H
#define BCD_PE_IMPORTS_H
#include <stddef.h>
typedef void (*BCDImportVisitor)(const char *dll, const char *function, int delayed, void *context);
/* Returns the number of imported symbols, or -1 for malformed/out-of-bounds data. */
int bcd_pe_imports(const unsigned char *bytes, size_t size, BCDImportVisitor visitor, void *context);
#endif
