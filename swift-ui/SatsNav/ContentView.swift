import Charts
import SwiftData
import SwiftUI

struct ToyShape: Identifiable {
    var color: String
    var type: String
    var count: Double
    var id = UUID()
}

var stackedBarData: [ToyShape] = [
    .init(color: "Green", type: "Cube", count: 2),
    .init(color: "Green", type: "Sphere", count: 0),
    .init(color: "Green", type: "Pyramid", count: 1),
    .init(color: "Purple", type: "Cube", count: 1),
    .init(color: "Purple", type: "Sphere", count: 1),
    .init(color: "Purple", type: "Pyramid", count: 1),
    .init(color: "Pink", type: "Cube", count: 1),
    .init(color: "Pink", type: "Sphere", count: 2),
    .init(color: "Pink", type: "Pyramid", count: 0),
    .init(color: "Yellow", type: "Cube", count: 1),
    .init(color: "Yellow", type: "Sphere", count: 1),
    .init(color: "Yellow", type: "Pyramid", count: 2)
]

struct ContentView: View {
    @Binding var balances: [String: Balance]

    @Environment(\.modelContext) private var modelContext
    @Query private var items: [Item]

    var coldStorage: RefsDeque? {
        return balances["❄️"]?[BTC]
    }

    var potfolioTotal: Decimal {
        return balances.values.reduce(0) { $0 + ($1[BTC]?.sum ?? 0) }
    }

    var body: some View {
        NavigationView {
            VStack {
                (Text("BTC ") + Text(potfolioTotal as NSNumber, formatter: btcFormatter)).font(.title)

                Chart {
                    ForEach(stackedBarData) { shape in
                        LineMark(
                            x: .value("Shape Type", shape.type),
                            y: .value("Total Count", shape.count)
                        )
                        .foregroundStyle(by: .value("Shape Color", shape.color))
                    }
                }
                .frame(width: nil, height: 200)
                .padding(.horizontal, 32)

                List {
                    Group {
                        if let refs = coldStorage {
                            ForEach(refs) { ref in
                                VStack(alignment: .leading) {
                                    Text(ref.date, format: Date.FormatStyle(date: .numeric, time: .omitted))
                                    Text("BTC ") + Text(ref.amount as NSNumber, formatter: btcFormatter)
                                        + Text(" (\(ref.refIds.count))")
                                }

//                                Text(verbatim: "\(ref)")
//                                NavigationLink {
//                                    Text("Item at \(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))")
//                                } label: {
//                                    Text(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))
//                                }
                            }
                            // .onDelete(perform: deleteItems)
                        } else {
                            Text("Loading...")
                        }
                    }
                }.toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        EditButton()
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: addItem) {
                            Label("Add Item", systemImage: "plus")
                        }
                    }
                }
            }
            .navigationTitle("Portfolio")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func addItem() {
        withAnimation {
            let newItem = Item(timestamp: Date())
            modelContext.insert(newItem)
        }
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(items[index])
            }
        }
    }
}

#Preview {
    let mockBalances = [String: Balance]()

    return ContentView(balances: .constant(mockBalances))
        .modelContainer(for: Item.self, inMemory: true)
}
