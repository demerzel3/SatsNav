import Collections
import CryptoKit
import Foundation
import Grammar
import JSON
import JSONDecoding
import KrakenAPI
import SwiftCSV

private let btcFormatter = createNumberFormatter(minimumFractionDigits: 8, maximumFranctionDigits: 8)
private let fiatFormatter = createNumberFormatter(minimumFractionDigits: 2, maximumFranctionDigits: 2)
private let cryptoRateFormatter = createNumberFormatter(minimumFractionDigits: 0, maximumFranctionDigits: 6)
private let fiatRateFormatter = createNumberFormatter(minimumFractionDigits: 0, maximumFranctionDigits: 2)

private let client = JSONRPCClient(hostName: "electrum1.bluewallet.io", port: 50001)
// private let client = JSONRPCClient(hostName: "bitcoin.lu.ke", port: 50001)
client.start()

private let storage = TransactionStorage()
// Restore transactions storage from disk
await storage.read()

// Addresses that are part of the onchain wallet
private let internalAddresses = Set<Address>(knownAddresses)

func readCSVFiles(config: [(CSVReader, String)]) async throws -> [LedgerEntry] {
    var entries = [LedgerEntry]()

    try await withThrowingTaskGroup(of: [LedgerEntry].self) { group in
        for (reader, filePath) in config {
            group.addTask {
                try await reader.read(filePath: filePath)
            }
        }

        for try await fileEntries in group {
            entries.append(contentsOf: fileEntries)
        }
    }

    return entries
}

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

