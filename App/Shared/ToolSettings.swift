import Foundation
import SwiftUI
import SihemaCore

/// The cutter sizes and units the user entered. They are kept on this device and apply to every program, like the
/// offset table of a machine. Radii are stored in millimetres.
@MainActor
final class ToolSettings: ObservableObject {
    static let shared = ToolSettings()

    private let defaults: UserDefaults
    private static let radiiKey = "sihema.toolRadii"
    private static let inchesKey = "sihema.defaultInches"
    private static let entryKey = "sihema.entryInches"

    /// Cutter radius for each offset register D, in mm.
    @Published private(set) var radii: [Int: Double]
    /// Programs without G20 or G21 are in inches.
    @Published var defaultInches: Bool { didSet { defaults.set(defaultInches, forKey: Self.inchesKey) } }
    /// Sizes are typed in inches on the Tools screen.
    @Published var entryInches: Bool { didSet { defaults.set(entryInches, forKey: Self.entryKey) } }

    // How the machine moves, for the cycle time. The starting values are typical for a small machining centre.
    @Published var rapidMMPerMin: Double { didSet { defaults.set(rapidMMPerMin, forKey: "sihema.rapid") } }
    @Published var accelerationMMPerS2: Double { didSet { defaults.set(accelerationMMPerS2, forKey: "sihema.accel") } }
    @Published var toolChangeSeconds: Double { didSet { defaults.set(toolChangeSeconds, forKey: "sihema.toolChange") } }
    @Published var cornerStepMMPerS: Double { didSet { defaults.set(cornerStepMMPerS, forKey: "sihema.cornerStep") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded: [Int: Double] = [:]
        if let data = defaults.data(forKey: Self.radiiKey),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            for (key, value) in decoded {
                if let register = Int(key), value > 0 { loaded[register] = value }
            }
        }
        radii = loaded
        defaultInches = defaults.bool(forKey: Self.inchesKey)
        entryInches = defaults.bool(forKey: Self.entryKey)
        let standard = MotionModel()
        rapidMMPerMin = defaults.object(forKey: "sihema.rapid") as? Double ?? standard.rapidFeedMMPerMin
        accelerationMMPerS2 = defaults.object(forKey: "sihema.accel") as? Double ?? standard.accelerationMMPerS2
        toolChangeSeconds = defaults.object(forKey: "sihema.toolChange") as? Double ?? standard.toolChangeSeconds
        cornerStepMMPerS = defaults.object(forKey: "sihema.cornerStep") as? Double ?? standard.cornerStepMMPerS
    }

    /// The motion model with the user's values, kept inside sensible limits.
    var motionModel: MotionModel {
        var model = MotionModel()
        model.rapidFeedMMPerMin = max(rapidMMPerMin, 100)
        model.accelerationMMPerS2 = max(accelerationMMPerS2, 5)
        model.toolChangeSeconds = max(toolChangeSeconds, 0)
        model.cornerStepMMPerS = max(cornerStepMMPerS, 0)
        return model
    }

    /// Sets the radius of an offset register, or forgets it when `radiusMM` is nil or not positive.
    func setRadius(_ register: Int, radiusMM: Double?) {
        if let radiusMM, radiusMM > 0, radiusMM.isFinite {
            radii[register] = radiusMM
        } else {
            radii.removeValue(forKey: register)
        }
        let encoded = Dictionary(uniqueKeysWithValues: radii.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(encoded) { defaults.set(data, forKey: Self.radiiKey) }
    }

    /// The machine settings the interpreter runs with.
    var machine: MachineConfig {
        var config = AppDefaults.machine
        config.cutterRadii = radii
        config.defaultInches = defaultInches
        return config
    }
}
