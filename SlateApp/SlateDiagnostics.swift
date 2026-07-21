import OSLog

enum SlateDiagnostics {
    static let app = Logger(subsystem: "com.langeundco.slate", category: "app")
    static let model = Logger(subsystem: "com.langeundco.slate", category: "model")
}
