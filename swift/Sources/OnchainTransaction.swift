struct OnchainTransaction {
    struct Vout {
        let sats: Int
        let address: Address
    }

    struct Vin {
        let txid: String
        let voutIndex: Int
        let sats: Int
        let address: Address
    }

    enum TransactionType {
        // couldn't figure this out
        case unknown
        // known address on vout
        case deposit(amount: Int)
        // known address on vin
        case withdrawal(amount: Int)
        // knows addresses everywhere, basically a payment to self
        case consolidation(fee: Int)
    }

    let txid: String
    let time: Int
    let rawTransaction: ElectrumTransaction
    let type: TransactionType
    let totalInSats: Int
    let totalOutSats: Int
    let feeSats: Int
    let vin: [Vin]
    let vout: [Vout]
}