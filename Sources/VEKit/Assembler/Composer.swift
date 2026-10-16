import Foundation

// How VE Configure drives the assembler (docs/re/03-assembler.md §13): META, asfStart, the assistants, asfStop,
// assembled as one root file; device image = code + 0xFF padding + assistant IDs in reverse order.

public struct AssistantBuildResult: Sendable {
    public var success: Bool
    /// META `.SET` labels whose final value differs from META (`name` → new value), docs/re/05-meta.md §6.
    public var vecChanges: [String: Value] = [:]
    public var code: [UInt8]
    public var messages: [AssemblerMessage]
    public var answers: [String: AnswerTable]
    public var cancelled: Bool
}

public final class AssistantComposer {
    public struct Item: Sendable {
        public var package: AssistantPackage
        public var name: String { package.baseName }
    }

    public let library: AssistantLibrary
    /// Assistants between asfStart and asfStop, in order.
    public var items: [Item] = []
    /// Answers per assistant name (the user's choices), kept between builds.
    public var answers: [String: AnswerTable] = [:]
    /// Text of the META environment item (target description), see docs/re/05-meta.md.
    public var meta: [UInt8] = []
    public var framework: (start: AssistantPackage, stop: AssistantPackage)
    public var languages: [String] = ["en"]

    public init(library: AssistantLibrary, start: AssistantPackage? = nil, stop: AssistantPackage? = nil) throws {
        self.library = library
        guard let s = start ?? library.latest.first(where: { $0.baseName == "asfStart" }),
              let e = stop ?? library.latest.first(where: { $0.baseName == "asfStop" })
        else { throw FormatError.badMagic("assistant library (asfStart/asfStop missing)") }
        framework = (s, e)
    }

    var allPackages: [AssistantPackage] { [framework.start] + items.map(\.package) + [framework.stop] }

    private func rootList() -> LineList {
        var lines = [SourceLine(Latin1.encode(" .SOURCE 'META'"))]
        for p in allPackages { lines.append(SourceLine(Latin1.encode(" .SOURCE '\(p.baseName)'"))) }
        return LineList(header: "Assistant Composer", lines: lines)
    }

    fileprivate func makeAssembler(state: (String) -> AssemblerState) -> AssistantAssembler {
        let a = AssistantAssembler()
        let packages = Dictionary(allPackages.map { ($0.baseName, $0) }, uniquingKeysWith: { a, _ in a })
        let meta = self.meta
        a.sourceProvider = { name in
            if name == "META" { return meta }
            return packages[name]?.source?.bytes
        }
        for (name, p) in packages {
            a.states[name] = state(name)
            let english = p.scripts["en"].map { WizardText($0.bytes) }
            let localized = languages.lazy.compactMap { p.scripts[$0] }.first.map { WizardText($0.bytes) }
            a.texts[name] = (localized, english)
        }
        a.states["META"] = .build
        a.tables = answers
        return a
    }

    /// Normal build of configured assistants (state 4), with the pass-3 readback verification.
    public func build() -> AssistantBuildResult {
        let a = makeAssembler { _ in .build }
        let ok = a.assemble(root: rootList(), passes: 2)
        var verified = ok
        if ok {
            a.referenceBinary = a.code
            let code = a.code
            verified = a.assemble(root: rootList(), passes: 3) && a.code == code
        }
        answers = a.tables
        var r = AssistantBuildResult(success: verified, code: a.code, messages: a.messages, answers: a.tables, cancelled: false)
        r.vecChanges = Self.vecChanges(meta: meta, assembler: a)
        return r
    }

    /// FUN_0050EE78: every META ` .SET` label whose final value, as text, differs from the original.
    static func vecChanges(meta: [UInt8], assembler a: Assembler) -> [String: Value] {
        var out: [String: Value] = [:]
        for raw in meta.split(separator: 0x0A) {
            let line = String(decoding: raw.filter { $0 != 0x0D }, as: Latin1.self)
            guard let set = line.range(of: " .SET "), let tail = line.range(of: ",4,true", options: .backwards) else { continue }
            let name = String(line[..<set.lowerBound]).trimmingCharacters(in: .whitespaces)
            let original = String(line[set.upperBound..<tail.lowerBound])
            guard let v = a.global[name]?.value, v.text != original else { continue }
            out[name] = v
        }
        return out
    }

