#include "OwnedIdentitySearch.h"
#include <Security/SecIdentity.h>
#include <Security/SecIdentitySearch.h>
#include <Security/SecCertificate.h>
#include <Security/cssmtype.h>
#include <Security/cssmapple.h>
#include <Security/cssmapi.h>
#include <Security/SecCode.h>
#include <Security/SecStaticCode.h>
#include <Security/SecItem.h>
#include <Security/SecKeychainItem.h>
#include <Security/SecAccess.h>
#include <Security/SecACL.h>
#include <Security/Authorization.h>
#include <Security/SecTrustedApplication.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>

OSStatus YueduOwnedUserTrustAuthorizationPreflight(void)
{
    AuthorizationRef authorization = NULL;
    OSStatus status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
                                         kAuthorizationFlagDefaults, &authorization);
    if (status != errAuthorizationSuccess) return status;
    if (authorization == NULL) return errSecInternalComponent;
    AuthorizationItem item = { "com.apple.trust-settings.user", 0, NULL, 0 };
    AuthorizationRights rights = { 1, &item };
    /* Deliberately no kAuthorizationFlagInteractionAllowed; no credentials,
     * no sudo, and no changes to authorization rules. Public TrustSettings
     * Set/Remove may still issue their own OS authorization request later. */
    status = AuthorizationCopyRights(authorization, &rights,
                                    kAuthorizationEmptyEnvironment,
                                    kAuthorizationFlagExtendRights | kAuthorizationFlagPreAuthorize,
                                    NULL);
    OSStatus released = AuthorizationFree(authorization, kAuthorizationFlagDefaults);
    return status == errAuthorizationSuccess ? released : status;
}

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

/* Only the bounded public ACL metadata below is declassified. In particular
 * SecTrustedApplicationCopyData is merely a documented path, not the private
 * API that checks the subject against the code requirement on disk. */
