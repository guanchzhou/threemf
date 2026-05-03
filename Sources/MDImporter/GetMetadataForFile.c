// Spotlight entry point. Called once per indexed file by mdworker.
// We delegate to a Swift implementation that uses our shared parsers.

#include <CoreFoundation/CoreFoundation.h>

// Implemented in MetadataImporterBridge.swift via @_cdecl.
extern Boolean ThreeMFExtractMetadata(CFMutableDictionaryRef attributes,
                                      CFStringRef contentTypeUTI,
                                      CFStringRef pathToFile);

Boolean GetMetadataForFile(void *thisInterface,
                           CFMutableDictionaryRef attributes,
                           CFStringRef contentTypeUTI,
                           CFStringRef pathToFile) {
    (void)thisInterface;
    if (!attributes || !pathToFile) return FALSE;
    return ThreeMFExtractMetadata(attributes, contentTypeUTI, pathToFile);
}
