import Foundation

struct MemoryQueryFormatter: Sendable {
    let codec: MemoryQueryJSONCodec

    init(codec: MemoryQueryJSONCodec = MemoryQueryJSONCodec()) {
        self.codec = codec
    }

    func render(_ result: MemoryQueryResult, as format: MemoryQueryOutputFormat) -> String {
        switch format {
        case .text:
            return renderText(result)
        case .json:
            return codec.renderJSON(result)
        }
    }

    private func renderText(_ result: MemoryQueryResult) -> String {
        var lines: [String] = [result.answer]
        if !result.keyPoints.isEmpty {
            lines.append("")
            lines.append("Key points:")
            lines.append(contentsOf: result.keyPoints.map { "- \($0)" })
        }
        if !result.supportingEvents.isEmpty {
            lines.append("")
            lines.append("Supporting events:")
            lines.append(contentsOf: result.supportingEvents.map { "- \($0)" })
        }
        if result.insufficientEvidence {
            lines.append("")
            lines.append("Evidence is partial; answer is based only on retrieved memories.")
        }
        return lines.joined(separator: "\n")
    }
}