static OSStatus ownedKey(SecKeychainRef keychain, SecKeyRef key) {
    OSStatus status = errSecParam;
    SecKeychainRef actual = NULL;
    CFArrayRef searchList = NULL;
    CFDictionaryRef query = NULL;
    CFTypeRef results = NULL;
    if (keychain == NULL || key == NULL ||
        CFGetTypeID(keychain) != SecKeychainGetTypeID() ||
        CFGetTypeID(key) != SecKeyGetTypeID()) goto finish;
    status = SecKeychainItemCopyKeychain((SecKeychainItemRef)key, &actual);
    if (status != errSecSuccess) goto finish;
    if (actual == NULL) { status = errSecInvalidKeychain; goto finish; }
    char expectedPath[4096], actualPath[4096];
    UInt32 expectedLength = sizeof(expectedPath), actualLength = sizeof(actualPath);
    status = SecKeychainGetPath(keychain, &expectedLength, expectedPath);
    if (status != errSecSuccess) goto finish;
    status = SecKeychainGetPath(actual, &actualLength, actualPath);
    if (status != errSecSuccess) goto finish;
    if (expectedLength == 0 || expectedLength >= sizeof(expectedPath) ||
        actualLength != expectedLength || memcmp(expectedPath, actualPath, actualLength) != 0) {
        status = errSecInvalidKeychain; goto finish;
    }
    const void *one[] = { keychain };
    searchList = CFArrayCreate(NULL, one, 1, &kCFTypeArrayCallBacks);
    if (searchList == NULL) { status = errSecAllocate; goto finish; }
    const void *keys[] = { kSecClass, kSecAttrKeyClass, kSecMatchSearchList, kSecReturnRef, kSecMatchLimit };
    const void *values[] = { kSecClassKey, kSecAttrKeyClassPrivate, searchList, kCFBooleanTrue, kSecMatchLimitAll };
    query = CFDictionaryCreate(NULL, keys, values, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (query == NULL) { status = errSecAllocate; goto finish; }
    status = SecItemCopyMatching(query, &results);
    if (status != errSecSuccess) goto finish;
    if (results == NULL || CFGetTypeID(results) != CFArrayGetTypeID() || CFArrayGetCount(results) != 1) {
        status = errSecDecode; goto finish;
    }
    SecKeyRef candidate = (SecKeyRef)CFArrayGetValueAtIndex(results, 0);
    if (CFGetTypeID(candidate) != SecKeyGetTypeID()) { status = errSecDecode; goto finish; }
    /* The single private key must be the actual identity's private key. Its
     * public representations are safe to compare internally, never exported. */
    SecKeyRef firstPublic = SecKeyCopyPublicKey(key), secondPublic = SecKeyCopyPublicKey(candidate);
    CFDataRef firstBytes = firstPublic == NULL ? NULL : SecKeyCopyExternalRepresentation(firstPublic, NULL);
    CFDataRef secondBytes = secondPublic == NULL ? NULL : SecKeyCopyExternalRepresentation(secondPublic, NULL);
    Boolean equal = firstBytes != NULL && secondBytes != NULL &&
        CFDataGetLength(firstBytes) > 0 && CFDataGetLength(firstBytes) <= 65536 &&
        CFDataGetLength(secondBytes) > 0 && CFDataGetLength(secondBytes) <= 65536 && CFEqual(firstBytes, secondBytes);
    if (firstBytes != NULL) CFRelease(firstBytes);
    if (secondBytes != NULL) CFRelease(secondBytes);
    if (firstPublic != NULL) CFRelease(firstPublic);
    if (secondPublic != NULL) CFRelease(secondPublic);
    if (!equal || !SecKeyIsAlgorithmSupported(key, kSecKeyOperationTypeSign, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256)) {
        status = errSecInvalidKeyRef; goto finish;
    }
    status = errSecSuccess;
finish:
    if (actual != NULL) CFRelease(actual);
    if (searchList != NULL) CFRelease(searchList);
    if (query != NULL) CFRelease(query);
    if (results != NULL) CFRelease(results);
    return status;
}

/* Public code-signing APIs validate this actual running tool and its on-disk
 * code before reading the public unique cdhash. Only a genuinely ad-hoc signed
 * current importer maps unambiguously to cdhash: in Apple's partition policy;
 * unsigned, developer/team and unclassified identities are refused. This does
 * not change the signing of any target or establish Apple authority. */
static OSStatus creatorPartition(CFStringRef *result) {
    if (result == NULL) return errSecParam;
    *result = NULL;
    SecCodeRef dynamic = NULL;
    SecStaticCodeRef code = NULL;
    CFDictionaryRef info = NULL;
    OSStatus status = SecCodeCopySelf(kSecCSDefaultFlags, &dynamic);
    if (status != errSecSuccess) goto finish;
    if (dynamic == NULL) { status = errSecDecode; goto finish; }
    status = SecCodeCheckValidity(dynamic, kSecCSDefaultFlags, NULL);
    if (status != errSecSuccess) goto finish;
    status = SecCodeCopyStaticCode(dynamic, kSecCSDefaultFlags, &code);
    if (status != errSecSuccess) goto finish;
    if (code == NULL) { status = errSecDecode; goto finish; }
    status = SecStaticCodeCheckValidity(code, kSecCSDefaultFlags, NULL);
    if (status != errSecSuccess) goto finish;
    status = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info);
    if (status != errSecSuccess) goto finish;
    if (info == NULL || CFGetTypeID(info) != CFDictionaryGetTypeID()) { status = errSecDecode; goto finish; }
    CFTypeRef flagsValue = CFDictionaryGetValue(info, kSecCodeInfoFlags);
    CFTypeRef uniqueValue = CFDictionaryGetValue(info, kSecCodeInfoUnique);
    int64_t flags = 0;
    if (flagsValue == NULL || CFGetTypeID(flagsValue) != CFNumberGetTypeID() || CFNumberIsFloatType((CFNumberRef)flagsValue) ||
        !CFNumberGetValue((CFNumberRef)flagsValue, kCFNumberSInt64Type, &flags) || flags < 0 || flags > UINT32_MAX ||
        (flags & kSecCodeSignatureAdhoc) == 0 || uniqueValue == NULL || CFGetTypeID(uniqueValue) != CFDataGetTypeID() ||
        CFDataGetLength((CFDataRef)uniqueValue) != 20) { status = errSecAuthFailed; goto finish; }
    char text[48] = "cdhash:";
    const uint8_t *bytes = CFDataGetBytePtr((CFDataRef)uniqueValue);
    const char hex[] = "0123456789abcdef";
    for (size_t n = 0; n < 20; ++n) {
        text[7 + 2*n] = hex[bytes[n] >> 4]; text[8 + 2*n] = hex[bytes[n] & 15];
    }
    text[47] = '\0';
    *result = CFStringCreateWithCString(NULL, text, kCFStringEncodingASCII);
    if (*result == NULL) status = errSecAllocate;
finish:
    if (info != NULL) CFRelease(info);
    if (code != NULL) CFRelease(code);
    if (dynamic != NULL) CFRelease(dynamic);
    return status;
}

