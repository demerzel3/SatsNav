import Foundation

struct LedgerEntry {
    enum LedgerEntryType {
        case deposit
        case withdrawal
        case trade
        case interest
        case bonus
        case fee
        case transfer // Fallback
    }

    enum AssetType {
        case fiat
        case crypto
    }

    struct Asset: Hashable {
        let name: String
        let type: AssetType
    }

    let wallet: String
    let id: String
    let groupId: String // Useful to group together ledgers from the same provider, usually part of the same transaction
    let date: Date
    let type: LedgerEntryType
    let amount: Decimal
    let asset: Asset
}

protocol CSVReader {
    func read(filePath: String) async throws -> [LedgerEntry]
}
