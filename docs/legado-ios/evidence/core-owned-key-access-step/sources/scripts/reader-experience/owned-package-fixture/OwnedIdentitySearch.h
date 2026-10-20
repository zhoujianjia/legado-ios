#ifndef YUEDU_OWNED_IDENTITY_SEARCH_H
#define YUEDU_OWNED_IDENTITY_SEARCH_H

#include <CoreFoundation/CoreFoundation.h>
#include <Security/SecBase.h>
#include <Security/SecKeychain.h>
#include <Security/SecKey.h>
#include <Security/SecAccess.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* macOS owned-fixture producer only. No identity/key is returned or retained.
 * The caller supplies its one owned Keychain and a bounded public leaf DER.
 * Output count is zero on every failure; success means exactly one exact leaf. */
OSStatus YueduOwnedIdentitySearchCount(SecKeychainRef keychain,
                                      CFDataRef expectedLeaf,
                                      uint32_t *matchingCount);

/* Bounded public facts only. A path entry is not a code-requirement check or
 * evidence that the separate codesign process has exercised this ACL. */
typedef struct {
    uint32_t privateKeyCount, sameOwnedKeychain, aclCount;
    uint32_t signACLCount, signAppListACLCount, signAllowAnyACLCount, signEmptyACLCount;
    uint32_t signTrustedApplicationCount, codesignPathEntryCount;
    uint32_t partitionACLCount, partitionIDCount;
    uint32_t applePartitionCount, appleToolPartitionCount, codesignPartitionCount, otherPartitionCount;
    uint32_t opaqueACLCount, unknownAuthorizationCount;
    uint32_t ownerACLCount, ownerAllowAnyACLCount, ownerTrustedApplicationCount, creatorOwnerPathEntryCount;
} YueduOwnedKeyACLReport;

/* Only the just-created, not-yet-imported SecAccess in this owned producer.
 * Adds its current importer subject to the actual owner, identified by the
 * public API's owner-edit rejection before any tags can be changed. */
OSStatus YueduOwnedAccessAuthorizeCreator(SecAccessRef access);

/* Exactly one private signing key in this one owned Keychain is required.
 * Inspect only, or append the current codesign subject once to one known
 * finite sign application list. A documented path cannot authenticate the
 * stored subject, so it does not suppress this explicit owned authorization.
 * No allow-all/custom ACL is rewritten.
 * All outputs are zero on failure; neither key nor raw ACL leaves this API. */
OSStatus YueduOwnedKeyACLInspect(SecKeychainRef keychain, SecKeyRef privateKey,
                               uint32_t appendCurrentCodesign,
                               YueduOwnedKeyACLReport *before,
                               YueduOwnedKeyACLReport *after,
                               uint32_t *classicChanged);

#ifdef __cplusplus
}
#endif
#endif
