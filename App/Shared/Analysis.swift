import Foundation
import SihemaCore

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Everything the views need from one run of the core over the program text.
struct Analysis: Sendable {
    let id = UUID()
    var lineCount = 0
    var wordCount = 0
    var toolpath = Toolpath()
    var tokenizeSeconds = 0.0
    var interpretSeconds = 0.0

    static func make(text: String) -> Analysis {
        let clock = ContinuousClock()
        var tokens = TokenizedProgram()
        let tokenize = clock.measure { tokens = GCodeTokenizer.tokenize(text) }
        var path = Toolpath()
        let interpret = clock.measure { path = FanucInterpreter().run(tokens) }
        var result = Analysis()
        result.lineCount = tokens.lineCount
        result.wordCount = tokens.words.count
        result.toolpath = path
        result.tokenizeSeconds = tokenize.seconds
        result.interpretSeconds = interpret.seconds
        return result
    }
}
