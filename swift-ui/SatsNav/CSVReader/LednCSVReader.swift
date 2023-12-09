
import Foundation
import SwiftCSV

private func createDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    // Set the locale to ensure that the date formatter doesn't get affected by the user's locale.
    formatter.locale = Locale(identifier: "en_US_POSIX")

    return formatter
}

class LednCSVReader: CSVReader {
    private let dateFormatter = createDateFormatter()

    func read(fileUrl: URL) async throws -> [LedgerEntry] {
        // Breaking down the components
        let directoryUrl = fileUrl.deletingLastPathComponent()
        let fileNameWithoutExtension = fileUrl.deletingPathExtension().lastPathComponent
        let patchFileName = "\(fileNameWithoutExtension).patch.csv"
        let patchFileUrl = directoryUrl.appendingPathComponent(patchFileName)

        let csv: CSV = try CSV<Named>(url: fileUrl)
        let patchCsv: CSV = try CSV<Named>(url: patchFileUrl)

        // Posted Date,Source,Amount,Type,Currency,Ledn Fee Amount,Fee Currency,Status,Blockchain,Txn ID,Txn Hash,Direction of funds
        func readRow(_ dict: [String: String]) {
            let id = dict["Txn ID"] ?? ""
            let groupId = id.split(separator: "-", maxSplits: 2).first.map { String($0) } ?? id
            let source = dict["Source"] ?? ""
            // This is a made up entry to make sense of the rows related to B2X, only used in patch
            // TODO: allocate these funds to a "Ledn-Loan" wallet or something in case they don't cancel out
            if source == "Collateral" {
                ledgers.removeValue(forKey: id)
                return
            }

            let type: LedgerEntry.LedgerEntryType = switch dict["Source"] ?? "" {
            case "Interest": .interest
            case "Withdrawal": .withdrawal
            case "Deposit": .deposit
            case "Trade": .trade
            case "Fee": .fee
            // This gets overridden by the patch anyways
            case "B2X": .transfer
            default:
                fatalError("Unexpected Ledn transaction type: \(dict["Source"] ?? "undefined")")
            }

            let date = self.dateFormatter.date(from: dict["Posted Date"] ?? "") ?? Date.now
            let fee = Decimal(string: dict["Ledn Fee Amount"] ?? "0") ?? 0
            let isSending = dict["Direction of funds"] == "Sending"
            let amount = (Decimal(string: dict["Amount"] ?? "0") ?? 0) - fee
            let asset = Asset(name: dict["Currency"] ?? "", type: .crypto)

            ledgers[id] = LedgerEntry(
                wallet: "Ledn",
                id: id,
                groupId: groupId,
                date: date,
                type: type,
                amount: (isSending ? -1 : 1) * amount,
                asset: asset
            )

            if fee > 0 {
                ledgers["\(id)-2"] = LedgerEntry(
                    wallet: "Ledn",
                    id: "\(id)-2",
                    groupId: id,
                    date: date,
                    type: .fee,
                    amount: -fee,
                    asset: asset
                )
            }
        }

        var ledgers = [String: LedgerEntry]()
        try csv.enumerateAsDict(readRow)
        try patchCsv.enumerateAsDict(readRow)

        return ledgers.values.map { $0 }
    }
}