static OSStatus partitions(CFStringRef description, CFStringRef creator, YueduOwnedKeyACLReport *report) {
    if (description == NULL || CFGetTypeID(description) != CFStringGetTypeID()) return errSecDecode;
    CFIndex size = CFStringGetLength(description);
    if (size < 2 || size > 16384 || size % 2 != 0) return errSecDecode;
    UInt8 bytes[8192];
    for (CFIndex index = 0; index < size; index += 2) {
        unsigned value = 0;
        for (CFIndex digit = 0; digit < 2; ++digit) {
            UniChar character = CFStringGetCharacterAtIndex(description, index + digit);
            unsigned nibble;
            if (character >= '0' && character <= '9') nibble = character - '0';
            else if (character >= 'a' && character <= 'f') nibble = character - 'a' + 10;
            else if (character >= 'A' && character <= 'F') nibble = character - 'A' + 10;
            else return errSecDecode;
            value = (value << 4) | nibble;
        }
        bytes[index / 2] = (UInt8)value;
    }
    CFDataRef data = CFDataCreate(NULL, bytes, size / 2);
    if (data == NULL) return errSecAllocate;
    CFPropertyListRef plist = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL);
    CFRelease(data);
    OSStatus status = errSecDecode;
    if (plist == NULL || CFGetTypeID(plist) != CFDictionaryGetTypeID() || CFDictionaryGetCount(plist) != 1) goto finish;
    CFArrayRef identifiers = (CFArrayRef)CFDictionaryGetValue(plist, CFSTR("Partitions"));
    if (identifiers == NULL || CFGetTypeID(identifiers) != CFArrayGetTypeID() || CFArrayGetCount(identifiers) > 16) goto finish;
    for (CFIndex index = 0; index < CFArrayGetCount(identifiers); ++index) {
        CFStringRef identifier = (CFStringRef)CFArrayGetValueAtIndex(identifiers, index);
        if (CFGetTypeID(identifier) != CFStringGetTypeID() || CFStringGetLength(identifier) < 1 || CFStringGetLength(identifier) > 256) goto finish;
        report->partitionIDCount += 1;
        if (CFEqual(identifier, CFSTR("apple:"))) report->applePartitionCount += 1;
        else if (CFEqual(identifier, CFSTR("apple-tool:"))) report->appleToolPartitionCount += 1;
        else if (CFEqual(identifier, CFSTR("codesign:"))) report->codesignPartitionCount += 1;
        else if (CFEqual(identifier, creator)) report->creatorPartitionCount += 1;
        else report->otherPartitionCount += 1;
    }
    status = errSecSuccess;
finish:
    if (plist != NULL) CFRelease(plist);
    return status;
}

