import Charts
import RealmSwift
import SwiftData
import SwiftUI

struct ChartDataItem: Identifiable {
    let source: String
    let date: Date
    let amount: Decimal

    var id: String {
        return "\(source)-\(date)"
    }
}

struct ContentView: View {
    var credentials: Credentials
    @StateObject private var balances: BalancesManager
    @StateObject private var btc = HistoricPriceProvider()
    @StateObject private var webSocketManager = WebSocketManager()
    @State var coldStorage: RefsArray = []
    @State private var csvImportWizardPresented = false
    @State private var addOnchainWalletWizardPresented = false
    @State private var addServiceAccountWizardPresented = false

    init(credentials: Credentials) {
        self.credentials = credentials
        _balances = StateObject(wrappedValue: BalancesManager(credentials: credentials))
    }

    var header: some View {
        VStack {
            (Text("BTC ") + Text(balances.current.total as NSNumber, formatter: btcFormatter)).font(.title)
            (Text("€ ") + Text((balances.current.total * webSocketManager.btcPrice) as NSNumber, formatter: fiatFormatter)).font(.title3).foregroundStyle(.secondary)
            (Text("BTC 1 = € ") + Text(webSocketManager.btcPrice as NSNumber, formatter: fiatFormatter)).font(.subheadline).foregroundStyle(.secondary)
            (Text("cost basis € ") + Text((balances.current.spent / balances.current.total) as NSNumber, formatter: fiatFormatter)).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    var chartData: [ChartDataItem] {
        balances.history.flatMap {
            let price = btc.prices[$0.date] ?? webSocketManager.btcPrice
            return [
                ChartDataItem(source: "capital", date: $0.date, amount: $0.spent),
                ChartDataItem(source: "bonuses", date: $0.date, amount: $0.bonus * price),
                ChartDataItem(source: "value", date: $0.date, amount: ($0.total - $0.bonus) * price),
            ]
        }
    }

    var chart: some View {
        Chart {
            ForEach(chartData) { item in
                AreaMark(
                    x: .value("Date", item.date),
                    // Using this trick with capital so that it is present in the legend.
                    y: .value("Amount", item.source == "capital" ? 0 : item.amount)
                )
                .foregroundStyle(by: .value("Source", item.source))
            }

            ForEach(chartData.filter { $0.source == "capital" }) { item in
                LineMark(
                    x: .value("Date", item.date),
                    y: .value("Amount", item.amount)
                )
            }
        }
        // .frame(width: nil, height: 200)
        .padding()
    }

    var body: some View {
        NavigationView {
            VStack {
                self.header
                self.chart

                List {
                    Group {
                        if balances.recap.count > 0 {
                            ForEach(balances.recap) { item in
                                HStack {
                                    Text(item.wallet)
                                    Spacer()
                                    Text("\(item.count)")
                                }
                            }

//                            ForEach(coldStorage) { ref in
//                                VStack(alignment: .leading) {
//                                    Text(ref.date, format: Date.FormatStyle(date: .numeric, time: .standard))
//                                    Text("BTC ") + Text(ref.amount as NSNumber, formatter: btcFormatter)
//                                        + Text(" (\(ref.refIds.count))")
//                                    Text(ref.refId)
//                                    if let rate = ref.rate {
//                                        Text("€ ") + Text(rate as NSNumber, formatter: fiatFormatter)
//                                    } else {
//                                        Text("€ -")
//                                    }
//                                }

//                                Text(verbatim: "\(ref)")
//                                NavigationLink {
//                                    Text("Item at \(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))")
//                                } label: {
//                                    Text(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))
//                                }
//                            }
                            // .onDelete(perform: deleteItems)
                        } else {
                            HStack {
                                Spacer()
                                Text("Loading...")
                                Spacer()
                            }.listRowSeparator(.hidden)
                        }
                    }
                }
                .listStyle(.plain)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // FIXME: the menu closes on data update from websockets.
                    Menu {
                        Button("Import from CSV") {
                            csvImportWizardPresented.toggle()
                        }
                        Button("Onchain wallet") {
                            addOnchainWalletWizardPresented.toggle()
                        }
                        Button("Exchange account") {
                            addServiceAccountWizardPresented.toggle()
                        }
                    }
                    label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .navigationBarTitle("Portfolio", displayMode: .inline)
        }
        .fullScreenCover(isPresented: $csvImportWizardPresented) {
            CSVImportView(onDone: { newEntries in
                csvImportWizardPresented.toggle()

                guard let entries = newEntries else {
                    return
                }

                // TODO: communicate progress while this is ongoing...
                Task {
                    await balances.merge(entries)
                }
            })
        }
        .fullScreenCover(isPresented: $addOnchainWalletWizardPresented) {
            AddOnchainWalletView(onDone: { newWallet in
                addOnchainWalletWizardPresented.toggle()

                guard let wallet = newWallet else {
                    return
                }

                // TODO: communicate progress while this is ongoing...
                Task {
                    await balances.addOnchainWallet(wallet)
                }
            })
        }
        .fullScreenCover(isPresented: $addServiceAccountWizardPresented) {
            AddServiceAccountView(onDone: { newAccount in
                addServiceAccountWizardPresented.toggle()

                guard let account = newAccount else {
                    return
                }

                // TODO: communicate progress while this is ongoing...
                print(account)
                fatalError("Not implemented")
            })
        }
        .task {
            await balances.update()
        }
        .onAppear {
            webSocketManager.connect()
            btc.load()
        }
    }
}

#Preview {
    ContentView(credentials: try! Credentials())
}
