import Foundation
import SihemaCore

/// Switches used by the automated screenshot tests, passed as environment variables because macOS treats loose
/// launch arguments as documents to open.
///   SIHEMA_UITEST=1        open the sample program
///   SIHEMA_TAB=<name>      start on a tab: code, path, compare or report
///   SIHEMA_SIMULATE=1      run the material removal automatically on the report tab
///   SIHEMA_PROGRAM=<path>  open this G-code file instead of the sample program
enum UITestSupport {
    static let environment = ProcessInfo.processInfo.environment

    static var isDirect: Bool { environment["SIHEMA_UITEST"] != nil }
    static var simulate: Bool { environment["SIHEMA_SIMULATE"] != nil }
    static var tab: String? { environment["SIHEMA_TAB"] }
    static var programPath: String? { environment["SIHEMA_PROGRAM"] }
    static var jumpLine: Int? { environment["SIHEMA_JUMP"].flatMap { Int($0) } }
    static var demoName: String? { environment["SIHEMA_DEMO"] }
    static var playbackProgress: Double? { environment["SIHEMA_PLAYBACK"].flatMap { Double($0) } }
}

/// Machine settings used until the app has a machine profile screen.
enum AppDefaults {
    static let machine: MachineConfig = {
        var config = MachineConfig()
        // cutter radii come from the program, from the tool comments or from the user's entries (ToolSettings)
        return config
    }()
}

enum DemoPrograms {
    /// A pocket with a WHILE loop, a profile with cutter compensation, and a subprogram call.
    static var main: String {
        if let path = UITestSupport.programPath, let text = try? String(contentsOfFile: path, encoding: .utf8) {
            return text
        }
        return UITestSupport.demoName == "problems" ? withProblems : builtIn
    }

    /// A short program with an error, warnings and a note, for checking how problems are shown.
    static let withProblems = """
    O1 (PROBLEMS)
    G21 G90 G17
    T1 M6
    G43 H1 Z5.
    G00 X0 Y0
    G01 X20 Y0
    G41 D9 G01 X20 Y10 F300
    G02 X30 Y20
    G01 X40
    G83 X10 Y10 Z-10 R2 F100
    G80
    G65 P9999
    M30

    """

    static let builtIn = """
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
        builtIn
            .replacingOccurrences(of: "G01 X50 F900", with: "G01 X50 F1100")
            .replacingOccurrences(of: "G01 Y40\n", with: "")
            .replacingOccurrences(of: "G01 X10\n", with: "g1 x10.0\n")
            .replacingOccurrences(of: "M30\n", with: "G04 P500\nM30\n")
    }
}
