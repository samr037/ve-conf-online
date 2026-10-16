// TEMP: replaced by ConfigDocument.canSave from fix/settings
extension ConfigDocument {
    var canSave: Bool { !changes.isEmpty }
    var saveBlockReason: String? { nil }
}
