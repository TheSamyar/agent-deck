# Credits and third-party notices

Agent Deck is MIT licensed; see LICENSE. Third-party components retain their own licenses.

- Sparkle provides the Mac update framework: https://github.com/sparkle-project/Sparkle
  Its complete license and bundled component notices are in docs/licenses/Sparkle.txt.
  The Mac app ships these notices in Contents/Resources/Licenses.
- SQLite provides local storage: https://sqlite.org
- Optional Local speech uses Kokoro-82M (Apache-2.0) and kokoro-onnx (MIT):
  https://huggingface.co/hexgrad/Kokoro-82M and https://github.com/thewh1teagle/kokoro-onnx
  The installer downloads the model and an isolated Python runtime separately;
  model weights and third-party Python libraries are not bundled in the Mac app.
  Runtime dependencies, including ONNX Runtime and phonemizer/espeak-ng, retain
  their own licenses in that environment's package metadata.
- MasterHUB protocol research informed the independent native implementation:
  https://github.com/goniszewski/OpenStreamHub and https://github.com/Przemotar/hubdeck
- HubDeck documented the standard HID SET_IDLE startup requirement for silent Mac rollers:
  https://github.com/Przemotar/hubdeck/blob/main/crates/mh-device/src/recover.rs
- cooltek-sdk (https://github.com/projectzero7/cooltek-sdk) is credited for MasterHUB protocol reference. Its license must be confirmed before any code is reused or redistributed; none is included.

Cooler Master, MasterHUB, Spotify, and agent/application names belong to their respective
owners. This is an independent project, not an official Cooler Master or Spotify product.
Vendor SDK components are not included in the MasterHUB preview package.
