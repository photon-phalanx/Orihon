// Read the visible screen after tapping Back. Runs on the Mac hosting the simulator.
import Foundation
import Vision

let request = VNRecognizeTextRequest()
request.recognitionLanguages = ["zh-Hans", "en-US"]
let screenshot = URL(fileURLWithPath: CommandLine.arguments[1])
try VNImageRequestHandler(url: screenshot).perform([request])
for observation in request.results ?? [] {
    if let text = observation.topCandidates(1).first?.string {
        print(text)
    }
}
