// CFPlugin factory boilerplate for the threemf Spotlight Importer.
//
// macOS loads .mdimporter bundles by calling MetadataImporterPluginFactory(),
// which returns an IUnknown-style object whose vtable contains GetMetadataForFile.
// Apple's Xcode template generated this file historically; Xcode 16 dropped it,
// so we keep our own copy. The factory UUID below must match Info.plist's
// CFPlugInFactories key.

#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreServices/CoreServices.h>
#include <stdatomic.h>

// Factory UUID. Must match Info.plist's CFPlugInFactories key.
#define PLUGIN_ID "BAD2CD2F-A277-418E-AE96-DC531D69FB35"

// Forward declaration — implemented in GetMetadataForFile.c (which bridges to Swift).
Boolean GetMetadataForFile(void *thisInterface,
                           CFMutableDictionaryRef attributes,
                           CFStringRef contentTypeUTI,
                           CFStringRef pathToFile);

typedef struct __MetadataImporterPlugin {
    MDImporterInterfaceStruct *conduitInterface;
    CFUUIDRef factoryID;
    // Atomic refcount: mdworker is multi-threaded and may call AddRef/Release
    // concurrently across plugin instances. Plain `+= 1` would race.
    atomic_uint refCount;
} MetadataImporterPlugin;

static MetadataImporterPlugin *AllocPlugin(CFUUIDRef factoryID);
static void DeallocPlugin(MetadataImporterPlugin *self);
static HRESULT QueryInterface(void *self, REFIID iid, LPVOID *ppv);
static ULONG AddRef(void *self);
static ULONG Release(void *self);

// Static vtable shared by all plugin instances.
static MDImporterInterfaceStruct sInterfaceFtbl = {
    NULL,
    QueryInterface,
    AddRef,
    Release,
    GetMetadataForFile
};

static MetadataImporterPlugin *AllocPlugin(CFUUIDRef factoryID) {
    MetadataImporterPlugin *plugin = (MetadataImporterPlugin *)malloc(sizeof(MetadataImporterPlugin));
    if (!plugin) return NULL;
    memset(plugin, 0, sizeof(MetadataImporterPlugin));
    plugin->conduitInterface = &sInterfaceFtbl;
    plugin->factoryID = (CFUUIDRef)CFRetain(factoryID);
    CFPlugInAddInstanceForFactory(factoryID);
    atomic_init(&plugin->refCount, 1);
    return plugin;
}

static void DeallocPlugin(MetadataImporterPlugin *self) {
    CFUUIDRef factoryID = self->factoryID;
    free(self);
    if (factoryID) {
        CFPlugInRemoveInstanceForFactory(factoryID);
        CFRelease(factoryID);
    }
}

static HRESULT QueryInterface(void *self, REFIID iid, LPVOID *ppv) {
    CFUUIDRef interfaceID = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, iid);
    if (CFEqual(interfaceID, kMDImporterInterfaceID) ||
        CFEqual(interfaceID, IUnknownUUID)) {
        ((MetadataImporterPlugin *)self)->conduitInterface->AddRef(self);
        *ppv = self;
        CFRelease(interfaceID);
        return S_OK;
    }
    CFRelease(interfaceID);
    *ppv = NULL;
    return E_NOINTERFACE;
}

static ULONG AddRef(void *self) {
    MetadataImporterPlugin *plugin = (MetadataImporterPlugin *)self;
    // fetch_add returns the previous value; new count is +1.
    return (ULONG)(atomic_fetch_add(&plugin->refCount, 1) + 1);
}

static ULONG Release(void *self) {
    MetadataImporterPlugin *plugin = (MetadataImporterPlugin *)self;
    unsigned previous = atomic_fetch_sub(&plugin->refCount, 1);
    if (previous == 1) {
        DeallocPlugin(plugin);
        return 0;
    }
    return (ULONG)(previous - 1);
}

// Exported factory entry. Spotlight (mdworker) calls this when loading the bundle.
void *MetadataImporterPluginFactory(CFAllocatorRef allocator, CFUUIDRef typeID) {
    (void)allocator;
    if (CFEqual(typeID, kMDImporterTypeID)) {
        CFUUIDRef uuid = CFUUIDCreateFromString(kCFAllocatorDefault, CFSTR(PLUGIN_ID));
        MetadataImporterPlugin *plugin = AllocPlugin(uuid);
        CFRelease(uuid);
        return plugin;
    }
    return NULL;
}
