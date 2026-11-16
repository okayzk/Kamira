// Minimal test runner for the non-UI logic, one group per source folder (TestSupport.swift
// has the shared helpers). Run with scripts/test.sh.
import Foundation

// Started by testApp() as a stand-in helper: it waits for ParentWatch to end it.
if CommandLine.arguments.contains("--parent-watch-probe") {
    ParentWatch.start()
    dispatchMain()
}

testShared()
testScreenshot()
testEditor()
testRecording()
testScrollCapture()
testTextRecognition()
testApp()

print(failures == 0 ? "All tests passed." : "\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
