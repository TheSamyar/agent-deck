#ifndef AGENT_DECK_MASTERHUB_USB_H
#define AGENT_DECK_MASTERHUB_USB_H
#include <stdint.h>
/// Standard HID SET_IDLE(0) for the connected MasterHUB rollers/small dials only.
/// Returns 0 on success; never resets devices or writes firmware.
int DeckMasterHUBEnableInput(uint64_t registryID);
#endif
