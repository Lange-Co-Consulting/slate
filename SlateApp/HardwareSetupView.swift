import SwiftUI
import SlateUI

/// Shown once, right after onboarding: asks the customer about their Mac
/// (chip / GPU / RAM) so Slate can recommend models that fit. Same visual
/// language as the tutorial popup, and bilingual (inherits the onboarding
/// language choice, still switchable here).
struct HardwareSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    @State private var chip: String = ""
    @State private var gpu: String = ""
    @State private var ram: Int = 0
    @State private var didPrefill = false

    private var lang: UILang { UILang.resolve(model.settings.interfaceLanguage) }

    var body: some View {
        let l = lang
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "memorychip")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 54, height: 54)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quinary))
                VStack(alignment: .leading, spacing: 3) {
                    Text(l("Tell Slate about your Mac", "Erzähl Slate von deinem Mac"))
                        .font(.system(size: 28, weight: .bold))
                    Text(l("This lets Slate recommend models that fit your memory. You can change it anytime in Settings.",
                           "Damit empfiehlt dir Slate Modelle, die in deinen Speicher passen. Du kannst es jederzeit in den Einstellungen ändern."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                languagePicker
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                row(l("Chip", "Chip")) {
                    selectionMenu(chip.isEmpty ? l("Not sure", "Unbekannt") : chip,
                                  options: [(l("Not sure", "Unbekannt"), "")] + HardwareCatalog.chips.map { ($0, $0) },
                                  selection: $chip)
                }
                row(l("GPU", "GPU")) {
                    let values = HardwareCatalog.gpuOptions(for: chip.isEmpty ? nil : chip)
                    selectionMenu(gpu.isEmpty ? l("Not sure", "Unbekannt") : gpu,
                                  options: [(l("Not sure", "Unbekannt"), "")] + values.map { ($0, $0) },
                                  selection: $gpu)
                }
                row(l("Memory (RAM)", "Arbeitsspeicher (RAM)")) {
                    let values = HardwareCatalog.ramOptions(for: chip.isEmpty ? nil : chip)
                    selectionMenu(ram == 0 ? l("Not sure", "Unbekannt") : "\(ram) GB",
                                  options: [(l("Not sure", "Unbekannt"), 0)] + values.map { ("\($0) GB", $0) },
                                  selection: $ram)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous)
                .fill(.quaternary.opacity(0.28)))
            // Changing the chip narrows the GPU/RAM lists - drop selections that
            // no longer exist for the new chip so an impossible combo can't stick.
            .onChange(of: chip) { _, newChip in
                let c = newChip.isEmpty ? nil : newChip
                if !HardwareCatalog.gpuOptions(for: c).contains(gpu) { gpu = "" }
                if !HardwareCatalog.ramOptions(for: c).contains(ram) { ram = 0 }
            }

            if ram > 0 {
                Label(HardwareCatalog.fitHint(ramGB: ram, l), systemImage: "sparkles")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(l("Skip", "Überspringen")) { save() }   // completes without values
                Spacer()
                Button(l("Save", "Speichern")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PaletteProminentButtonStyle())
            }
        }
        .padding(28)
        .frame(width: 560)
        .interactiveDismissDisabled()
        .onAppear(perform: prefill)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ control: () -> Content) -> some View {
        GridRow {
            Text(label).gridColumnAlignment(.trailing).foregroundStyle(.secondary)
            control().frame(width: 190, alignment: .leading)
        }
    }

    private var languagePicker: some View {
        Picker("", selection: Binding(
            get: { lang.rawValue },
            set: { model.settings.interfaceLanguage = $0 })) {
            Text("EN").tag("en")
            Text("DE").tag("de")
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    private func selectionMenu<T: Hashable>(_ value: String, options: [(String, T)],
                                             selection: Binding<T>) -> some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button { selection.wrappedValue = option.1 } label: {
                    if selection.wrappedValue == option.1 {
                        Label(option.0, systemImage: "checkmark")
                    } else {
                        Text(option.0)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(value).foregroundStyle(pickerInk).lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: DS.R.small, style: .continuous).fill(.quinary))
            .contentShape(RoundedRectangle(cornerRadius: DS.R.small, style: .continuous))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
    }

    private var pickerInk: Color { scheme == .dark ? .white : .black }

    /// Pre-fill from prior answers, else from auto-detection.
    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        chip = model.settings.hwChip ?? HardwareCatalog.detectedChip() ?? ""
        gpu = model.settings.hwGPU ?? ""
        let detectedRAM = HardwareCatalog.detectedRAMGB(for: chip.isEmpty ? nil : chip)
        ram = model.settings.hwRAMGB != 0 ? model.settings.hwRAMGB : detectedRAM
    }

    private func save() {
        model.settings.hwChip = chip.isEmpty ? nil : chip
        model.settings.hwGPU = gpu.isEmpty ? nil : gpu
        model.settings.hwRAMGB = ram
        model.settings.hardwareProfileCompleted = true
    }
}
