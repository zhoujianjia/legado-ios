#include "OwnedIdentitySearch.h"
#include <Security/SecIdentity.h>
#include <Security/SecIdentitySearch.h>
#include <Security/SecCertificate.h>
#include <Security/cssmtype.h>

/* Public deprecated C APIs, not SPI or an indirect Swift symbol call. Their
 * Copy/Create results are released on both success and error paths. */
OSStatus YueduOwnedIdentitySearchCount(SecKeychainRef keychain,
                                      CFDataRef expectedLeaf,
                                      uint32_t *matchingCount) {
    if (matchingCount == NULL) return errSecParam;
    *matchingCount = 0;
    if (keychain == NULL || expectedLeaf == NULL ||
        CFGetTypeID(keychain) != SecKeychainGetTypeID() ||
        CFGetTypeID(expectedLeaf) != CFDataGetTypeID() ||
        CFDataGetLength(expectedLeaf) < 1 || CFDataGetLength(expectedLeaf) > 65536) {
        return errSecParam;
    }
    SecIdentitySearchRef search = NULL;
    uint32_t count = 0;
    OSStatus status = SecIdentitySearchCreate(keychain, CSSM_KEYUSE_SIGN, &search);
    if (status != errSecSuccess) goto finish;
    if (search == NULL) { status = errSecInternalComponent; goto finish; }
    for (;;) {
        SecIdentityRef identity = NULL;
        status = SecIdentitySearchCopyNext(search, &identity);
        if (status == errSecItemNotFound) {
            if (identity != NULL) CFRelease(identity);
            status = count == 1 ? errSecSuccess : errSecItemNotFound;
            break;
        }
        if (status != errSecSuccess) {
            if (identity != NULL) CFRelease(identity);
            goto finish;
        }
        if (identity == NULL || count >= 16) {
            if (identity != NULL) CFRelease(identity);
            status = errSecDecode;
            goto finish;
        }
        SecCertificateRef certificate = NULL;
        status = SecIdentityCopyCertificate(identity, &certificate);
        CFRelease(identity);
        if (status != errSecSuccess || certificate == NULL) {
            if (certificate != NULL) CFRelease(certificate);
            if (status == errSecSuccess) status = errSecDecode;
            goto finish;
        }
        CFDataRef actualLeaf = SecCertificateCopyData(certificate);
        CFRelease(certificate);
        if (actualLeaf == NULL) { status = errSecDecode; goto finish; }
        Boolean exact = CFDataGetLength(actualLeaf) >= 1 &&
                        CFDataGetLength(actualLeaf) <= 65536 &&
                        CFEqual(actualLeaf, expectedLeaf);
        CFRelease(actualLeaf);
        if (!exact) { status = errSecDecode; goto finish; }
        count += 1;
    }
finish:
    if (search != NULL) CFRelease(search);
    if (status == errSecSuccess) *matchingCount = count;
    return status;
}
