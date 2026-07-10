import AppKit

if CommandLine.arguments.count >= 3,
   CommandLine.arguments[1] == "--hid-probe" || CommandLine.arguments[1] == "--hid-probe-file" {
    let resultPath: String?
    if let index = CommandLine.arguments.firstIndex(of: "--result"),
       CommandLine.arguments.indices.contains(index + 1) {
        resultPath = CommandLine.arguments[index + 1]
    } else {
        resultPath = nil
    }
    if CommandLine.arguments[1] == "--hid-probe-file" {
        HIDIntegrationProbe.run(fixturePath: CommandLine.arguments[2], resultPath: resultPath)
    } else {
        HIDIntegrationProbe.run(scenarioName: CommandLine.arguments[2], resultPath: resultPath)
    }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
