import Foundation
import RealmSwift

struct WalletRecap: Identifiable {
    let wallet: String
    let count: Int

    var id: String { wallet }
}

@MainActor
class BalancesManager: ObservableObject {
    @Published var history = [PortfolioHistoryItem]()
    @Published var recap = [WalletRecap]()
    private let credentials: Credentials

    var current: PortfolioHistoryItem {
        history.last ?? PortfolioHistoryItem(date: Date.now, total: 0, bonus: 0, spent: 0)
    }

    private var balances = [String: Balance]()

    init(credentials: Credentials) {
        self.credentials = credentials
    }

    func load() async {
        let start = Date.now
        let realm = try! await getRealm()
        let ledgers = realm.objects(LedgerEntry.self).sorted { a, b in a.date < b.date }
        print("Loaded after \(Date.now.timeIntervalSince(start))s \(ledgers.count)")
        let groupedLedgers = groupLedgers(ledgers: ledgers)
        print("Grouped after \(Date.now.timeIntervalSince(start))s \(groupedLedgers.count)")
        balances = buildBalances(groupedLedgers: groupedLedgers, debug: false)
        print("Built balances after \(Date.now.timeIntervalSince(start))s \(balances.count)")

        verify(balances: balances, getLedgerById: { id in
            realm.object(ofType: LedgerEntry.self, forPrimaryKey: id)
        })

        history = buildBtcHistory(balances: balances, getLedgerById: { id in
            realm.object(ofType: LedgerEntry.self, forPrimaryKey: id)
        })
        print("Ready after \(Date.now.timeIntervalSince(start))s")

        recap = ledgers.reduce(into: [String: Int]()) { dict, entry in
            dict[entry.wallet, default: 0] += 1
        }.map { (key: String, value: Int) in
            WalletRecap(wallet: key, count: value)
        }.sorted(by: { a, b in
            a.wallet < b.wallet
        })
    }

    func merge(_ newEntries: [LedgerEntry]) async {
        let realm = try! await getRealm()
        print("-- MERGING")
        try! realm.write {
            var deletedCount = 0
            for entry in newEntries {
                if let oldEntry = realm.object(ofType: LedgerEntry.self, forPrimaryKey: entry.globalId) {
                    realm.delete(oldEntry)
                    deletedCount += 1
                }
                realm.add(entry)
            }
            print("-- Deleted \(deletedCount) entries")
            print("-- Added \(newEntries.count) entries")
        }
        print("-- MERGING ENDED")

        await load()
    }

    private func verify(balances: [String: Balance], getLedgerById: (String) -> LedgerEntry?) {
        if let btcColdStorage = balances["❄️"]?[BTC] {
            print("-- Cold storage --")
            print("total", btcColdStorage.sum)

            let enrichedRefs: [(ref: Ref, entry: LedgerEntry, comment: String?)] = btcColdStorage
                .compactMap {
                    guard let entry = getLedgerById($0.refId) else {
                        print("Entry not found \($0.refId)")
                        return nil
                    }

                    return ($0, entry, ledgersMeta[$0.refId].flatMap { $0.comment })
                }
            // .filter { $0.entry.type != .bonus && $0.entry.type != .interest }
            // .filter { $0.ref.rate == nil }
            // .sorted { a, b in a.ref.refIds.count > b.ref.refIds.count }
            // .sorted { a, b in a.ref.date < b.ref.date }
            // .sorted { a, b in a.ref.rate ?? 0 < b.ref.rate ?? 0 }

            let withoutRate = enrichedRefs
                .filter { $0.entry.type != .bonus && $0.entry.type != .interest && $0.ref.rate == nil }
                .map { $0.ref }
                .sum
            print("Without rate \(withoutRate)")
            // assert(withoutRate < 0.032, "Something broke in the grouping")

            let oneSat = Decimal(string: "0.00000001")!
            print("Below 1 sat:", enrichedRefs.filter { $0.ref.amount < oneSat }.count, "/", enrichedRefs.count)
//            for (ref, _, comment) in enrichedRefs where ref.amount < oneSat {
//                // let spent = formatFiatAmount(ref.amount * (ref.rate ?? 0))
//                let rate = formatFiatAmount(ref.rate ?? 0)
//                let amount = formatBtcAmount(ref.amount)
//                print("\(ref.date) \(amount) \(rate) (\(ref.count))\(comment.map { _ in " 💬" } ?? "")")
            ////                for refId in ref.refIds {
            ////                    print(ledgersIndex[refId]!)
            ////                }
            ////                break
//            }
        }
    }

    private func getRealm() async throws -> Realm {
        let configuration = Realm.Configuration(encryptionKey: credentials.localStorageEncryptionKey)

        return try await Realm(configuration: configuration)
    }
}
