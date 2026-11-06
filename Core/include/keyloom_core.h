#ifndef KEYLOOM_CORE_H
#define KEYLOOM_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Version of this C interface. Bumped on any incompatible change.
uint32_t keyloom_core_abi_version(void);

#ifdef __cplusplus
}
#endif

#endif /* KEYLOOM_CORE_H */
