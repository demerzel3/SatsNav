import Foundation
import RealmSwift

@MainActor
class BalancesManager: ObservableObject {
    @Published var history = [PortfolioHistoryItem]()

    var current: PortfolioHistoryItem {
        history.last ?? PortfolioHistoryItem(date: Date.now, total: 0, bonus: 0, spent: 0)
    }

    private var balances = [String: Balance]()

    private var storage = TransactionStorage()
    private let client = JSONRPCClient(hostName: "electrum1.bluewallet.io", port: 50001)

    // Addresses that are part of the onchain wallet
    private let internalAddresses = Set<Address>(knownAddresses)

    private func retrieveAndStoreTransactions(txIds: [String]) async -> [ElectrumTransaction] {
        let txIdsSet = Set<String>(txIds)
        print("requesting transaction information for", txIdsSet.count, "transactions")

        // Do not request transactions that we have already stored
        let unknownTransactionIds = await storage.notIncludedTxIds(txIds: txIdsSet)
        if unknownTransactionIds.count > 0 {
            let txRequests = Set<String>(unknownTransactionIds).map { JSONRPCRequest.getTransaction(txHash: $0, verbose: true) }
            guard let transactions: [Result<ElectrumTransaction, JSONRPCError>] = await client.send(requests: txRequests) else {
                print("🚨 Unable to get transactions")
                exit(1)
            }

            // TODO: do something with the errors maybe? at least log them!
            let validTransactions = transactions.compactMap { if case .success(let t) = $0 { t } else { nil } }
            let storageSize = await storage.store(transactions: validTransactions)
            print("Retrieved \(validTransactions.count) transactions, in store: \(storageSize)")

            // Commit transactions storage to disk
            await storage.write()
        }

        return await storage.getTransactions(byIds: txIdsSet)
    }

    // Manual transactions have usually a number of inputs (in case of consolidation)
    // but only one output, + optional change
    private func isManualTransaction(_ transaction: ElectrumTransaction) -> Bool {
        return transaction.vout.count <= 2
    }

