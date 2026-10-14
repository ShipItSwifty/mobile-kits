import Testing

@testable import MobileDevices

@Suite("PhysicalIOSDeviceManager")
struct PhysicalIOSDeviceManagerTests {
    @Test("Parses devicectl devices and drops simulators listed by newer Xcode")
    func parsesDevices() {
        let devices = PhysicalIOSDeviceManager.parseDevices(
            """
            {"result": {"devices": [
              {"identifier": "CD-1",
               "connectionProperties": {"tunnelState": "connected", "transportType": "wired"},
               "deviceProperties": {"name": "Phone", "osVersionNumber": "18.0", "developerModeStatus": "enabled"},
               "hardwareProperties": {"udid": "00008130-AAA", "platform": "iOS", "marketingName": "iPhone 15 Pro", "reality": "physical"}},
              {"identifier": "CD-2",
               "connectionProperties": {"tunnelState": "disconnected"},
               "deviceProperties": {"name": "Watch"},
               "hardwareProperties": {"udid": "W", "platform": "watchOS"}},
              {"identifier": "CD-3",
               "connectionProperties": {"tunnelState": "connected"},
               "deviceProperties": {"name": "iPhone 16"},
               "hardwareProperties": {"udid": "SIM", "platform": "iOS", "reality": "simulated"}}
            ]}}
            """)
        #expect(devices.map(\.udid) == ["00008130-AAA", "W"])
        #expect(devices[0].isConnected)
        #expect(devices[0].developerModeEnabled == true)
        #expect(devices[0].model == "iPhone 15 Pro")
        #expect(devices[1].isConnected == false)
        #expect(devices[1].platform == "watchOS")
    }

    @Test("Finds a running app's pid by its .app executable path")
    func processID() {
        let json = """
            {"result": {"runningProcesses": [
              {"processIdentifier": 1, "executable": "file:///usr/libexec/backboardd"},
              {"processIdentifier": 812, "executable": "file:///private/var/containers/Bundle/Application/X/Jot.app/Jot"}
            ]}}
            """
        #expect(PhysicalIOSDeviceManager.processID(inProcessList: json, bundleID: "com.example.Jot") == 812)
        #expect(PhysicalIOSDeviceManager.processID(inProcessList: json, bundleID: "com.example.Other") == nil)
    }
}
