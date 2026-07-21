import SwiftUI
import SlateUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var showingTour = false

    /// Resolved from the persisted setting; the segmented control writes it back
    /// so the following hardware popup inherits the same language.
    private var lang: UILang { UILang.resolve(model.settings.interfaceLanguage) }

    private func examples(_ l: UILang) -> [(String, String)] {
        [
            (l("Code", "Code"),
             l("Open a project and ask Slate to explain its architecture.",
               "Öffne ein Projekt und lass Slate die Architektur erklären.")),
            (l("Build", "Bauen"),
             l("Create a small feature, show the plan, then run the tests.",
               "Baue ein kleines Feature, zeig den Plan, dann lauf die Tests.")),
            (l("Review", "Review"),
             l("Review the current changes for correctness and security.",
               "Prüfe die aktuellen Änderungen auf Korrektheit und Sicherheit.")),
            (l("Image", "Bild"),
             l("Generate a local product illustration with a transparent background.",
               "Erzeuge lokal eine Produkt-Illustration mit transparentem Hintergrund.")),
            (l("Voice", "Sprache"),
             l("Press ⌘⇧V to have a hands-free conversation with a local model.",
               "Drück ⌘⇧V für ein freihändiges Gespräch mit einem lokalen Modell.")),
            (l("Flow", "Flow"),
             l("Hold Fn to dictate into the app that currently has keyboard focus.",
               "Halte Fn, um in die App zu diktieren, die gerade den Fokus hat.")),
        ]
    }

    var body: some View {
        let l = lang
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                SlateMark(width: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text(l("Welcome to Slate", "Willkommen bei Slate")).font(.largeTitle.bold())
                    Text(l("Local-first chat, coding, images and dictation on your Mac.",
                           "Lokale Chats, Coding, Bilder und Diktat auf deinem Mac."))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                languagePicker
            }

            if showingTour {
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
                    ForEach(Array(examples(l).enumerated()), id: \.offset) { _, example in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(example.0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(example.1).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quinary))
                    }
                }
                Text(l("Permissions are requested only when a feature needs them. Cloud mode stays off until you explicitly enable it in Settings.",
                       "Berechtigungen werden nur abgefragt, wenn eine Funktion sie braucht. Der Cloud-Modus bleibt aus, bis du ihn ausdrücklich in den Einstellungen aktivierst."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label(l("Your conversations and local inference stay on this Mac.",
                            "Deine Unterhaltungen und lokale Inferenz bleiben auf diesem Mac."),
                          systemImage: "lock.shield")
                    Label(l("New coding sessions ask before edits or commands.",
                            "Neue Coding-Sitzungen fragen vor Änderungen oder Befehlen."),
                          systemImage: "checkmark.shield")
                    Label(l("Models show their size before download and continue in the background.",
                            "Modelle zeigen ihre Größe vor dem Download und laden im Hintergrund weiter."),
                          systemImage: "arrow.down.circle")
                }
                .font(.callout)
            }

            HStack {
                Button(showingTour ? l("Back", "Zurück") : l("Quick tour", "Kurztour")) {
                    showingTour.toggle()
                }
                Spacer()
                Button(l("Choose a model…", "Modell auswählen…")) {
                    model.settings.onboardingCompleted = true
                    model.showModelManager = true
                }
                Button(l("Get started", "Loslegen")) { model.settings.onboardingCompleted = true }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PaletteProminentButtonStyle())
            }
        }
        .padding(28)
        .frame(width: 650)
        .interactiveDismissDisabled()
    }

    /// EN / DE segmented toggle - persists the choice so the hardware popup and
    /// the rest of onboarding follow the same language.
    private var languagePicker: some View {
        Picker("", selection: Binding(
            get: { lang.rawValue },
            set: { model.settings.interfaceLanguage = $0 })) {
            Text("EN").tag("en")
            Text("DE").tag("de")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(lang("Language of this guide", "Sprache dieser Anleitung"))
    }
}