    private func fetchOnchainTransactions(cacheOnly: Bool = false) async -> [LedgerEntry] {
        func writeCache(txIds: [String]) {
            let filePath = FileManager.default.temporaryDirectory.appendingPathComponent("rootTransactionIds.plist")
            print(filePath)
            do {
                let data = try PropertyListEncoder().encode(txIds)
                try data.write(to: filePath)
                print("Root tx ids saved successfully!")
            } catch {
                fatalError("Error saving root tx ids: \(error)")
            }
        }

        func readCache() -> [String] {
            let filePath = FileManager.default.temporaryDirectory.appendingPathComponent("rootTransactionIds.plist")
            print(filePath)
            do {
                let data = try Data(contentsOf: filePath)
                let txIds = try PropertyListDecoder().decode([String].self, from: data)
                print("Retrieved root tx ids from disk: \(txIds.count)")

                return txIds
            } catch {
                fatalError("Error retrieving root tx ids: \(error)")
            }
        }

        func electrumTransactionToLedgerEntries(_ transaction: ElectrumTransaction) async -> [LedgerEntry] {
            var totalIn: Decimal = 0
            var transactionVin = [OnchainTransaction.Vin]()
            for vin in transaction.vin {
                guard let vinTxId = vin.txid else {
                    continue
                }
                guard let vinTx = await storage.getTransaction(byId: vinTxId) else {
                    continue
                }
                guard let voutIndex = vin.vout else {
                    continue
                }

                let vout = vinTx.vout[voutIndex]
                let amount = readBtcAmount(vout.value)

                guard let vinAddress = vout.scriptPubKey.address else {
                    print("\(vinTxId):\(voutIndex) has no address")
                    continue
                }
                guard let vinScriptHash = getScriptHashForElectrum(vout.scriptPubKey) else {
                    print("Could not compute script hash for address \(vinAddress)")
                    continue
                }

                totalIn += amount
                transactionVin.append(OnchainTransaction.Vin(
                    txid: vinTxId,
                    voutIndex: voutIndex,
                    amount: amount,
                    address: Address(id: vinAddress, scriptHash: vinScriptHash)
                ))
            }

            var totalOut: Decimal = 0
            var transactionVout = [OnchainTransaction.Vout]()
            for vout in transaction.vout {
                guard let voutAddress = vout.scriptPubKey.address else {
                    continue
                }
                guard let voutScriptHash = getScriptHashForElectrum(vout.scriptPubKey) else {
                    print("Could not compute script hash for address \(voutAddress)")
                    continue
                }

                let amount = readBtcAmount(vout.value)
                totalOut += amount
                transactionVout.append(OnchainTransaction.Vout(
                    amount: amount,
                    address: Address(id: voutAddress, scriptHash: voutScriptHash)
                ))
            }

            let (knownVin, _) = transactionVin.partition { internalAddresses.contains($0.address) }
            let (knownVout, unknownVout) = transactionVout.partition { internalAddresses.contains($0.address) }

            let fees = totalIn - totalOut
            let types: [(LedgerEntry.LedgerEntryType, Decimal)] = if
                knownVin.count == transaction.vin.count,
                knownVout.count == transaction.vout.count
            {
                // vin and vout are all known, it's consolidation or internal transaction, we track each output separately
                transactionVout.flatMap { [(.withdrawal, $0.amount), (.deposit, $0.amount)] } + [(.fee, -fees)]
            } else if knownVin.count == transaction.vin.count {
                // All vin known, it must be a transfer out of some kind
                [
                    (.withdrawal, -unknownVout.reduce(0) { sum, vout in sum + vout.amount }),
                    (.fee, -fees),
                ]
            } else if knownVin.count == 0 {
                // No vin is known, must be a deposit.
                // Split by vout in case we are receiving multiple from different sources, easier to match.
                knownVout.map { (.deposit, $0.amount) }
            } else {
                [(.transfer, 0)]
            }

            let date = Date(timeIntervalSince1970: TimeInterval(transaction.time ?? 0))

            return types.enumerated().map { index, item in LedgerEntry(
                wallet: "❄️",
                id: types.count > 1 ? "\(transaction.txid)-\(index)" : transaction.txid,
                groupId: transaction.txid,
                date: date,
                type: item.0,
                amount: item.1,
                asset: .init(name: "BTC", type: .crypto)
            ) }
        }

        func fetchRootTransactionIds() async -> [String] {
            let internalAddressesList = internalAddresses.map { $0 }
            let historyRequests = internalAddressesList
                .map { address in
                    JSONRPCRequest.getScripthashHistory(scriptHash: address.scriptHash)
                }
            print("Requesting transactions for \(historyRequests.count) addresses")
            guard let history: [Result<GetScriptHashHistoryResult, JSONRPCError>] = await client.send(requests: historyRequests) else {
                fatalError("🚨 Unable to get history")
            }

            // Collect transaction ids and log failures.
            var txIds = [String]()
            for (address, res) in zip(internalAddressesList, history) {
                switch res {
                case .success(let history):
                    txIds.append(contentsOf: history.map { $0.tx_hash })
                case .failure(let error):
                    print("🚨 history request failed for address \(address.id)", error)
                }
            }
            // Save collected txids to cache
            writeCache(txIds: txIds)

            return txIds
        }

        let txIds = cacheOnly ? readCache() : await fetchRootTransactionIds()
        let rootTransactions = await retrieveAndStoreTransactions(txIds: txIds)
        let refTransactionIds = rootTransactions
            .filter { isManualTransaction($0) }
            .flatMap { transaction in transaction.vin.map { $0.txid } }
            .compactMap { $0 }
        _ = await retrieveAndStoreTransactions(txIds: refTransactionIds)

        var entries = [LedgerEntry]()
        for rawTransaction in rootTransactions {
            entries.append(contentsOf: await electrumTransactionToLedgerEntries(rawTransaction))
        }

        return entries
    }

