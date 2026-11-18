import Foundation
import llama

/// Thin wrapper around llama.cpp for one local GGUF model. Not thread-safe: create, use and
/// drop it on a single background task. Everything runs on this Mac (Metal); no network.
final class LlamaRunner {
    enum Failure: LocalizedError {
        case load, context, tokenize, decode, grammar, tooLong, unfinished
        var errorDescription: String? {
            switch self {
            case .load: return L("the model file couldn't be loaded")
            case .context: return L("not enough memory for the model")
            case .tokenize: return L("the text couldn't be tokenized")
            case .decode: return L("the model stopped with an error")
            case .grammar: return L("invalid output grammar")
            case .tooLong: return L("the text is too long for the model")
            case .unfinished: return L("the summary didn't come out right, try Summarize again")
            }
        }
    }

    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    let contextSize: Int
    private static let batchSize = 512

    private static let backend: Void = {
        llama_log_set({ _, _, _ in }, nil)   // llama.cpp is chatty on stderr
        llama_backend_init()
    }()

    init(path: String, contextSize wanted: Int) throws {
        _ = Self.backend
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 999                 // everything on the GPU (Metal)
        guard let model = llama_model_load_from_file(path, mp) else { throw Failure.load }
        let trained = Int(llama_model_n_ctx_train(model))
        let n = trained > 0 ? min(wanted, trained) : wanted
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(n)
        cp.n_batch = UInt32(Self.batchSize)
        guard let ctx = llama_init_from_model(model, cp) else {
            llama_model_free(model)
            throw Failure.context
        }
        self.model = model
        self.ctx = ctx
        self.vocab = llama_model_get_vocab(model)
        self.contextSize = n
    }

    deinit {
        llama_free(ctx)
        llama_model_free(model)
    }

    func tokenCount(_ text: String) -> Int {
        (try? tokenize(text, special: false).count) ?? text.utf8.count / 3
    }

    /// Builds a prompt with the model's own chat template (ChatML if it has none we know).
    func chatPrompt(system: String, user: String) -> String {
        let roles = [strdup("system"), strdup("user")]
        let texts = [strdup(system), strdup(user)]
        defer { (roles + texts).forEach { free($0) } }
        var messages = [llama_chat_message(role: roles[0], content: texts[0]),
                        llama_chat_message(role: roles[1], content: texts[1])]
        let template = llama_model_chat_template(model, nil)
        var buffer = [CChar](repeating: 0, count: (system.utf8.count + user.utf8.count) * 2 + 512)
        var n = llama_chat_apply_template(template, &messages, 2, true, &buffer, Int32(buffer.count))
        if n > Int32(buffer.count) {
            buffer = [CChar](repeating: 0, count: Int(n) + 1)
            n = llama_chat_apply_template(template, &messages, 2, true, &buffer, Int32(buffer.count))
        }
        guard n > 0 else {
            return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        }
        return String(decoding: buffer[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Generates a reply to `prompt` (already in chat format). `grammar` (GBNF) constrains the output.
    func generate(_ prompt: String, maxTokens: Int, grammar: String? = nil) throws -> String {
        llama_memory_clear(llama_get_memory(ctx), true)
        var tokens = try tokenize(prompt, special: true)
        guard tokens.count + maxTokens <= contextSize else { throw Failure.tooLong }

        var start = 0
        while start < tokens.count {
            let n = min(Self.batchSize, tokens.count - start)
            let status = tokens.withUnsafeMutableBufferPointer { buf in
                llama_decode(ctx, llama_batch_get_one(buf.baseAddress! + start, Int32(n)))
            }
            guard status == 0 else { throw Failure.decode }
            start += n
        }

        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(chain) }
        if let grammar {
            guard let g = llama_sampler_init_grammar(vocab, grammar, "root") else { throw Failure.grammar }
            llama_sampler_chain_add(chain, g)
        }
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.1, 0, 0))
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.3))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32(LLAMA_DEFAULT_SEED)))

        var output = [UInt8]()
        var piece = [CChar](repeating: 0, count: 256)
        for _ in 0..<maxTokens {
            var token = llama_sampler_sample(chain, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let n = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if n > 0 { output += piece[0..<Int(n)].map { UInt8(bitPattern: $0) } }
            guard llama_decode(ctx, llama_batch_get_one(&token, 1)) == 0 else { throw Failure.decode }
            if Task.isCancelled { break }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private func tokenize(_ text: String, special: Bool) throws -> [llama_token] {
        let length = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 8)
        var n = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), special, special)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), special, special)
        }
        guard n >= 0 else { throw Failure.tokenize }
        return Array(tokens.prefix(Int(n)))
    }
}