static OSStatus inspectAccess(SecAccessRef access, YueduOwnedKeyACLReport *report, SecACLRef *signACL) {
    CFArrayRef list = NULL;
    SecTrustedApplicationRef creator = NULL;
    CFDataRef creatorPath = NULL;
    CFStringRef creatorID = NULL;
    OSStatus status = SecAccessCopyACLList(access, &list);
    if (status != errSecSuccess) goto finish;
    if (list == NULL || CFGetTypeID(list) != CFArrayGetTypeID() || CFArrayGetCount(list) < 1 || CFArrayGetCount(list) > 32) {
        status = errSecDecode; goto finish;
    }
    status = SecTrustedApplicationCreateFromPath(NULL, &creator);
    if (status != errSecSuccess) goto finish;
    if (creator == NULL) { status = errSecDecode; goto finish; }
    status = SecTrustedApplicationCopyData(creator, &creatorPath);
    if (status != errSecSuccess) goto finish;
    if (creatorPath == NULL || CFDataGetLength(creatorPath) < 1 || CFDataGetLength(creatorPath) > 4096) { status = errSecDecode; goto finish; }
    report->privateKeyCount = 1; report->sameOwnedKeychain = 1;
    report->aclCount = (uint32_t)CFArrayGetCount(list);
    for (CFIndex index = 0; index < CFArrayGetCount(list); ++index) {
        SecACLRef acl = (SecACLRef)CFArrayGetValueAtIndex(list, index);
        CFArrayRef applications = NULL;
        CFStringRef description = NULL;
        SecKeychainPromptSelector prompt = 0;
        if (CFGetTypeID(acl) != SecACLGetTypeID()) { status = errSecDecode; goto finish; }
        /* The newer string-copy API maps unknown numeric authorizations to
         * Any in Apple's implementation. This public C API retains the real
         * bounded tags, so unknown counts cannot silently become Any. */
        CSSM_ACL_AUTHORIZATION_TAG tags[64];
        uint32_t tagCount = 64;
        status = SecACLGetAuthorizations(acl, tags, &tagCount);
        if (status != errSecSuccess) goto finish;
        if (tagCount < 1 || tagCount > 64) { status = errSecDecode; goto finish; }
        Boolean isSign = false, isPartition = false, hasAny = false;
        uint32_t unknownTagCount = 0;
        const CSSM_ACL_AUTHORIZATION_TAG known[] = { CSSM_ACL_AUTHORIZATION_ANY, CSSM_ACL_AUTHORIZATION_LOGIN, CSSM_ACL_AUTHORIZATION_GENKEY,
            CSSM_ACL_AUTHORIZATION_DELETE, CSSM_ACL_AUTHORIZATION_EXPORT_WRAPPED, CSSM_ACL_AUTHORIZATION_EXPORT_CLEAR,
            CSSM_ACL_AUTHORIZATION_IMPORT_WRAPPED, CSSM_ACL_AUTHORIZATION_IMPORT_CLEAR, CSSM_ACL_AUTHORIZATION_SIGN,
            CSSM_ACL_AUTHORIZATION_ENCRYPT, CSSM_ACL_AUTHORIZATION_DECRYPT, CSSM_ACL_AUTHORIZATION_MAC, CSSM_ACL_AUTHORIZATION_DERIVE,
            CSSM_ACL_AUTHORIZATION_CHANGE_ACL, CSSM_ACL_AUTHORIZATION_CHANGE_OWNER, CSSM_ACL_AUTHORIZATION_PARTITION_ID, CSSM_ACL_AUTHORIZATION_INTEGRITY };
        for (uint32_t t = 0; t < tagCount; ++t) {
            CSSM_ACL_AUTHORIZATION_TAG tag = tags[t];
            if (tag == CSSM_ACL_AUTHORIZATION_SIGN) isSign = true;
            if (tag == CSSM_ACL_AUTHORIZATION_PARTITION_ID) isPartition = true;
            if (tag == CSSM_ACL_AUTHORIZATION_ANY) hasAny = true;
            Boolean found = false;
            for (size_t k = 0; k < sizeof(known) / sizeof(*known); ++k) if (tag == known[k]) found = true;
            if (!found) { unknownTagCount += 1; report->unknownAuthorizationCount += 1; }
        }
        /* Appending this subject must not grant every right or an unknown
         * right through a compound target ACL. This is per-entry: unrelated
         * ACL authorizations remain intact and do not veto this known target. */
        if (isSign && (hasAny || unknownTagCount != 0)) { status = errSecAuthFailed; goto finish; }
        if (isPartition && (isSign || tagCount != 1)) { status = errSecDecode; goto finish; }
        Boolean isOwner = false;
        if (tagCount == 1 && tags[0] == CSSM_ACL_AUTHORIZATION_CHANGE_ACL) {
            /* Apple's public implementation rejects an owner before changing
             * tags. Same tags are supplied; success is only an ordinary ACL,
             * never evidence that its subject is the real owner credential. */
            status = SecACLSetAuthorizations(acl, tags, tagCount);
            if (status == errSecInvalidOwnerEdit) { isOwner = true; status = errSecSuccess; }
            else if (status != errSecSuccess) goto finish;
        }
        status = SecACLCopyContents(acl, &applications, &description, &prompt);
        if (status == errSecACLNotSimple && !isSign && !isPartition && !isOwner) {
            report->opaqueACLCount += 1; status = errSecSuccess;
        } else if (status == errSecSuccess) {
            if (description != NULL && CFStringGetLength(description) > 16384) status = errSecDecode;
            if (applications != NULL && (CFGetTypeID(applications) != CFArrayGetTypeID() || CFArrayGetCount(applications) > 16)) status = errSecDecode;
            if (status == errSecSuccess && isPartition) {
                report->partitionACLCount += 1;
                if (creatorID == NULL) status = creatorPartition(&creatorID);
                if (status == errSecSuccess) status = partitions(description, creatorID, report);
            }
            if (status == errSecSuccess && (isSign || isOwner)) {
                if (isSign) report->signACLCount += 1;
                if (isOwner) report->ownerACLCount += 1;
                if (applications == NULL) {
                    if (isSign) report->signAllowAnyACLCount += 1;
                    if (isOwner) report->ownerAllowAnyACLCount += 1;
                }
                else {
                    CFIndex count = CFArrayGetCount(applications);
                    if (isSign) {
                        report->signAppListACLCount += 1;
                        if (count == 0) report->signEmptyACLCount += 1;
                        report->signTrustedApplicationCount += (uint32_t)count;
                    }
                    if (isOwner) report->ownerTrustedApplicationCount += (uint32_t)count;
                    for (CFIndex a = 0; a < count; ++a) {
                        SecTrustedApplicationRef app = (SecTrustedApplicationRef)CFArrayGetValueAtIndex(applications, a);
                        CFDataRef path = NULL;
                        if (CFGetTypeID(app) != SecTrustedApplicationGetTypeID()) { status = errSecDecode; break; }
                        status = SecTrustedApplicationCopyData(app, &path);
                        if (status == errSecSuccess && (path == NULL || CFDataGetLength(path) < 1 || CFDataGetLength(path) > 4096)) status = errSecDecode;
                        const char expected[] = "/usr/bin/codesign";
                        if (status == errSecSuccess && isSign && CFDataGetLength(path) == sizeof(expected) &&
                            memcmp(CFDataGetBytePtr(path), expected, sizeof(expected)) == 0) report->codesignPathEntryCount += 1;
                        if (status == errSecSuccess && isOwner && CFEqual(path, creatorPath)) report->creatorOwnerPathEntryCount += 1;
                        if (path != NULL) CFRelease(path);
                        if (status != errSecSuccess) break;
                    }
                }
                if (status == errSecSuccess && isSign && signACL != NULL && *signACL == NULL) { CFRetain(acl); *signACL = acl; }
            }
        }
        if (applications != NULL) CFRelease(applications);
        if (description != NULL) CFRelease(description);
        if (status != errSecSuccess) goto finish;
    }
    status = errSecSuccess;
finish:
    if (list != NULL) CFRelease(list);
    if (creator != NULL) CFRelease(creator);
    if (creatorPath != NULL) CFRelease(creatorPath);
    if (creatorID != NULL) CFRelease(creatorID);
    return status;
}

