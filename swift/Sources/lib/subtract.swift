import Foundation

/**
 Removes refs from asset balance using FIFO strategy
 */
func subtract(refs: inout RefsDeque, amount: Decimal) -> RefsArray {
    guard amount >= 0 else {
        fatalError("amount must be positive")
    }
    let balanceBefore = refs.sum

    // Remove refs from asset balance using FIFO strategy
    var subtractedRefs = RefsArray()
    var totalRemoved: Decimal = 0
    while !refs.isEmpty && totalRemoved < amount {
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
        refs.insert(last.withAmount(leftOnBalance), at: 0)
        // Add rest to removed refs
        subtractedRefs.append(last.withAmount(last.amount - leftOnBalance))
    }

    assert(refs.sum + subtractedRefs.sum == balanceBefore,
           "Balance subtract error, should be \(balanceBefore), it's \(refs.sum + subtractedRefs.sum)")

    return subtractedRefs
}
