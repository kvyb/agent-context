import Foundation

struct BM25Ranker: Sendable {
    let k1: Double
    let b: Double

    init(k1: Double = 1.5, b: Double = 0.75) {
        self.k1 = k1
        self.b = b
    }

    func score(documents: [[String]], queryTerms: [String]) -> [Double] {
        guard !documents.isEmpty, !queryTerms.isEmpty else {
            return Array(repeating: 0, count: documents.count)
        }

        let tokenCounts = documents.map { tokens in
            tokens.reduce(into: [String: Int]()) { counts, token in
                counts[token, default: 0] += 1
            }
        }

        let docLengths = documents.map(\.count)
        let averageLength = max(1.0, Double(docLengths.reduce(0, +)) / Double(documents.count))

        var docFrequency: [String: Int] = [:]
        for counts in tokenCounts {
            for token in counts.keys {
                docFrequency[token, default: 0] += 1
            }
        }

        let queryCounts = queryTerms.reduce(into: [String: Int]()) { counts, token in
            counts[token, default: 0] += 1
        }

        let totalDocuments = Double(documents.count)
        var scores = Array(repeating: 0.0, count: documents.count)

        for (term, queryFrequency) in queryCounts {
            let df = Double(docFrequency[term] ?? 0)
            if df == 0 {
                continue
            }

            let idf = log(1.0 + ((totalDocuments - df + 0.5) / (df + 0.5)))
            for index in documents.indices {
                let tf = Double(tokenCounts[index][term] ?? 0)
                if tf == 0 {
                    continue
                }
                let lengthNorm = (1 - b) + b * (Double(docLengths[index]) / averageLength)
                let denominator = tf + (k1 * lengthNorm)
                let termScore = idf * ((tf * (k1 + 1)) / denominator) * Double(queryFrequency)
                scores[index] += termScore
            }
        }

        return scores
    }
}
