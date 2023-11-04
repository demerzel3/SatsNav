import Foundation
import SwiftCSV

func createNumberFormatter(minimumFractionDigits: Int, maximumFranctionDigits: Int) -> NumberFormatter {
    let formatter = NumberFormatter()
    formatter.minimumFractionDigits = minimumFractionDigits
    formatter.maximumFractionDigits = maximumFranctionDigits

    return formatter
}

class KrakenCSVReader: CSVReader {
    private let rateFormatterFiat = createNumberFormatter(minimumFractionDigits: 0, maximumFranctionDigits: 4)
    private let rateFormatterCrypto = createNumberFormatter(minimumFractionDigits: 0, maximumFranctionDigits: 10)

    private enum AssetType {
        case fiat
        case crypto
    }

    private struct Asset {
        let name: String
        let type: AssetType

        init(fromTicker ticker: String) {
            switch ticker {
            case "XXBT":
                self.name = "BTC"
                self.type = .crypto
            case "XXDG":
                self.name = "DOGE"
                self.type = .crypto
            case let a where a.starts(with: "X"):
                self.name = String(a.dropFirst())
                self.type = .crypto
            case let a where a.starts(with: "Z"):
                self.name = String(a.dropFirst())
                self.type = .fiat
            default:
                self.name = ticker
                self.type = .crypto
            }
        }
    }

    private struct LedgerEntry {
        let txId: String
        let refId: String
        let time: String
        let type: String
        let asset: Asset
        let amount: Decimal
    }

    private struct Trade {
        let from: Asset
        let fromAmount: Decimal
        let to: Asset
        let toAmount: Decimal
        let rate: Decimal

        init?(fromLedgers entries: [LedgerEntry]) {
            if entries.count < 2 {
                return nil
            }

            if entries[0].amount < 0 {
                self.from = entries[0].asset
                self.fromAmount = -entries[0].amount
                self.to = entries[1].asset
                self.toAmount = entries[1].amount
            } else {
                self.from = entries[1].asset
                self.fromAmount = -entries[1].amount
                self.to = entries[0].asset
                self.toAmount = entries[0].amount
            }

            self.rate = fromAmount / toAmount
        }
    }

    func read(filePath: String) async throws -> [Transaction] {
        let csv: CSV = try CSV<Named>(url: URL(fileURLWithPath: filePath))

        var ledgers = [LedgerEntry]()
        var ledgersByRefId = [String: [LedgerEntry]]()
        // "txid","refid","time","type","subtype","aclass","asset","amount","fee","balance"
        try csv.enumerateAsDict { dict in
            let entry = LedgerEntry(txId: dict["txid"] ?? "",
                                    refId: dict["refid"] ?? "",
                                    time: dict["time"] ?? "",
                                    type: dict["type"] ?? "",
                                    asset: Asset(fromTicker: dict["asset"] ?? ""),
                                    amount: Decimal(string: dict["amount"] ?? "0") ?? 0)
            ledgers.append(entry)
            if !entry.refId.isEmpty {
                ledgersByRefId[entry.refId, default: []].append(entry)
            }
        }

        let ledgersGroupedByRefId = ledgersByRefId.values.filter { $0.count > 1 }

        print(ledgers.count)
        print(ledgersByRefId.count)

        // TODO: convert to shared "Transaction"
        return [Transaction(
            provider: .Kraken,
            id: "AAA-AAA-AAA",
            date: Date.now,
            type: .Withdrawal,
            amount: 0.0001,
            asset: Transaction.Asset(name: "BTC", type: .crypto)
        )]
    }

    private func printTrade(entries: [LedgerEntry]) {
        guard let trade = Trade(fromLedgers: entries) else {
            return
        }

        let rateFormatter = trade.from.type == .fiat ? rateFormatterFiat : rateFormatterCrypto

        if trade.from.name != "EUR" || trade.to.name != "BTC" {
            return
        }
        print("Traded", trade.fromAmount, trade.from.name, "for", trade.toAmount, trade.to.name, "@", rateFormatter.string(for: trade.rate)!)
    }
}
