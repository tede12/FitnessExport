import FitnessUI
import Foundation

struct Exercise: Identifiable, Hashable {
    let id: String
    let name: String
    let why: String
    let prescription: [(String, String)]
    let cues: [String]
    let progression: String

    static func == (lhs: Exercise, rhs: Exercise) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum ExerciseLibrary {
    static var all: [Exercise] {
        [
            Exercise(
                id: "pullups", name: AppLanguage.text("Trazioni"),
                why: AppLanguage.text("Forza per schiena e braccia."),
                prescription: [(AppLanguage.text("Prescrizione"), AppLanguage.text("Segui il tuo piano personale"))],
                cues: [AppLanguage.text("Parti senza slancio e mantieni il controllo durante la discesa.")],
                progression: AppLanguage.text("Adatta la progressione con il tuo allenatore.")),
            Exercise(
                id: "pushups", name: AppLanguage.text("Piegamenti"), why: AppLanguage.text("Spinta a corpo libero."),
                prescription: [(AppLanguage.text("Prescrizione"), AppLanguage.text("Segui il tuo piano personale"))],
                cues: [AppLanguage.text("Mantieni il corpo allineato e scegli un rialzo adeguato.")],
                progression: AppLanguage.text("Adatta la progressione con il tuo allenatore.")),
            Exercise(
                id: "pistol", name: AppLanguage.text("Affondo bulgaro"), why: AppLanguage.text("Forza su una gamba."),
                prescription: [(AppLanguage.text("Prescrizione"), AppLanguage.text("Segui il tuo piano personale"))],
                cues: [AppLanguage.text("Usa un appoggio stabile e mantieni il ginocchio in linea con il piede.")],
                progression: AppLanguage.text("Adatta la progressione con il tuo allenatore.")),
            Exercise(
                id: "dips", name: "Dips", why: AppLanguage.text("Spinta alle parallele."),
                prescription: [(AppLanguage.text("Prescrizione"), AppLanguage.text("Segui il tuo piano personale"))],
                cues: [AppLanguage.text("Scendi entro un intervallo di movimento che controlli.")],
                progression: AppLanguage.text("Adatta la progressione con il tuo allenatore.")),
            Exercise(
                id: "bench", name: AppLanguage.text("Panca piana"), why: AppLanguage.text("Spinta con bilanciere."),
                prescription: [(AppLanguage.text("Prescrizione"), AppLanguage.text("Segui il tuo piano personale"))],
                cues: [AppLanguage.text("Usa un carico gestibile e un supporto di sicurezza.")],
                progression: AppLanguage.text("Adatta la progressione con il tuo allenatore.")),
            Exercise(
                id: "core", name: "Plank", why: AppLanguage.text("Stabilità del tronco."),
                prescription: [(AppLanguage.text("Prescrizione"), AppLanguage.text("Segui il tuo piano personale"))],
                cues: [AppLanguage.text("Mantieni il bacino allineato e continua a respirare.")],
                progression: AppLanguage.text("Adatta la progressione con il tuo allenatore.")),
            Exercise(
                id: "long", name: AppLanguage.text("Corsa lunga facile"),
                why: AppLanguage.text("Volume aerobico secondo il piano personale."),
                prescription: [(AppLanguage.text("Prescrizione"), AppLanguage.text("Segui il tuo piano personale"))],
                cues: [AppLanguage.text("Usa le tue zone e una durata adatta alla preparazione.")],
                progression: AppLanguage.text("Adatta la progressione con il tuo allenatore.")),
            Exercise(
                id: "cadence", name: AppLanguage.text("Cadenza"),
                why: AppLanguage.text("Frequenza dei passi durante la corsa."),
                prescription: [(AppLanguage.text("Prescrizione"), AppLanguage.text("Segui il tuo piano personale"))],
                cues: [AppLanguage.text("Osserva la tua cadenza senza imporre un obiettivo universale.")],
                progression: AppLanguage.text("Adatta la progressione con il tuo allenatore.")),
        ]
    }

    static func forSlot(_ slot: String) -> [Exercise] {
        switch slot {
        case "strength":
            return all.filter { ["pullups", "pushups", "pistol", "dips", "bench", "core"].contains($0.id) }
        case "long":
            return all.filter { ["long", "cadence"].contains($0.id) }
        case "easy":
            return all.filter { $0.id == "cadence" }
        default:
            return []
        }
    }
}
