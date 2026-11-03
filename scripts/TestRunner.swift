// Runs the Swift Testing tests in the SwiftPM test bundle. Needed only with the Command Line
// Tools (no Xcode), where `swift test` builds the tests but never runs them.
import Foundation
import Testing

@main struct TestRunner {
    static func main() async {
        let bundle = CommandLine.arguments[1]
        guard dlopen(bundle, RTLD_NOW) != nil else {
            FileHandle.standardError.write("dlopen failed: \(String(cString: dlerror()))\n".data(using: .utf8)!)
            exit(2)
        }
        exit(await Testing.__swiftPMEntryPoint())
    }
}
