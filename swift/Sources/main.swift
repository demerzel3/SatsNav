import CryptoKit
import Foundation
import Grammar
import JSON
import JSONDecoding
import KrakenAPI
import SwiftCSV

private let btcFormatter = createNumberFormatter(minimumFractionDigits: 8, maximumFranctionDigits: 8)
private let fiatFormatter = createNumberFormatter(minimumFractionDigits: 2, maximumFranctionDigits: 2)

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
private func getOnchainTransactions() async -> [LedgerEntry] {
    let internalAddressesList = internalAddresses.map { $0 }
    let historyRequests = internalAddressesList
        .map { address in
            JSONRPCRequest.getScripthashHistory(scriptHash: address.scriptHash)
        }
    print("Requesting transactions for \(historyRequests.count) addresses")
    guard let history: [Result<GetScriptHashHistoryResult, JSONRPCError>] = await client.send(requests: historyRequests) else {
        print("🚨 Unable to get history")
        exit(1)
    }

    // Collect transaction ids and log failures.
    var txIds = [String]()
    var txIdToAddress = [String: Address]()
    for (address, res) in zip(internalAddressesList, history) {
        switch res {
        case .success(let history):
            let historyTxIds = history.map { $0.tx_hash }
            txIds.append(contentsOf: historyTxIds)
            for txId in historyTxIds {
                txIdToAddress[txId] = address
            }
        case .failure(let error):
            print("🚨 history request failed for address \(address.id)", error)
        }
    }

    let rootTransactions = await retrieveAndStoreTransactions(txIds: txIds)
    let refTransactionIds = rootTransactions
        .filter { isManualTransaction($0) }
        .flatMap { transaction in transaction.vin.map { $0.txid } }
        .compactMap { $0 }
    _ = await retrieveAndStoreTransactions(txIds: refTransactionIds)

    var entries = [LedgerEntry]()
    for rawTransaction in rootTransactions {
        entries.append(await electrumTransactionToLedgerEntry(rawTransaction))
    }

    return entries
}

func satsToBtc(_ amount: Int) -> String {
    btcFormatter.string(from: Double(amount) / 100000000 as NSNumber)!
}

func btcToSats(_ amount: Double) -> Int {
    Int(amount * 100000000)
}

@MainActor
func electrumTransactionToLedgerEntry(_ transaction: ElectrumTransaction) async -> LedgerEntry {
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
        let sats = btcToSats(vout.value)

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

        let sats = btcToSats(vout.value)
        totalOut += sats
        transactionVout.append(OnchainTransaction.Vout(
            sats: sats,
            address: Address(id: voutAddress, scriptHash: voutScriptHash)
        ))
    }

    let (knownVin, _) = transactionVin.partition { internalAddresses.contains($0.address) }
    let (knownVout, unknownVout) = transactionVout.partition { internalAddresses.contains($0.address) }

    let satsFees = totalOut - totalIn
    let (type, satsAmount): (LedgerEntry.LedgerEntryType, Int) = if
        knownVin.count == transaction.vin.count,
        knownVout.count == transaction.vout.count
    {
        // vin and vout are all known, it's consolidation transaction
        (.Transfer, -satsFees)
    } else if knownVin.count == transaction.vin.count {
        // All vin known, it must be a transfer out of some kind
        (.Withdrawal, -unknownVout.reduce(0) { sum, vout in sum + vout.sats } + satsFees)
    } else if knownVin.count == 0 {
        // No vin is known, must be a deposit
        (.Deposit, knownVout.reduce(0) { sum, vout in sum + vout.sats })
    } else {
        (.Transfer, 0)
    }

    let date = Date(timeIntervalSince1970: TimeInterval(transaction.time ?? 0))

    return LedgerEntry(
        wallet: "❄️",
        id: transaction.txid,
        groupId: transaction.txid,
        date: date,
        type: type,
        amount: Decimal(satsAmount) / 100000000,
        asset: .init(name: "BTC", type: .crypto)
    )
}

private var ledgers = try await readCSVFiles(config: [
    (CoinbaseCSVReader(), "../data/Coinbase.csv"),
    (CelsiusCSVReader(), "../data/Celsius.csv"),
    (KrakenCSVReader(), "../data/Kraken.csv"),
    (BlockFiCSVReader(), "../data/BlockFi.csv"),
    (LednCSVReader(), "../data/Ledn.csv"),
])
ledgers.append(contentsOf: await getOnchainTransactions())
ledgers.sort(by: { a, b in a.date < b.date })

//             [Wallet:[Asset:balance]]
var balances = [String: [LedgerEntry.Asset: Decimal]]()
for entry in ledgers {
    balances[entry.wallet, default: [LedgerEntry.Asset: Decimal]()][entry.asset, default: 0] += entry.amount
}

for (wallet, assets) in balances {
    print("--- \(wallet) ---")
    for (asset, amount) in assets {
        print("\(asset.name) \(asset.type == .crypto ? btcFormatter.string(from: amount as NSNumber)! : fiatFormatter.string(from: amount as NSNumber)!)")
    }
}
