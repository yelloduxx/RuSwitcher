public enum RuntimePreferencesDomain {
    public static let hidProbeSuiteName = "com.ruswitcher.hidhost"
    public static let hidMonitorSuiteName = "com.ruswitcher.hidmonitor"

    public static func isolatedSuiteName(arguments: [String]) -> String? {
        if arguments.contains("--hid-monitor") {
            return hidMonitorSuiteName
        }
        let probeArguments = Set([
            "--hid-probe",
            "--hid-probe-file",
            "--hid-transport-probe",
            "--hid-transport-probe-file",
        ])
        guard arguments.contains(where: probeArguments.contains),
              !arguments.contains("--hid-use-standard-preferences") else { return nil }
        return hidProbeSuiteName
    }
}
