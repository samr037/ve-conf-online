import Foundation

/// Data-driven description of VE Configure's UI (tabs → pages → groups → controls), loaded from catalog.json.
/// Provisional: replaced by the generated catalog once docs/re/04 lands.
final class Catalog {
    static let shared = Catalog()

    func label(forSetting id: Int) -> String? { nil }
    func label(forFlag n: Int) -> String? { nil }
    func unit(forSetting id: Int) -> String? { nil }
    func gridCodeName(_ index: Int) -> String? { nil }
}
