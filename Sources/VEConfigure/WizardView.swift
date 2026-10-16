import SwiftUI
import VEKit

/// Drives one assistant wizard; each answer re-assembles up to the next step (VE Configure's replay model).
final class WizardModel: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    private let composer: AssistantComposer
    private let wizard: AssistantWizard
    private let languages: [String]
    private let completion: (AssistantBuildResult?) -> Void
    private var done = false

    @Published private(set) var step: AssistantStepPresentation?
    @Published private(set) var content: WizardStepContent?
    @Published var values: [Int32] = []
    @Published var texts: [String] = []
    @Published private(set) var error: String?
    @Published private(set) var stepNumber = 0
    @Published var finished = false

    init(composer: AssistantComposer, assistant: String, title: String, languages: [String],
         completion: @escaping (AssistantBuildResult?) -> Void) {
        self.composer = composer
        self.title = title
        self.languages = languages
        self.completion = completion
        wizard = composer.wizard(for: assistant)
        refresh(forward: true)
    }

    private func refresh(forward: Bool) {
        switch wizard.status {
        case .step(let p):
            step = p
            let script = composer.package(named: p.assistant)?.script(preferring: languages).map { WizardText($0.bytes) }
            content = WizardStepContent(step: p.step, text: script, format: p.format)
            values = p.values
            texts = zip(p.step.fields, p.values).map { $0.display($1) }
            stepNumber += forward ? 1 : -1
            error = nil
        case .finished(let r):
            finish(r)
        case .failed(let messages):
            let fatal = messages.first { $0.kind == .fatal || $0.kind == .error }
            error = fatal.map(AssistantsModel.clean) ?? L("The assistant stopped with an error.")
        case .cancelled:
            finish(nil)
        }
    }

    private func finish(_ r: AssistantBuildResult?) {
        guard !done else { return }
        done = true
        finished = true
        completion(r)
    }

    var canGoBack: Bool {
        guard let s = step else { return false }
        return stepNumber > 1 && (s.buttons == .normal || s.buttons == .previousOnly)
    }
    var canGoForward: Bool {
        guard let s = step else { return false }
        return s.buttons == .normal || s.buttons == .nextOnly
    }

    func next() {
        guard let s = step else { return }
        var v = values
        if s.step.kind == .entry {
            for (i, f) in s.step.fields.enumerated() where i < texts.count && f.precision != .list {
                guard let parsed = f.parse(texts[i]) else { error = L("“%@” is not a valid value.", texts[i]); NSSound.beep(); return }
                v[i] = parsed
            }
        }
        wizard.next(v)
        refresh(forward: true)
    }

    func previous() {
        wizard.previous()
        refresh(forward: false)
    }

    func cancel() {
        wizard.cancel()
        finish(nil)
    }
}

/// The wizard sheet: one decision at a time, in the assistant's own words.
struct WizardView: View {
    @ObservedObject var model: WizardModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let content = model.content {
                        ForEach(Array(content.description.enumerated()), id: \.offset) { _, line in
                            if line.isBlank { Spacer().frame(height: 2) } else { Text(attributed(line.runs)).fixedSize(horizontal: false, vertical: true) }
                        }
                        if let step = model.step { controls(step, content) }
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 600, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.finished) { _, done in if done { dismiss() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.title).font(.subheadline).foregroundStyle(.secondary)
            Text(model.content?.title ?? "")
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Text(L("Step %@", "\(max(model.stepNumber, 1))"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button(L("Cancel"), role: .cancel) { model.cancel() }
                .keyboardShortcut(.cancelAction)
            Button(L("Previous")) { model.previous() }
                .disabled(!model.canGoBack)
            Button(L("Next")) { model.next() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canGoForward)
        }
        .padding(16)
    }

    @ViewBuilder
    private func controls(_ step: AssistantStepPresentation, _ content: WizardStepContent) -> some View {
        switch step.step.kind {
        case .radio:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(content.options.enumerated()), id: \.offset) { i, lines in
                    let selected = model.values.first == Int32(i)
                    Button { model.values = [Int32(i)] } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(selected ? Theme.victron : .secondary)
                            optionText(lines)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        case .check:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(content.options.enumerated()), id: \.offset) { i, lines in
                    Toggle(isOn: Binding(
                        get: { (model.values.first ?? 0) >> i & 1 == 1 },
                        set: { on in
                            var m = model.values.first ?? 0
                            if on { m |= 1 << Int32(i) } else { m &= ~(1 << Int32(i)) }
                            model.values = [m]
                        })) { optionText(lines) }
                        .toggleStyle(.checkbox)
                }
            }
        case .entry:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(content.entry.enumerated()), id: \.offset) { _, pieces in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in entryPiece(piece, step) }
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.drafting))
        }
    }

    @ViewBuilder
    private func entryPiece(_ piece: WizardEntryPiece, _ step: AssistantStepPresentation) -> some View {
        switch piece {
        case .text(let runs):
            Text(attributed(runs))
        case .field(let i, let items):
            if i < step.step.fields.count {
                let f = step.step.fields[i]
                if let items {
                    Picker("", selection: Binding(
                        get: { i < model.values.count ? model.values[i] : f.defaultValue },
                        set: { if i < model.values.count { model.values[i] = $0 } })) {
                        ForEach(Array(items.enumerated()), id: \.offset) { k, item in Text(item).tag(f.min + Int32(k)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                } else {
                    TextField("", text: Binding(
                        get: { i < model.texts.count ? model.texts[i] : "" },
                        set: { if i < model.texts.count { model.texts[i] = $0 } }))
                        .font(.value)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .help(L("Range %@ – %@, default %@", f.display(f.min), f.display(f.max), f.display(f.defaultValue)))
                        .onSubmit { model.next() }
                }
            }
        }
    }

    private func optionText(_ lines: [WizardLine]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { k, line in
                Text(attributed(line.runs))
                    .font(k == 0 ? .body : .callout)
                    .foregroundStyle(k == 0 ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

func attributed(_ runs: [WizardRun]) -> AttributedString {
    var out = AttributedString()
    for r in runs {
        var a = AttributedString(r.text)
        if r.bold { a.font = .body.weight(.semibold) }
        if r.emphasis { a.font = .body.italic() }
        if let link = r.link, let url = URL(string: link) { a.link = url }
        out += a
    }
    return out
}
