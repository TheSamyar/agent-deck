import AVFoundation
import Speech
import Foundation

/// Exercises local synthesis and on-device recognition. This is NOT an acoustic
/// microphone/echo test: its report deliberately distinguishes fixture coverage.
@MainActor enum RobinAudioDiagnostic {
  static func runFixture() async throws -> [String:Any] {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("robin-audio-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    defer {try? FileManager.default.removeItem(at:root)}
    let url=root.appendingPathComponent("fixture.caf")
    let synth=AVSpeechSynthesizer(),start=Date()
    var file:AVAudioFile?
    try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
      var finished=false
      let deadline=Task { @MainActor in
        do {try await Task.sleep(for:.seconds(30))} catch {return}
        guard !finished else {return};finished=true;file=nil;synth.stopSpeaking(at:.immediate)
        continuation.resume(throwing:NSError(domain:"RobinAudioDiagnostic",code:3,userInfo:[NSLocalizedDescriptionKey:"Local synthesis timed out after 30 seconds"]))
      }
      synth.write(AVSpeechUtterance(string:"Alfred please review my current project")) { buffer in
        guard let pcm=buffer as? AVAudioPCMBuffer else {return}
        Task { @MainActor in
        guard !finished else {return}
        do {
          if pcm.frameLength == 0 { finished=true;deadline.cancel();file=nil;continuation.resume();return }
          if file == nil {file=try AVAudioFile(forWriting:url,settings:pcm.format.settings)}
          try file?.write(from:pcm)
        } catch {finished=true;deadline.cancel();continuation.resume(throwing:error)}
        }
      }
    }
    let synthesized=Date().timeIntervalSince(start)
    guard let recognizer=SFSpeechRecognizer(),recognizer.supportsOnDeviceRecognition else {throw NSError(domain:"RobinAudioDiagnostic",code:1,userInfo:[NSLocalizedDescriptionKey:"On-device recognition unavailable"])}
    let request=SFSpeechURLRecognitionRequest(url:url);request.requiresOnDeviceRecognition=true
    var recognition:SFSpeechRecognitionTask?
    let recognized:String = try await withCheckedThrowingContinuation { continuation in
      var finished=false
      let deadline=Task { @MainActor in
        do {try await Task.sleep(for:.seconds(30))} catch {return}
        guard !finished else {return};finished=true;recognition?.cancel()
        continuation.resume(throwing:NSError(domain:"RobinAudioDiagnostic",code:4,userInfo:[NSLocalizedDescriptionKey:"On-device recognition timed out after 30 seconds"]))
      }
      recognition=recognizer.recognitionTask(with:request) {result,error in
        Task { @MainActor in
        guard !finished else {return}
        if let error {finished=true;deadline.cancel();continuation.resume(throwing:error)}
        else if let result,result.isFinal {finished=true;deadline.cancel();continuation.resume(returning:result.bestTranscription.formattedString)}
        }
      }
    }
    recognition?.cancel()
    let valid=recognized.lowercased().contains("review") && recognized.lowercased().contains("project")
    guard valid else {throw NSError(domain:"RobinAudioDiagnostic",code:2,userInfo:[NSLocalizedDescriptionKey:"Local audio fixture recognition did not retain task words"])}
    return ["fixtureRecognitionPassed":true,"synthesisMilliseconds":synthesized*1000,"totalMilliseconds":Date().timeIntervalSince(start)*1000,"acousticMicrophoneTested":false,"echoTested":false,"bargeInLatencyMeasured":false]
  }
}