    /// The "assistants removed" image: a 6-byte stub that keeps the checksum at the erased value.
    public static func emptyImage(size: Int = 4096) -> [UInt8] {
        [0xA7, 0xFE, 0x00, 0x00, 0x57, 0x01] + [UInt8](repeating: 0xFF, count: size - 6)
    }

    /// Applies a successful build to a configuration: settings changed by the assistants (clamped to the device
    /// range, as FUN_00516420 does) and the new program image. `BatteryType_VEC` is returned for the caller,
    /// which owns the battery presets.
    public func apply(_ result: AssistantBuildResult, to config: DeviceConfiguration) -> (DeviceConfiguration, batteryType: Int?) {
        var c = config
        let targets = MetaGenerator.vecTargets(config)
        for (name, value) in result.vecChanges {
            guard case .int(let v) = value, let target = targets[name] else { continue }
            switch target {
            case .setting(let id):
                guard let info = c.info.info(id) else { continue }
                let clamped = min(max(Int(v), Int(info.minRaw)), Int(info.maxRaw))
                c.setRaw(id, UInt16(clamped))
            case .flag(let n):
                c.setFlag(n, v != 0)
            }
        }
        let size = config.data.assistantMemory.count
        c.data.assistantMemory = items.isEmpty ? Self.emptyImage(size: size) : image(code: result.code, size: size)
        var battery: Int? = nil
        if case .int(let b)? = result.vecChanges["BatteryType_VEC"] { battery = Int(b) }
        return (c, battery)
    }

    /// Starts the wizard of one assistant (state 5); the others replay their stored answers.
    public func wizard(for assistant: String) -> AssistantWizard { AssistantWizard(composer: self, assistant: assistant) }

    func assembler(states: @escaping (String) -> AssemblerState) -> AssistantAssembler { makeAssembler(state: states) }

    func root() -> LineList { rootList() }

    // MARK: Device image

    /// Assistant IDs stored at the top of an image, read downward until asfStop.
    public static func installedIDs(in image: [UInt8], trailer: Int = 4) -> [UInt32] {
        var ids: [UInt32] = []
        var p = image.count - trailer - 2
        while p >= 0 {
            let id = UInt32(image[p]) | UInt32(image[p + 1]) << 8
            if id == 0xFFFF { break }
            ids.append(id)
            p -= 2
            if id == 0x000E || ids.count > 64 { break }   // asfStop ends the list
        }
        return ids
    }

    /// Fills the composer from an image's ID directory (top-down: asfStart, assistants…, asfStop).
    public func load(image: [UInt8]) throws {
        let ids = Self.installedIDs(in: image)
        guard ids.count >= 2 else { items = []; return }
        guard let s = library.package(id: ids.first!), let e = library.package(id: ids.last!) else {
            throw AssistantError.unknownAssistant(ids.first!)
        }
        framework = (s, e)
        items = try ids.dropFirst().dropLast().map { id in
            guard let p = library.package(id: id) else { throw AssistantError.unknownAssistant(id) }
            return Item(package: p)
        }
    }

    /// Recovers the user's answers from a device image (state 2) and checks the code re-assembles identically.
    public func reconstruct(image: [UInt8]) throws -> AssistantBuildResult {
        try load(image: image)
        let a = makeAssembler { _ in .backReadBuild }
        a.states["META"] = .build
        a.tables = [:]
        a.referenceBinary = image
        let ok = a.assemble(root: rootList())
        var result = AssistantBuildResult(success: ok, code: a.code, messages: a.messages, answers: a.tables, cancelled: false)
        if ok {
            let device = Self.trimmed(image, codeLength: a.code.count)
            if device != Self.trimmed(a.code, codeLength: a.code.count) {
                let first = zip(device, a.code).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(device.count, a.code.count)
                result.success = false
                result.messages.append(AssemblerMessage(kind: .error, text: String(format: "The reconstructed binary does not match! First difference is located at 0x%X", first), position: ""))
            } else {
                answers = a.tables
            }
        }
        return result
    }

