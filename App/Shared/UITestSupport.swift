import Foundation
import SihemaCore

/// Launch switches used by the automated screenshot tests.
///   -UITestDirect          open a sample program in a plain window instead of the document browser
///   -UITestTab <name>      start on a tab: code, path, compare or report
///   -UITestSimulate        run the material removal automatically on the report tab
enum UITestSupport {
    static let arguments = ProcessInfo.processInfo.arguments

    static var isDirect: Bool { arguments.contains("-UITestDirect") }
    static var simulate: Bool { arguments.contains("-UITestSimulate") }
    static var tab: String? {
        guard let index = arguments.firstIndex(of: "-UITestTab"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

/// Machine settings used until the app has a machine profile screen.
enum AppDefaults {
    static let machine: MachineConfig = {
        var config = MachineConfig()
        // cutter radii in mm for D1 and D2, standing in for a tool table
        config.cutterRadii = [1: 3.0, 2: 5.0]
        return config
    }()
}

enum DemoPrograms {
    /// A pocket with a WHILE loop, a profile with cutter compensation, and a subprogram call.
    static let main = """
    %
    O1000 (SIHEMA DEMO - POCKET AND PROFILE)
    N10 G21 G90 G17 G94 G40 G49 G80
    N20 T1 M6 (10 MM END MILL)
    N30 G54 S8000 M3
    N40 G00 X-10 Y-10
    N50 G43 H1 Z5. M8
    #100 = 12 (POCKET DEPTH)
    #101 = 0
    WHILE [#101 LT 3] DO1
    #101 = [#101 + 1]
    G00 X10 Y10
    G01 Z[0 - #100 * #101 / 4] F300
    G01 X50 F900
    G03 X60 Y20 I0 J10
    G01 Y40
    G02 X50 Y50 I-10 J0
    G01 X10
    G01 Y10
    END1
    G00 Z5.
    G00 X0 Y-10
    G01 Z-5 F200
    G41 D1 G01 X0 Y0 F600
    G01 Y60
    G01 X80
    G01 Y0
    G01 X0
    G40 G01 X-10 Y-10
    G00 Z50. M9
    M98 P2000
    M30
    O2000 (SUB: MARK THE LOWER LEFT CORNER)
    G00 X5 Y5
    G01 Z-1 F150
    G00 Z5
    M99
    %

    """

    /// The same program edited: one feed changed, one line removed, one line added, and some formatting-only edits.
    static var compareOther: String {
        main
            .replacingOccurrences(of: "G01 X50 F900", with: "G01 X50 F1100")
            .replacingOccurrences(of: "G01 Y40\n", with: "")
            .replacingOccurrences(of: "G01 X10\n", with: "g1 x10.0\n")
            .replacingOccurrences(of: "M30\n", with: "G04 P500\nM30\n")
    }
}