OSStatus YueduOwnedAccessAuthorizeCreator(SecAccessRef access) {
    if (access == NULL || CFGetTypeID(access) != SecAccessGetTypeID()) return errSecParam;
    CFArrayRef list = NULL, applications = NULL;
    CFMutableArrayRef extended = NULL;
    CFStringRef description = NULL;
    SecACLRef owner = NULL;
    SecTrustedApplicationRef creator = NULL;
    SecKeychainPromptSelector prompt = 0;
    OSStatus status = SecAccessCopyACLList(access, &list);
    if (status != errSecSuccess) goto finish;
    if (list == NULL || CFGetTypeID(list) != CFArrayGetTypeID() || CFArrayGetCount(list) < 1 || CFArrayGetCount(list) > 32) { status = errSecDecode; goto finish; }
    for (CFIndex index = 0; index < CFArrayGetCount(list); ++index) {
        SecACLRef acl = (SecACLRef)CFArrayGetValueAtIndex(list, index);
        if (CFGetTypeID(acl) != SecACLGetTypeID()) { status = errSecDecode; goto finish; }
        CSSM_ACL_AUTHORIZATION_TAG tags[64]; uint32_t count = 64;
        status = SecACLGetAuthorizations(acl, tags, &count);
        if (status != errSecSuccess) goto finish;
        if (count < 1 || count > 64) { status = errSecDecode; goto finish; }
        if (count != 1 || tags[0] != CSSM_ACL_AUTHORIZATION_CHANGE_ACL) continue;
        status = SecACLSetAuthorizations(acl, tags, count);
        if (status == errSecSuccess) continue; /* unchanged ordinary tags, not owner */
        if (status != errSecInvalidOwnerEdit) goto finish;
        if (owner != NULL) { status = errSecDecode; goto finish; }
        CFRetain(acl); owner = acl;
    }
    if (owner == NULL) { status = errSecInvalidOwnerEdit; goto finish; }
    status = SecACLCopyContents(owner, &applications, &description, &prompt);
    if (status != errSecSuccess) goto finish;
    if (applications == NULL || CFGetTypeID(applications) != CFArrayGetTypeID() || CFArrayGetCount(applications) >= 16 ||
        description == NULL || CFGetTypeID(description) != CFStringGetTypeID() || CFStringGetLength(description) > 16384) {
        status = errSecDecode; goto finish;
    }
    /* Only this fresh SecAccess object, before its one PKCS12 import. Original
     * subjects and prompt survive; creator receives the owner right explicitly
     * so the later public SetAccess need not invent passphrase credentials or
     * use the private SetAccessWithPassword entry point. */
    extended = CFArrayCreateMutableCopy(NULL, 0, applications);
    if (extended == NULL) { status = errSecAllocate; goto finish; }
    status = SecTrustedApplicationCreateFromPath(NULL, &creator);
    if (status != errSecSuccess) goto finish;
    if (creator == NULL) { status = errSecDecode; goto finish; }
    CFArrayAppendValue(extended, creator);
    status = SecACLSetContents(owner, extended, description, prompt);
finish:
    if (list != NULL) CFRelease(list);
    if (owner != NULL) CFRelease(owner);
    if (applications != NULL) CFRelease(applications);
    if (extended != NULL) CFRelease(extended);
    if (description != NULL) CFRelease(description);
    if (creator != NULL) CFRelease(creator);
    return status;
}