@MainActor
private func fetchOnchainTransactions(cacheOnly: Bool = false) async -> [LedgerEntry] {
    func writeCache(txIds: [String]) {
        let filePath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("rootTransactionIds.plist")
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
        let filePath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("rootTransactionIds.plist")
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

func satsToBtc(_ amount: Int) -> String {
    btcFormatter.string(from: Double(amount) / 100000000 as NSNumber)!
}

func btcToSats(_ amount: Decimal) -> Int {
    NSDecimalNumber(decimal: amount * 100000000).intValue
}

@MainActor
func electrumTransactionToLedgerEntries(_ transaction: ElectrumTransaction) async -> [LedgerEntry] {
    var totalIn = 0
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
        let sats = btcToSats(Decimal(vout.value))

        guard let vinAddress = vout.scriptPubKey.address else {
            print("\(vinTxId):\(voutIndex) has no address")
            continue
        }
        guard let vinScriptHash = getScriptHashForElectrum(vout.scriptPubKey) else {
            print("Could not compute script hash for address \(vinAddress)")
            continue
        }

        totalIn += sats
        transactionVin.append(OnchainTransaction.Vin(
            txid: vinTxId,
            voutIndex: voutIndex,
            sats: sats,
            address: Address(id: vinAddress, scriptHash: vinScriptHash)
        ))
    }

    var totalOut = 0
    var transactionVout = [OnchainTransaction.Vout]()
    for vout in transaction.vout {
        guard let voutAddress = vout.scriptPubKey.address else {
            continue
        }
        guard let voutScriptHash = getScriptHashForElectrum(vout.scriptPubKey) else {
            print("Could not compute script hash for address \(voutAddress)")
            continue
        }

        let sats = btcToSats(Decimal(vout.value))
        totalOut += sats
        transactionVout.append(OnchainTransaction.Vout(
            sats: sats,
            address: Address(id: voutAddress, scriptHash: voutScriptHash)
        ))
    }

    let (knownVin, _) = transactionVin.partition { internalAddresses.contains($0.address) }
    let (knownVout, unknownVout) = transactionVout.partition { internalAddresses.contains($0.address) }

    let satsFees = totalOut - totalIn
    let types: [(LedgerEntry.LedgerEntryType, Int)] = if
        knownVin.count == transaction.vin.count,
        knownVout.count == transaction.vout.count
    {
        // vin and vout are all known, it's consolidation or internal transaction, we only track the fees
        [(.fee, -satsFees)]
    } else if knownVin.count == transaction.vin.count {
        // All vin known, it must be a transfer out of some kind
        [
            (.withdrawal, -unknownVout.reduce(0) { sum, vout in sum + vout.sats }),
            (.fee, satsFees),
        ]
    } else if knownVin.count == 0 {
        // No vin is known, must be a deposit
        [(.deposit, knownVout.reduce(0) { sum, vout in sum + vout.sats })]
    } else {
        [(.transfer, 0)]
    }

    let date = Date(timeIntervalSince1970: TimeInterval(transaction.time ?? 0))

    return types.map { type, satsAmount in LedgerEntry(
        wallet: "❄️",
        id: transaction.txid,
        groupId: transaction.txid,
        date: date,
        type: type,
        amount: Decimal(satsAmount) / 100000000,
        asset: .init(name: "BTC", type: .crypto)
    ) }
}

func formatAmount(_ entry: LedgerEntry) -> String {
    let asset = entry.asset
    let amount = entry.amount

    return "\(asset.name) \(asset.type == .crypto ? btcFormatter.string(from: amount as NSNumber)! : fiatFormatter.string(from: amount as NSNumber)!)"
}

func formatRate(_ optionalRate: Decimal?, spendType: LedgerEntry.AssetType = .crypto) -> String {
    guard let rate = optionalRate else {
        return "unknown"
    }

    switch spendType {
    case .crypto: return cryptoRateFormatter.string(from: rate as NSNumber)!
    case .fiat: return fiatRateFormatter.string(from: rate as NSNumber)!
    }
}

struct Ref {
    // "\(wallet)-\(id)"
    let wallet: String
    let id: String
    let amount: Decimal
    let rate: Decimal?
}

typealias RefsDeque = Deque<Ref>
typealias RefsArray = [Ref]
typealias Balance = [LedgerEntry.Asset: RefsDeque]

/**
 Removes refs from asset balance using FIFO strategy
 */
func subtract(refs: inout RefsDeque, amount: Decimal) -> RefsArray {
    guard amount >= 0 else {
        fatalError("amount must be positive")
    }

    // Remove refs from asset balance using FIFO strategy
    var subtractedRefs = RefsArray()
    var totalRemoved: Decimal = 0
    while totalRemoved < amount {
        let removed = refs.removeFirst()
        totalRemoved += removed.amount
        subtractedRefs.append(removed)
    }

    if totalRemoved > amount {
        let leftOnBalance = totalRemoved - amount
        guard let last = subtractedRefs.popLast() else {
            fatalError("This should definitely never happen")
        }
        // Put leftover back to top of refs
        refs.insert(Ref(wallet: last.wallet, id: last.id, amount: leftOnBalance, rate: last.rate), at: 0)
        // Add rest to removed refs
        subtractedRefs.append(Ref(wallet: last.wallet, id: last.id, amount: last.amount - leftOnBalance, rate: last.rate))
    }

    return subtractedRefs
}

private var ledgers = try await readCSVFiles(config: [
    (CoinbaseCSVReader(), "../data/Coinbase.csv"),
    (CelsiusCSVReader(), "../data/Celsius.csv"),
    (KrakenCSVReader(), "../data/Kraken.csv"),
    (BlockFiCSVReader(), "../data/BlockFi.csv"),
    (LednCSVReader(), "../data/Ledn.csv"),
])
ledgers.append(contentsOf: await fetchOnchainTransactions(cacheOnly: true))
ledgers.sort(by: { a, b in a.date < b.date })

////             [Wallet:[Asset:balance]]
// var balances = [String: [LedgerEntry.Asset: Decimal]]()
// for entry in ledgers {
//    balances[entry.wallet, default: [LedgerEntry.Asset: Decimal]()][entry.asset, default: 0] += entry.amount
// }
//
// for (wallet, assets) in balances {
//    print("--- \(wallet) ---")
//    for (asset, amount) in assets {
//        print("\(asset.name) \(asset.type == .crypto ? btcFormatter.string(from: amount as NSNumber)! : fiatFormatter.string(from: amount as NSNumber)!)")
//    }
// }

// for entry in ledgers where (entry.type == .Deposit || entry.type == .Withdrawal) && entry.asset.name == "BTC" {
//    print("\(entry.date) \(entry.wallet) \(entry.type) \(formatAmount(entry))")
// }

enum GroupedLedger {
    // Single transaction within a wallet (e.g. Fee, Interest, Bonus) or ungrouped ledger entry
    case single(entry: LedgerEntry)
    // Trade within a single wallet
    case trade(spend: LedgerEntry, receive: LedgerEntry)
    // Transfer between wallets
    case transfer(from: LedgerEntry, to: LedgerEntry)
}

let groupedLedgers: [GroupedLedger] = ledgers.reduce(into: [String: [LedgerEntry]]()) { groupIdToLedgers, entry in
    switch entry.type {
    // Group trades by ledger-provided groupId
    case .trade:
        groupIdToLedgers["\(entry.wallet)-\(entry.groupId)", default: [LedgerEntry]()].append(entry)
    // Group deposit and withdrawals by amount (may lead to false positives)
    case .deposit where entry.asset.type == .crypto,
         .withdrawal where entry.asset.type == .crypto:
        var id = "\(entry.asset.name)-\(btcFormatter.string(from: abs(entry.amount) as NSNumber)!)"

        // Skip until we find a suitable group, greedy strategy
        while groupIdToLedgers[id]?.count == 2 ||
            groupIdToLedgers[id]?[0].type == entry.type
        {
            id += "-"
        }

        groupIdToLedgers[id, default: [LedgerEntry]()].append(entry)
    default:
        // Avoid grouping other ledger entries
        groupIdToLedgers[UUID().uuidString] = [entry]
    }

    // let groupId = "\(entry.wallet)-\(entry.groupId)\(entry.type == .Fee ? "-fee" : "")"
    // groupIdToLedgers[groupId, default: [LedgerEntry]()].append(entry)
}.values.sorted { a, b in
    a[0].date < b[0].date
}.flatMap { group -> [GroupedLedger] in
    switch group.count {
    case 1: return [.single(entry: group[0])]
    case 2 where group[0].type == .trade && group[0].amount > 0: return [.trade(spend: group[1], receive: group[0])]
    case 2 where group[0].type == .trade && group[0].amount <= 0: return [.trade(spend: group[0], receive: group[1])]
    case 2 where group[0].type == .withdrawal && group[1].type == .deposit && group[0].wallet != group[1].wallet:
        return [.transfer(from: group[0], to: group[1])]
    case 2 where group[0].type == .deposit && group[1].type == .withdrawal && group[0].wallet != group[1].wallet:
        return [.transfer(from: group[1], to: group[0])]
    case 2 where group[0].type == group[1].type || group[0].wallet == group[1].wallet:
        // Wrongly matched by amount, ungroup!
        return [.single(entry: group[0]), .single(entry: group[1])]
    default:
        print(group)
        fatalError("Group has more than 2 elements")
    }
}

let BASE_ASSET = LedgerEntry.Asset(name: "EUR", type: .fiat)

//             [Wallet: Balance]
var balances = [String: Balance]()
for group in groupedLedgers {
    switch group {
    case .single(let entry):
        print("\(entry.wallet) \(entry.type) \(formatAmount(entry))")

        // Not keeping track of base asset
        guard entry.asset != BASE_ASSET else {
            continue
        }

        var refs = balances[entry.wallet, default: Balance()][entry.asset, default: RefsDeque()]
        if entry.amount > 0 {
            refs.append(Ref(wallet: entry.wallet, id: entry.id, amount: entry.amount, rate: nil))
        } else {
            let removedRefs = subtract(refs: &refs, amount: -entry.amount)

            if entry.type == .withdrawal {
                let refsString = refs.map { "\($0.amount)@\(formatRate($0.rate, spendType: .fiat))" }.joined(separator: ", ")
                let removedRefsString = removedRefs.map { "\($0.amount)@\(formatRate($0.rate, spendType: .fiat))" }.joined(separator: ", ")
                print("  refs: \(removedRefsString)")
                print("  balance: \(refsString)")
            }
        }
        balances[entry.wallet, default: Balance()][entry.asset] = refs
    case .transfer(let from, let to):
        if from.wallet == to.wallet {
            print("noop internal transfer \(from.wallet) \(formatAmount(to))")
            continue
        }
        print("TRANSFER! \(from.wallet) -> \(to.wallet) \(formatAmount(to))")
        fatalError("Not implemented!")
    case .trade(let spend, let receive):
        let rate = (-spend.amount / receive.amount)
        print("\(spend.wallet) trade! spent \(formatAmount(spend)), received \(formatAmount(receive)) @\(formatRate(rate, spendType: spend.asset.type))")

        if spend.asset != BASE_ASSET {
            // "move" refs to receive balance
            var refs = balances[spend.wallet, default: Balance()][spend.asset, default: RefsDeque()]
            let removedRefs = subtract(refs: &refs, amount: -spend.amount)

            // Propagate rate to receive side
            let receiveRefs = removedRefs.map {
                Ref(wallet: $0.wallet, id: $0.id, amount: $0.amount / rate, rate: $0.rate != nil ? $0.rate! * rate : nil)
            }

            balances[spend.wallet, default: Balance()][spend.asset] = refs
            balances[receive.wallet, default: Balance()][receive.asset, default: RefsDeque()]
                .append(contentsOf: receiveRefs)
            break
        }

        if receive.asset != BASE_ASSET {
            // Add ref to balance
            let ref = Ref(wallet: receive.wallet, id: receive.groupId, amount: receive.amount, rate: rate)
            balances[receive.wallet, default: Balance()][receive.asset, default: RefsDeque()].append(ref)
        }
    }
}

/*
 NEXT STEPS
  - track onchain fees separately from withdrawal transactions
  - match deposits with withdrawals before starting the balances exercise so that they can handled at the same time
 */
