# Agent Deck 0.3.7 preview — build 13

Fixes service recovery after a private update replaces the running helper binary.
The updater verifies the owned launchd job, exact installed helper path, PID, and
process birth before restarting; pending approvals and managed work still defer
recovery. This covers the macOS case where a replaced running executable no longer
has a readable process path.

Supervised process output and exit waits now use dedicated blocking-I/O workers,
keeping Swift's cooperative executor available for HTTP and state updates. A
six-agent fixture exercises simultaneous stderr backpressure and denied requests.

Build 12 hands-on checks recorded all 31 inputs, USB reconnect, user-confirmed
sleep/wake recovery, and volume changes. Those observations apply to build 12;
build 13's source tests do not automatically recertify physical behavior. The
300-second build 12 CPU result was 15.39% of one core, just above the 15% target.

Requires macOS 14+. Physical acceptance, automatic update relaunch, accessibility,
and additional Mac models require separate observed evidence.