    static func trimmed(_ b: [UInt8], codeLength: Int) -> [UInt8] {
        var x = Array(b.prefix(max(codeLength, 0) + 16))
        while x.last == 0xFF { x.removeLast() }
        return x
    }

    /// Image checksum (VEConfig FUN_00510494): Σ((bᵢ xor 0xFF) << 8·(i mod 4)) − 1 over all bytes but the last 4.
    public static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var sum: UInt32 = 0
        for (i, b) in bytes.enumerated() { sum &+= UInt32(b ^ 0xFF) << (8 * UInt32(i % 4)) }
        return sum &- 1
    }

    /// Complete device image: code, 0xFF padding, IDs (asfStop lowest … asfStart highest), 4-byte checksum.
    public func image(code: [UInt8], size: Int = 4096) -> [UInt8] {
        var img = image(code: code, size: size, trailer: [0, 0, 0, 0])
        let c = Self.checksum(img[0..<(size - 4)])
        for k in 0..<4 { img[size - 4 + k] = UInt8(c >> (8 * UInt32(k)) & 0xFF) }
        return img
    }

    /// Image of `size` bytes: code, 0xFF padding, IDs (asfStop first … asfStart last), trailer.
    public func image(code: [UInt8], size: Int = 4096, trailer: [UInt8]) -> [UInt8] {
        var img = code + [UInt8](repeating: 0xFF, count: max(0, size - code.count))
        var p = size - trailer.count
        for pkg in allPackages {
            p -= 2
            img[p] = UInt8(pkg.id & 0xFF)
            img[p + 1] = UInt8(pkg.id >> 8)
        }
        for (k, b) in trailer.enumerated() { img[size - trailer.count + k] = b }
        return img
    }
}

public enum AssistantError: Error, CustomStringConvertible {
    case unknownAssistant(UInt32)
    public var description: String {
        switch self {
        case .unknownAssistant(let id): String(format: "An Assistant, which is not on your system (ID 0x%04X), is installed in the device.", id)
        }
    }
}

/// One run of an assistant's wizard. Non-blocking: each call re-assembles from scratch up to the step to show
/// (the same replay mechanism VE Configure uses for stepback), so the UI simply answers and calls again.
public final class AssistantWizard {
    public enum Status { case step(AssistantStepPresentation), finished(AssistantBuildResult), failed([AssemblerMessage]), cancelled }

    let composer: AssistantComposer
    public let assistant: String
    private var displayStep: Int32 = 1
    private var backList: [Value] = []
    private var tables: [String: AnswerTable]
    private var pending: AssistantDecision?
    public private(set) var status: Status = .cancelled

    init(composer: AssistantComposer, assistant: String) {
        self.composer = composer
        self.assistant = assistant
        tables = composer.answers
        run()
    }

    public func next(_ values: [Int32]) { pending = .next(values); run() }
    public func previous() { pending = .previous; run() }
    public func cancel() { status = .cancelled }

    private func run() {
        for _ in 0..<1024 {
            let a = composer.assembler { [assistant] in $0 == assistant ? .userEntry : .build }
            a.tables = tables
            a.displayStep = displayStep
            a.backStepList = backList
            var captured: AssistantStepPresentation?
            a.presentStep = { [unowned self] p in
                if let d = self.pending { self.pending = nil; return d }
                captured = p
                return .suspend
            }
            let ok = a.assemble(root: composer.root())
            a.captureDriverState()
            displayStep = a.displayStep
            backList = a.backStepList
            tables = a.tables
            if ok {
                composer.answers = tables
                status = .finished(AssistantBuildResult(success: true, code: a.code, messages: a.messages, answers: tables, cancelled: false))
                return
            }
            let first = a.messages.first(where: { $0.kind == .fatal })?.text
            if first == AssistantAssembler.suspendMessage, let p = captured { status = .step(p); return }
            if first == AssistantAssembler.restartMessage { continue }
            status = .failed(a.messages)
            return
        }
        status = .failed([AssemblerMessage(kind: .fatal, text: "Wizard did not converge", position: "")])
    }
}
