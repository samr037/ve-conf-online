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
    /// Steps bound during the build, in order (for summaries).
    public var steps: [AssistantStepPresentation] = []
}

public final class AssistantComposer {
    public struct Item: Sendable {
        public var package: AssistantPackage
        public var name: String { package.baseName }
        public init(package: AssistantPackage) { self.package = package }
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

    public func package(named name: String) -> AssistantPackage? { allPackages.first { $0.baseName == name } }

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
        r.steps = a.stepLog
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

    /// Size of the assistant program memory: VE Configure only ever handles 4096 bytes.
    public static let memorySize = 4096

    /// Bytes an image needs: code, the ID directory (framework + assistants) and the 4-byte checksum.
    public func bytesNeeded(code: [UInt8]) -> Int { code.count + 2 * allPackages.count + 4 }

    /// Applies a successful build to a configuration: the battery preset an assistant selected (`BatteryType_VEC`,
    /// through `batteryPreset`, owned by the caller), then the settings changed by the assistants (clamped to the
    /// device range, as FUN_00516420 does), then the new program image. Throws when the build failed or the program
    /// does not fit the configuration's assistant memory.
    public func apply(_ result: AssistantBuildResult, to config: DeviceConfiguration,
                      extraChanges: [String: Value] = [:],
                      batteryPreset: ((Int, inout DeviceConfiguration) -> Void)? = nil) throws -> (DeviceConfiguration, batteryType: Int?) {
        guard result.success else {
            throw AssistantError.buildFailed(result.messages.first { $0.kind == .fatal || $0.kind == .error }?.text ?? "")
        }
        let size = config.data.assistantMemory.count
        let memory = items.isEmpty ? try Self.emptyImage(checkedSize: size) : try image(code: result.code, size: size)
        var c = config
        let targets = MetaGenerator.vecTargets(config)
        let changes = extraChanges.merging(result.vecChanges) { _, new in new }
        var battery: Int? = nil
        if case .int(let b)? = changes["BatteryType_VEC"] {
            battery = Int(b)
            if b > 0 { batteryPreset?(Int(b), &c) }
        }
        for (name, value) in changes {
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
        c.data.assistantMemory = memory
        return (c, battery)
    }

    static func emptyImage(checkedSize size: Int) throws -> [UInt8] {
        guard size == memorySize else { throw AssistantError.badMemorySize(size) }
        return emptyImage(size: size)
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
    /// Throws unless `size` is the 4096-byte assistant memory and everything fits in it.
    public func image(code: [UInt8], size: Int = AssistantComposer.memorySize) throws -> [UInt8] {
        guard size == Self.memorySize else { throw AssistantError.badMemorySize(size) }
        let needed = bytesNeeded(code: code)
        guard needed <= size else { throw AssistantError.imageTooLarge(needed: needed, size: size) }
        var img = code + [UInt8](repeating: 0xFF, count: size - code.count)
        var p = size - 4
        for pkg in allPackages {
            p -= 2
            img[p] = UInt8(pkg.id & 0xFF)
            img[p + 1] = UInt8(pkg.id >> 8)
        }
        let c = Self.checksum(img[0..<(size - 4)])
        for k in 0..<4 { img[size - 4 + k] = UInt8(c >> (8 * UInt32(k)) & 0xFF) }
        return img
    }
}

public enum AssistantError: Error, CustomStringConvertible {
    case unknownAssistant(UInt32)
    case imageTooLarge(needed: Int, size: Int)
    case badMemorySize(Int)
    case buildFailed(String)
    public var description: String {
        switch self {
        case .unknownAssistant(let id): String(format: "An Assistant, which is not on your system (ID 0x%04X), is installed in the device.", id)
        case .imageTooLarge(let needed, let size): "Not enough assistant memory: \(needed) bytes needed, \(size) available."
        case .badMemorySize(let n): "The assistant memory of this configuration is \(n) bytes; 4096 expected."
        case .buildFailed(let m): m.isEmpty ? "The assistants could not be assembled." : m
        }
    }
}

/// One run of an assistant's wizard (driver FUN_00500bec, docs/re/03-assembler.md §11.7).
///
/// Like VE Configure, the assembly is one continuous run that pauses at each step shown: it runs on a worker thread
/// that waits for the answer, so whatever the sources do once a step is handled (`$AUEHandled`, `.ALS`, `_VEC`
/// settings) happens exactly once, with the user's answer. Only Previous (and a source's `.RESTART`) restarts the
/// assembly from scratch, replaying the earlier steps with their stored answers.
///
/// The calls are synchronous: `next`/`previous` return once the worker shows the following step or has finished.
/// After a cancel, finish or failure the wizard ignores further calls.
public final class AssistantWizard {
    public enum Status { case step(AssistantStepPresentation), finished(AssistantBuildResult), failed([AssemblerMessage]), cancelled }

    let composer: AssistantComposer
    public let assistant: String
    public private(set) var status: Status
    private let session: WizardSession

    init(composer: AssistantComposer, assistant: String) {
        self.composer = composer
        self.assistant = assistant
        session = WizardSession { session in
            Self.drive(composer: composer, assistant: assistant, session: session)
        }
        status = session.start()
        if case .finished(let r) = status { composer.answers = r.answers }
    }

    deinit { session.abandon() }

    /// A step is shown and waits for an answer.
    public var isWaiting: Bool { if case .step = status { true } else { false } }

    public func next(_ values: [Int32]) { answer(.next(values)) }
    public func previous() { answer(.previous) }
    public func cancel() {
        guard isWaiting else { return }
        _ = session.answer(.cancel)
        status = .cancelled
    }

    private func answer(_ d: AssistantDecision) {
        guard isWaiting else { return }
        status = session.answer(d)
        if case .finished(let r) = status { composer.answers = r.answers }
    }

    /// Worker side: the assembly loop, restarted on stepback.
    private static func drive(composer: AssistantComposer, assistant: String, session: WizardSession) -> Status {
        var displayStep: Int32 = 1
        var backList: [Value] = []
        var tables = composer.answers
        for _ in 0..<1024 {
            let a = composer.assembler { $0 == assistant ? .userEntry : .build }
            a.tables = tables
            a.displayStep = displayStep
            a.backStepList = backList
            a.presentStep = { session.present($0) }
            let ok = a.assemble(root: composer.root())
            a.captureDriverState()
            displayStep = a.displayStep
            backList = a.backStepList
            tables = a.tables
            if ok {
                var r = AssistantBuildResult(success: true, code: a.code, messages: a.messages, answers: tables, cancelled: false)
                r.vecChanges = AssistantComposer.vecChanges(meta: composer.meta, assembler: a)
                r.steps = a.stepLog
                return .finished(r)
            }
            if a.cancelled { return .cancelled }
            if a.messages.first(where: { $0.kind == .fatal })?.text == AssistantAssembler.restartMessage { continue }
            return .failed(a.messages)
        }
        return .failed([AssemblerMessage(kind: .fatal, text: "Wizard did not converge", position: "")])
    }
}

/// Hand-off between the caller and the wizard's worker thread: exactly one of them runs at a time.
private final class WizardSession: @unchecked Sendable {
    private let toWorker = DispatchSemaphore(value: 0)
    private let toCaller = DispatchSemaphore(value: 0)
    private let work: (WizardSession) -> AssistantWizard.Status
    private var decision: AssistantDecision = .cancel
    private var event: AssistantWizard.Status = .cancelled
    private var running = false

    init(work: @escaping (WizardSession) -> AssistantWizard.Status) { self.work = work }

    /// Starts the worker and returns the first step (or the end).
    func start() -> AssistantWizard.Status {
        running = true
        let t = Thread { [self] in
            let end = work(self)
            event = end
            running = false
            toCaller.signal()
        }
        t.stackSize = 64 << 20   // nested .SOURCE / macro recursion
        t.name = "Assistant wizard"
        t.start()
        toCaller.wait()
        return event
    }

    /// Caller side: hands the answer to the waiting worker and returns its next step (or the end).
    func answer(_ d: AssistantDecision) -> AssistantWizard.Status {
        guard running else { return event }
        decision = d
        toWorker.signal()
        toCaller.wait()
        return event
    }

    /// Worker side: shows a step and waits for the answer.
    func present(_ p: AssistantStepPresentation) -> AssistantDecision {
        event = .step(p)
        toCaller.signal()
        toWorker.wait()
        return decision
    }

    /// Lets a worker that still waits for an answer finish (cancel), so the thread ends.
    func abandon() {
        while running { _ = answer(.cancel) }
    }
}
