import MLX
import MLXLMCommon

/// Restricts LLM output to only tokens present in the input transcript plus punctuation.
/// Prevents hallucination by construction: the model cannot generate words it wasn't given.
final class InputVocabularyProcessor: LogitProcessor {

    private let allowedTokenIDs: Set<Int>
    private var mask: MLXArray?

    init(allowedTokenIDs: Set<Int>) {
        self.allowedTokenIDs = allowedTokenIDs
    }

    func prompt(_ prompt: MLXArray) {}

    func process(logits: MLXArray) -> MLXArray {
        if mask == nil {
            let vocabSize = logits.dim(-1)
            var values = [Float](repeating: -Float.infinity, count: vocabSize)
            for id in allowedTokenIDs where id >= 0 && id < vocabSize {
                values[id] = 0
            }
            mask = MLXArray(values).reshaped(1, vocabSize)
        }
        return logits + mask!
    }

    func didSample(token: MLXArray) {}

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

        let alwaysAllowed = [
            ".", ",", "!", "?", ";", ":", "-", "'", "\"", "\n", " ",
            "'s", "'t", "'re", "'ve", "'ll", "'d", "'m", "n't",
            " .", " ,", " !", " ?",
        ]
        for s in alwaysAllowed {
            allowed.formUnion(tokenizer.encode(text: s, addSpecialTokens: false))
        }
        if let eos = tokenizer.eosTokenId { allowed.insert(eos) }

        return InputVocabularyProcessor(allowedTokenIDs: allowed)
    }
}
