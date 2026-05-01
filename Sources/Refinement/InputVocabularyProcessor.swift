import MLX
import MLXLMCommon
import os

/// Restricts LLM output to only tokens present in the input transcript plus punctuation.
/// Prevents hallucination by construction: the model cannot generate words it wasn't given.
final class InputVocabularyProcessor: LogitProcessor {

    private let allowedTokenIDs: Set<Int>
    private var mask: MLXArray?
    private var callCount = 0
    private let log = Logger(subsystem: "io.gremble.gremblevoice", category: "VocabProcessor")

    init(allowedTokenIDs: Set<Int>) {
        self.allowedTokenIDs = allowedTokenIDs
        log.info("VocabProcessor created with \(allowedTokenIDs.count) allowed tokens")
    }

    func prompt(_ prompt: MLXArray) {
        log.debug("VocabProcessor.prompt() called, prompt shape: \(prompt.shape.description)")
    }

    func process(logits: MLXArray) -> MLXArray {
        callCount += 1
        if mask == nil {
            let vocabSize = logits.dim(-1)
            var values = [Float](repeating: -Float.infinity, count: vocabSize)
            for id in allowedTokenIDs where id >= 0 && id < vocabSize {
                values[id] = 0
            }
            mask = MLXArray(values).reshaped(1, vocabSize)
            let infCount = vocabSize - allowedTokenIDs.count
            log.info("Mask built: vocabSize=\(vocabSize), allowed=\(self.allowedTokenIDs.count), masked=\(infCount), logits shape=\(logits.shape.description)")
        }
        let result = logits + mask!
        if callCount <= 3 {
            log.debug("process() call #\(self.callCount), logits shape=\(logits.shape.description), result shape=\(result.shape.description)")
        }
        return result
    }

    func didSample(token: MLXArray) {
        if callCount <= 5 {
            let tokenId = token.item(Int.self)
            let isAllowed = allowedTokenIDs.contains(tokenId)
            log.debug("Sampled token \(tokenId), allowed=\(isAllowed)")
        }
    }

    static func build(transcript: String, tokenizer: Tokenizer) -> InputVocabularyProcessor {
        var allowed = Set<Int>()

        allowed.formUnion(tokenizer.encode(text: transcript, addSpecialTokens: false))

        for word in transcript.split(separator: " ").map(String.init) where !word.isEmpty {
            allowed.formUnion(tokenizer.encode(text: word, addSpecialTokens: false))
            allowed.formUnion(tokenizer.encode(text: " " + word, addSpecialTokens: false))
            let cap = word.prefix(1).uppercased() + word.dropFirst()
            allowed.formUnion(tokenizer.encode(text: cap, addSpecialTokens: false))
            allowed.formUnion(tokenizer.encode(text: " " + cap, addSpecialTokens: false))
        }

        // Single-character punctuation: safe to encode (no sub-token leakage).
        let punctuation = [".", ",", "!", "?", ";", ":", "-", "'", "\u{2019}", "\"", "\n", " "]
        for p in punctuation {
            allowed.formUnion(tokenizer.encode(text: p, addSpecialTokens: false))
        }

        // Multi-character contractions: use convertTokenToId to avoid splitting
        // "'re" into ["'", "re"] which leaks "re" as a building block for new words.
        let contractions = ["'s", "'t", "'re", "'ve", "'ll", "'d", "'m", "n't",
                            "\u{2019}s", "\u{2019}t", "\u{2019}re", "\u{2019}ve",
                            "\u{2019}ll", "\u{2019}d", "\u{2019}m"]
        for c in contractions {
            if let id = tokenizer.convertTokenToId(c) { allowed.insert(id) }
        }
        if let eos = tokenizer.eosTokenId { allowed.insert(eos) }

        return InputVocabularyProcessor(allowedTokenIDs: allowed)
    }
}
