import FITStudioCore
import SwiftUI

enum SettingsKey {
    static let unitSystem = "unitSystem"
    static let ftp = "ftp"
}

struct SettingsView: View {
    @AppStorage(SettingsKey.unitSystem) private var unitSystem: UnitSystem = .metric
    @AppStorage(SettingsKey.ftp) private var ftp: Double = 250

    var body: some View {
        Form {
            Picker("Units", selection: $unitSystem) {
                ForEach(UnitSystem.allCases, id: \.self) { system in
                    Text(system == .metric ? "Metric (km, km/h, m, °C)" : "Imperial (mi, mph, ft, °F)").tag(system)
                }
            }
            TextField("FTP (W)", value: $ftp, format: .number.precision(.fractionLength(0)))
                .frame(maxWidth: 200)
            Text("Your functional threshold power is used for Intensity Factor and TSS in the summary.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 440)
    }
}