OSStatus YueduOwnedKeyACLInspect(SecKeychainRef keychain, SecKeyRef privateKey,
                               uint32_t appendCurrentCodesign,
                               YueduOwnedKeyACLReport *before, YueduOwnedKeyACLReport *after,
                               uint32_t *classicChanged) {
    if (before == NULL || after == NULL || classicChanged == NULL) return errSecParam;
    memset(before, 0, sizeof(*before)); memset(after, 0, sizeof(*after)); *classicChanged = false;
    if (appendCurrentCodesign > 1) return errSecParam;
    YueduOwnedKeyACLReport initial = {0}, final = {0};
    SecAccessRef access = NULL, persisted = NULL;
    SecACLRef signACL = NULL;
    CFArrayRef applications = NULL;
    CFMutableArrayRef extended = NULL;
    CFStringRef description = NULL;
    SecTrustedApplicationRef codesign = NULL;
    SecKeychainPromptSelector prompt = 0;
    OSStatus status = ownedKey(keychain, privateKey);
    if (status != errSecSuccess) goto finish;
    status = SecKeychainItemCopyAccess((SecKeychainItemRef)privateKey, &access);
    if (status != errSecSuccess) goto finish;
    if (access == NULL) { status = errSecNoAccessForItem; goto finish; }
    status = inspectAccess(access, &initial, &signACL);
    if (status != errSecSuccess) goto finish;
    if (initial.ownerACLCount != 1 || initial.ownerAllowAnyACLCount != 0 ||
        initial.ownerTrustedApplicationCount < 1 || initial.ownerTrustedApplicationCount > 16 ||
        initial.creatorOwnerPathEntryCount != 1) { status = errSecInvalidOwnerEdit; goto finish; }
    if (appendCurrentCodesign) {
        /* Exactly one known, nonempty finite application list, never ANY or a
         * reconstructed ACL. Preserve all old subjects/authorizations/prompt
         * and all unrelated entries. The path is not a reason to skip writing
         * a fresh actual codesign subject from the running platform. */
        if (initial.signACLCount != 1 || initial.signAppListACLCount != 1 ||
            initial.signAllowAnyACLCount != 0 || initial.signEmptyACLCount != 0 ||
            initial.signTrustedApplicationCount >= 16 || signACL == NULL) { status = errSecAuthFailed; goto finish; }
        status = SecACLCopyContents(signACL, &applications, &description, &prompt);
        if (status != errSecSuccess) goto finish;
        if (applications == NULL || description == NULL) { status = errSecDecode; goto finish; }
        extended = CFArrayCreateMutableCopy(NULL, 0, applications);
        if (extended == NULL) { status = errSecAllocate; goto finish; }
        status = SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &codesign);
        if (status != errSecSuccess) goto finish;
        if (codesign == NULL) { status = errSecInternalComponent; goto finish; }
        CFArrayAppendValue(extended, codesign);
        status = SecACLSetContents(signACL, extended, description, prompt);
        if (status != errSecSuccess) goto finish;
        status = SecKeychainItemSetAccess((SecKeychainItemRef)privateKey, access);
        if (status != errSecSuccess) goto finish;
        status = SecKeychainItemCopyAccess((SecKeychainItemRef)privateKey, &persisted);
        if (status != errSecSuccess) goto finish;
        if (persisted == NULL) { status = errSecNoAccessForItem; goto finish; }
        status = inspectAccess(persisted, &final, NULL);
        if (status != errSecSuccess) goto finish;
        YueduOwnedKeyACLReport normalized = final;
        if (normalized.signTrustedApplicationCount == 0 || normalized.codesignPathEntryCount == 0) { status = errSecDecode; goto finish; }
        normalized.signTrustedApplicationCount -= 1; normalized.codesignPathEntryCount -= 1;
        if (memcmp(&initial, &normalized, sizeof(initial)) != 0) { status = errSecDecode; goto finish; }
    } else final = initial;
    *before = initial; *after = final; *classicChanged = appendCurrentCodesign;
