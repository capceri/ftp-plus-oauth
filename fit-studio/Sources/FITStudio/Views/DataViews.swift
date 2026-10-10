import FITStudioCore
import SwiftUI

/// Every record as a table (with adjustments applied).
struct DataView: View {
    @EnvironmentObject private var store: FileStore
    @ObservedObject var file: LoadedFile
    @AppStorage(SettingsKey.unitSystem) private var system: UnitSystem = .metric

    private let timeWidth: CGFloat = 90
    private let columnWidth: CGFloat = 112

    var body: some View {
        let activity = file.displayActivity
        let channels = activity.channels
        let units = channels.map { $0.displayUnit(system) }
        let decimals = channels.map(tableDecimals)
        VStack(spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(activity.times.indices, id: \.self) { row in
                            HStack(spacing: 0) {
                                Text(Format.duration(activity.times[row]))
                                    .frame(width: timeWidth, alignment: .trailing)
                                    .foregroundStyle(.secondary)
                                ForEach(channels.indices, id: \.self) { column in
                                    let channel = channels[column]
                                    Text(channel.values[row].map { Format.number(units[column].convert($0), decimals: decimals[column]) } ?? "–")
                                    .frame(width: columnWidth, alignment: .trailing)
                                }
                            }
                            .font(.callout.monospacedDigit())
                            .padding(.vertical, 2)
                            .background(row % 2 == 0 ? Color.clear : Color.primary.opacity(0.035))
                        }
                    } header: {
                        HStack(spacing: 0) {
                            Text("Time").frame(width: timeWidth, alignment: .trailing)
                            ForEach(channels.indices, id: \.self) { column in
                                VStack(alignment: .trailing, spacing: 0) {
                                    Text(channels[column].name).lineLimit(1)
                                    Text(units[column].symbol.isEmpty ? " " : units[column].symbol)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: columnWidth, alignment: .trailing)
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.vertical, 6)
                        .background(.bar)
                    }
                }
                .padding(.horizontal, 12)
            }
            Divider()
            HStack {
                Text("\(activity.times.count.formatted()) records\(file.hasAdjustments ? " · values include your adjustments" : "")")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Export CSV…") { store.exportCSV(of: file) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

extension DataView {
    /// A little more precision than elsewhere, since this is the raw data.
    private func tableDecimals(_ channel: Channel) -> Int {
        switch channel.quantity {
        case .distance: return 3
        case .speed, .altitude, .temperature: return 1
        case .other: return ["W", "bpm", "rpm", "kcal", ""].contains(channel.units) ? 0 : 2
        }
    }
}

/// Raw view of every message in the file, with field names, values, units and stored values.
struct MessagesView: View {
    @ObservedObject var file: LoadedFile
    @State private var selectedType: UInt16? = FITMessageNumber.session
    @State private var index = 0

    var body: some View {
        HSplitView {
            List(selection: $selectedType) {
                ForEach(file.activity.info.messageCounts) { count in
                    HStack {
                        Text(count.name).lineLimit(1)
                        Spacer()
                        Text(count.count.formatted())
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .tag(count.globalNumber)
                }
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)

            detail
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if let selectedType, !file.activity.info.messageCounts.contains(where: { $0.globalNumber == selectedType }) {
                self.selectedType = file.activity.info.messageCounts.first?.globalNumber
            }
        }
        .onChange(of: selectedType) { index = 0 }
    }

    @ViewBuilder
    private var detail: some View {
        if let type = selectedType {
            let messages = file.file.messages(type)
            if messages.isEmpty {
                EmptyState(title: "No messages", message: "Choose a message type on the left.", symbol: "doc.text.magnifyingglass")
            } else {
                let current = min(index, messages.count - 1)
                let message = messages[current]
                let definition = file.file.definition(of: message)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(FITProfile.messageName(type).map { FITNames.humanize($0) } ?? "Message \(type)") \(current + 1) of \(messages.count.formatted())")
                                .font(.headline)
                            Text("\(FITInspector.label(of: message, in: file.file)) · message \(type) · \(definition.fields.count + definition.developerFields.count) fields, \(definition.dataSize) bytes\(definition.isBigEndian ? ", big-endian" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if messages.count > 1 {
                            Button {
                                index = max(0, current - 1)
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                            .disabled(current == 0)
                            Button {
                                index = min(messages.count - 1, current + 1)
                            } label: {
                                Image(systemName: "chevron.right")
                            }
                            .disabled(current == messages.count - 1)
                        }
                    }
                    if messages.count > 2 {
                        Slider(value: Binding(get: { Double(current) }, set: { index = Int($0.rounded()) }),
                               in: 0...Double(messages.count - 1))
                    }
                    Table(FITInspector.fields(of: message, in: file.file)) {
                        TableColumn("Field") { field in
                            Text(field.name + (field.isDeveloper ? " (developer)" : ""))
                        }
                        .width(min: 140, ideal: 200)
                        TableColumn("Value") { field in
                            Text(field.value).textSelection(.enabled)
                        }
                        .width(min: 120, ideal: 220)
                        TableColumn("Units") { field in
                            Text(field.units).foregroundStyle(.secondary)
                        }
                        .width(min: 40, ideal: 60)
                        TableColumn("Stored") { field in
                            Text(field.raw).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .width(min: 60, ideal: 110)
                        TableColumn("#") { field in
                            Text("\(field.number)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .width(min: 30, ideal: 40)
                        TableColumn("Type") { field in
                            Text(field.baseType).foregroundStyle(.secondary)
                        }
                        .width(min: 50, ideal: 70)
                    }
                }
                .padding(16)
            }
        } else {
            EmptyState(title: "Choose a message type", message: "Every message in the file is listed on the left.", symbol: "doc.text.magnifyingglass")
        }
    }
}
