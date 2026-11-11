#import "MasterHUBUSB.h"
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>

// Independent implementation of USB HID SET_IDLE. Windows normally sends this
// during attachment; affected MasterHUB M0 firmware stays silent without it.
int DeckMasterHUBEnableInput(uint64_t registryID) {
  @autoreleasepool {
    io_service_t entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID));
    if (!entry) return 1;
    for (int depth = 0; depth < 12 && !IOObjectConformsTo(entry, "IOUSBHostDevice"); depth++) {
      io_registry_entry_t parent = IO_OBJECT_NULL;
      kern_return_t result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent);
      IOObjectRelease(entry);
      entry = result == KERN_SUCCESS ? parent : IO_OBJECT_NULL;
      if (!entry) return 2;
    }
    if (!IOObjectConformsTo(entry, "IOUSBHostDevice")) { IOObjectRelease(entry); return 2; }
    NSNumber *vendor = CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, CFSTR("idVendor"), kCFAllocatorDefault, 0));
    NSNumber *product = CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, CFSTR("idProduct"), kCFAllocatorDefault, 0));
    if (![vendor isKindOfClass:NSNumber.class] || ![product isKindOfClass:NSNumber.class] ||
        vendor.unsignedIntValue != 0x2516 || (product.unsignedIntValue != 0x0204 && product.unsignedIntValue != 0x0202)) {
      IOObjectRelease(entry); return 5;
    }
    NSError *error = nil;
    IOUSBHostDevice *device = [[IOUSBHostDevice alloc] initWithIOService:entry options:IOUSBHostObjectInitOptionsNone queue:nil error:&error interestHandler:nil];
    IOObjectRelease(entry);
    if (!device) return 3;
    IOUSBDeviceRequest request = {.bmRequestType = 0x21, .bRequest = 0x0A, .wValue = 0, .wIndex = 0, .wLength = 0};
    BOOL success = [device sendDeviceRequest:request error:&error];
    [device destroy];
    return success ? 0 : 4;
  }
}