finish:
    if (access != NULL) CFRelease(access);
    if (persisted != NULL) CFRelease(persisted);
    if (signACL != NULL) CFRelease(signACL);
    if (applications != NULL) CFRelease(applications);
    if (extended != NULL) CFRelease(extended);
    if (description != NULL) CFRelease(description);
    if (codesign != NULL) CFRelease(codesign);
    return status;
}

OSStatus YueduOwnedKeyCreatePartition(SecKeychainRef keychain, SecKeyRef privateKey,
                                     const uint8_t *password, uint32_t passwordLength,
                                     YueduOwnedKeyACLReport *before,
                                     YueduOwnedKeyACLReport *after) {
    if (before == NULL || after == NULL || before == after) return errSecParam;
    memset(before, 0, sizeof(*before)); memset(after, 0, sizeof(*after));
    if (password == NULL || passwordLength < 1 || passwordLength > 256) return errSecParam;
    uint8_t passwordCopy[256] = {0};
    SecAccessRef original = NULL, persisted = NULL;
    CFStringRef creatorID = NULL;
    CFArrayRef identifiers = NULL;
    CFDictionaryRef dictionary = NULL;
    CFDataRef payload = NULL;
    YueduOwnedKeyACLReport initial = {0}, final = {0};
    const CSSM_KEY *borrowedKey = NULL;
    CSSM_CSP_HANDLE csp = 0;
    OSStatus status = ownedKey(keychain, privateKey);
    if (status != errSecSuccess) goto finish;
    status = creatorPartition(&creatorID);
    if (status != errSecSuccess) goto finish;
    status = SecKeychainItemCopyAccess((SecKeychainItemRef)privateKey, &original);
    if (status != errSecSuccess) goto finish;
    if (original == NULL) { status = errSecNoAccessForItem; goto finish; }
    status = inspectAccess(original, &initial, NULL);
    if (status != errSecSuccess) goto finish;
    /* Only add a genuinely absent partition, never replace/guess an existing
     * entry or manufacture a simple ANY ACL carrying a partition tag. */
    if (initial.aclCount >= 32 || initial.partitionACLCount != 0 || initial.partitionIDCount != 0 ||
        initial.ownerACLCount != 1 || initial.ownerAllowAnyACLCount != 0 || initial.creatorOwnerPathEntryCount != 1 ||
        initial.signACLCount != 1 || initial.signAppListACLCount != 1 || initial.signAllowAnyACLCount != 0 ||
        initial.signEmptyACLCount != 0 || initial.codesignPathEntryCount < 1) { status = errSecAuthFailed; goto finish; }
    status = SecKeyGetCSSMKey(privateKey, &borrowedKey);
    if (status != errSecSuccess) goto finish;
    if (borrowedKey == NULL || borrowedKey->KeyHeader.BlobType != CSSM_KEYBLOB_REFERENCE ||
        borrowedKey->KeyHeader.KeyClass != CSSM_KEYCLASS_PRIVATE_KEY ||
        (borrowedKey->KeyHeader.KeyUsage & CSSM_KEYUSE_SIGN) == 0) { status = errSecInvalidKeyRef; goto finish; }
    /* The public API borrows this opaque reference until privateKey is
     * released. Its KeyData is never inspected, copied, serialized or freed. */
    status = SecKeyGetCSPHandle(privateKey, &csp);
    if (status != errSecSuccess) goto finish;
    if (csp == 0) { status = errSecInvalidKeyRef; goto finish; }
    const void *parts[] = { CFSTR("apple-tool:"), CFSTR("apple:"), CFSTR("codesign:"), creatorID };
    identifiers = CFArrayCreate(NULL, parts, 4, &kCFTypeArrayCallBacks);
    if (identifiers == NULL) { status = errSecAllocate; goto finish; }
    const void *keys[] = { CFSTR("Partitions") }, *values[] = { identifiers };
    dictionary = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (dictionary == NULL) { status = errSecAllocate; goto finish; }
    payload = CFPropertyListCreateData(NULL, dictionary, kCFPropertyListBinaryFormat_v1_0, 0, NULL);
    if (payload == NULL || CFDataGetLength(payload) < 1 || CFDataGetLength(payload) > 8192) { status = errSecDecode; goto finish; }

    /* Real partition subject: a two-element typed list, not an ANY subject
     * with changed authorizations. This matches PartitionAclSubject::Maker. */
    CSSM_LIST_ELEMENT partitionType = {0}, partitionData = {0};
    partitionType.ElementType = CSSM_LIST_ELEMENT_WORDID;
    partitionType.WordID = CSSM_ACL_SUBJECT_TYPE_PARTITION;
    partitionType.NextElement = &partitionData;
    partitionData.ElementType = CSSM_LIST_ELEMENT_DATUM;
    partitionData.Element.Word.Length = (CSSM_SIZE)CFDataGetLength(payload);
    partitionData.Element.Word.Data = (uint8_t *)CFDataGetBytePtr(payload);
    CSSM_ACL_AUTHORIZATION_TAG authorization = CSSM_ACL_AUTHORIZATION_PARTITION_ID;
    CSSM_ACL_ENTRY_INPUT entry = {0};
    entry.Prototype.TypedSubject.ListType = CSSM_LIST_TYPE_SEXPR;
    entry.Prototype.TypedSubject.Head = &partitionType; entry.Prototype.TypedSubject.Tail = &partitionData;
    entry.Prototype.Authorization.NumberOfAuthTags = 1; entry.Prototype.Authorization.AuthTags = &authorization;
    memcpy(entry.Prototype.EntryTag, CSSM_APPLE_ACL_TAG_PARTITION_ID, sizeof(CSSM_APPLE_ACL_TAG_PARTITION_ID));
    CSSM_ACL_EDIT edit = {0};
    edit.EditMode = CSSM_ACL_EDIT_MODE_ADD; edit.NewEntry = &entry;

    /* Public CSSM password sample. No UI callback, no raw credential output.
     * The server checks this actual database password before allowing the
     * protected partition ADD. All structures live only across the call. */
    memcpy(passwordCopy, password, passwordLength);
    CSSM_LIST_ELEMENT lockType = {0}, passwordType = {0}, passwordData = {0};
    lockType.ElementType = CSSM_LIST_ELEMENT_WORDID; lockType.WordID = CSSM_SAMPLE_TYPE_KEYCHAIN_LOCK;
    lockType.NextElement = &passwordType;
    passwordType.ElementType = CSSM_LIST_ELEMENT_WORDID; passwordType.WordID = CSSM_SAMPLE_TYPE_PASSWORD;
    passwordType.NextElement = &passwordData;
    passwordData.ElementType = CSSM_LIST_ELEMENT_DATUM;
    passwordData.Element.Word.Length = passwordLength; passwordData.Element.Word.Data = passwordCopy;
    CSSM_SAMPLE sample = {0};
    sample.TypedSample.ListType = CSSM_LIST_TYPE_SEXPR;
    sample.TypedSample.Head = &lockType; sample.TypedSample.Tail = &passwordData;
    CSSM_ACCESS_CREDENTIALS credentials = {0};
    credentials.Samples.NumberOfSamples = 1; credentials.Samples.Samples = &sample;
    status = CSSM_ChangeKeyAcl(csp, &credentials, &edit, borrowedKey);
    if (status != errSecSuccess) goto finish;

    status = SecKeychainItemCopyAccess((SecKeychainItemRef)privateKey, &persisted);
    if (status != errSecSuccess) goto finish;
    if (persisted == NULL) { status = errSecNoAccessForItem; goto finish; }
    status = inspectAccess(persisted, &final, NULL);
    if (status != errSecSuccess) goto finish;
    if (final.partitionACLCount != 1 || final.partitionIDCount != 4 || final.applePartitionCount != 1 ||
        final.appleToolPartitionCount != 1 || final.codesignPartitionCount != 1 || final.creatorPartitionCount != 1 ||
        final.otherPartitionCount != 0 || final.aclCount != initial.aclCount + 1) { status = errSecDecode; goto finish; }
    YueduOwnedKeyACLReport normalized = final;
    normalized.aclCount -= 1; normalized.partitionACLCount -= 1; normalized.partitionIDCount -= 4;
    normalized.applePartitionCount -= 1; normalized.appleToolPartitionCount -= 1;
    normalized.codesignPartitionCount -= 1; normalized.creatorPartitionCount -= 1;
    if (memcmp(&initial, &normalized, sizeof(initial)) != 0) { status = errSecDecode; goto finish; }
    *before = initial; *after = final;
finish:
    /* Volatile writes keep the local password copy's erasure observable to
     * the abstract machine. Never clear or free the caller's borrowed input. */
    for (size_t n = 0; n < sizeof(passwordCopy); ++n) ((volatile uint8_t *)passwordCopy)[n] = 0;
    if (original != NULL) CFRelease(original);
    if (persisted != NULL) CFRelease(persisted);
    if (creatorID != NULL) CFRelease(creatorID);
    if (identifiers != NULL) CFRelease(identifiers);
    if (dictionary != NULL) CFRelease(dictionary);
    if (payload != NULL) CFRelease(payload);
    return status;
}