    private func buildLedger() async -> [LedgerEntry] {
        // TODO: only start the JSONRPCClient when we actually need it
        // client.start()
        await storage.read()

        // TODO: add proper error handling
        var ledgers = try! await readCSVFiles(config: [
            (CoinbaseCSVReader(), "Coinbase.csv"),
            (CelsiusCSVReader(), "Celsius.csv"),
            (KrakenCSVReader(), "Kraken.csv"),
            (BlockFiCSVReader(), "BlockFi.csv"),
            (LednCSVReader(), "Ledn.csv"),
            (CoinifyCSVReader(), "Coinify.csv"),

            // TODO: add proper blockchain support?
            (EtherscanCSVReader(), "Eth.csv"),
            (CryptoIdCSVReader(), "Ltc.csv"),
            (DogeCSVReader(), "Doge.csv"),
            (RippleCSVReader(), "Ripple.csv"),
            (DefiCSVReader(), "Defi.csv"),
            (LiquidCSVReader(), "Liquid.csv"),
        ])
        ledgers.append(contentsOf: await fetchOnchainTransactions(cacheOnly: true))
        let ledgersCountBeforeIgnore = ledgers.count
        ledgers = ledgers.filter { ledgersMeta["\($0.wallet)-\($0.id)"].map { !$0.ignored } ?? true }
        guard ledgers.count - ledgersCountBeforeIgnore < ledgersMeta.map({ $1.ignored }).count else {
            fatalError("Some entries in blocklist were not found in the ledger")
        }

        ledgers.sort(by: { a, b in a.date < b.date })

        return ledgers
    }

    func load() async {
        let start = Date.now
        let realm = try! await Realm()
        let ledgers = realm.objects(LedgerEntry.self).sorted { a, b in a.date < b.date }
        print("Loaded after \(Date.now.timeIntervalSince(start))s \(ledgers.count)")
        let groupedLedgers = groupLedgers(ledgers: ledgers)
        print("Grouped after \(Date.now.timeIntervalSince(start))s \(groupedLedgers.count)")
        balances = buildBalances(groupedLedgers: groupedLedgers)
        print("Built balances after \(Date.now.timeIntervalSince(start))s \(balances.count)")

        verify(balances: balances, getLedgerById: { id in
            realm.object(ofType: LedgerEntry.self, forPrimaryKey: id)
        })

        history = buildBtcHistory(balances: balances, getLedgerById: { id in
            realm.object(ofType: LedgerEntry.self, forPrimaryKey: id)
        })
        print("Ready after \(Date.now.timeIntervalSince(start))s")
    }

    func merge(_ newEntries: [LedgerEntry]) async {
        let realm = try! await Realm()
        let ids = newEntries.map { $0.globalId }
        try! realm.write {
            let entriesToDelete = realm.objects(LedgerEntry.self).where {
                $0.globalId.in(ids)
            }

            print("-- Deleting \(entriesToDelete.count) entries")
            realm.delete(entriesToDelete)
            print("-- Deleted \(entriesToDelete.count) entries")

            for entry in newEntries {
                realm.add(entry)
            }
            print("-- Added \(newEntries.count) entries")
        }

        await load()
    }

    func update() async {
        let start = Date.now
        let ledgers = await buildLedger()
        print("Built ledgers after \(Date.now.timeIntervalSince(start))s")
        let ledgersIndex = ledgers.reduce(into: [String: LedgerEntry]()) { index, entry in
            assert(index[entry.globalId] == nil, "duplicated global id \(entry.globalId)")

            index[entry.globalId] = entry
        }
        print("Built index after \(Date.now.timeIntervalSince(start))s")

        let groupedLedgers = groupLedgers(ledgers: ledgers)
        print("Grouped after \(Date.now.timeIntervalSince(start))s")
        balances = buildBalances(groupedLedgers: groupedLedgers)
        print("Built balances after \(Date.now.timeIntervalSince(start))s")

        verify(balances: balances, getLedgerById: { ledgersIndex[$0] })

        // Persist all ledger entries
        let realm = try! await Realm()
        try! realm.write {
            for entry in ledgers {
                realm.add(entry)
            }
        }
        print("Persisted after \(Date.now.timeIntervalSince(start))s")

        // portfolioTotal = balances.values.reduce(0) { $0 + ($1[BTC]?.sum ?? 0) }
        // totalAcquisitionCost = balances.values.reduce(0) { $0 + ($1[BTC]?.reduce(0) { tot, ref in tot + ref.amount * (ref.rate ?? 0) } ?? 0) }
        // portfolioHistory = buildBtcHistory(balances: balances, ledgersIndex: self.ledgersIndex)
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
            assert(withoutRate < 0.032, "Something broke in the grouping")

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
}
