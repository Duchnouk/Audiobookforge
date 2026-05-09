import Foundation

/// Service d'extraction et de nettoyage de texte depuis EPUB, PDF, DOCX
/// Délègue le travail aux scripts Python backend
class TextExtractorService {
    static let shared = TextExtractorService()

    /// Chemin absolu vers le dossier backend/scripts
    private let backendScriptsPath: String

    private init() {
        // On remonte depuis le bundle jusqu'à trouver le dossier backend
        let bundlePath = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        backendScriptsPath = "\(bundlePath)/backend/scripts"
    }

    /// Extrait le texte d'un fichier source
    func extractText(from filePath: String, type: FileType) async throws -> (
        chapters: [(title: String, text: String)],
        metadata: (title: String, author: String),
        coverPath: String?
    ) {
        let scriptPath: String

        switch type {
        case .epub:
            scriptPath = "\(backendScriptsPath)/extract_epub.py"
        case .pdf:
            scriptPath = "\(backendScriptsPath)/extract_pdf.py"
        case .docx:
            scriptPath = "\(backendScriptsPath)/extract_docx.py"
        }

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiobookforge_extract_\(UUID().uuidString)")
            .path

        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.arguments = [
                        scriptPath,
                        "--input", filePath,
                        "--output", outputDir
                    ]

                    let outputPipe = Pipe()
                    let errorPipe = Pipe()
                    process.standardOutput = outputPipe
                    process.standardError = errorPipe

                    try process.run()
                    process.waitUntilExit()

                    if process.terminationStatus != 0 {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorMessage = String(data: errorData, encoding: .utf8) ?? "Erreur inconnue"
                        throw TextExtractorError.extractionFailed(errorMessage)
                    }

                    // Lire les fichiers générés par le script Python
                    let chaptersFile = "\(outputDir)/chapters.json"
                    let metadataFile = "\(outputDir)/metadata.json"
                    let coverFile = "\(outputDir)/cover.jpg"

                    let chaptersData = try Data(contentsOf: URL(fileURLWithPath: chaptersFile))
                    let metadataData = try Data(contentsOf: URL(fileURLWithPath: metadataFile))

                    let chapters = try JSONDecoder().decode([ChapterData].self, from: chaptersData)
                    let metadata = try JSONDecoder().decode(MetadataData.self, from: metadataData)

                    let coverPath = FileManager.default.fileExists(atPath: coverFile) ? coverFile : nil
                    let resultChapters = chapters.map { (title: $0.title, text: $0.text) }

                    // Nettoyer le dossier temporaire
                    try? FileManager.default.removeItem(atPath: outputDir)

                    continuation.resume(returning: (resultChapters, (metadata.title, metadata.author), coverPath))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Nettoie le texte brut selon les règles définies
    func cleanText(_ text: String) -> String {
        var cleaned = text

        cleaned = cleaned.replacingOccurrences(
            of: "(?m)^\\s*\\d+\\s*$",
            with: "",
            options: .regularExpression
        )

        cleaned = cleaned.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )

        cleaned = cleaned.replacingOccurrences(
            of: "(\\w)-\\n(\\w)",
            with: "$1$2",
            options: .regularExpression
        )

        cleaned = cleaned.replacingOccurrences(of: "\u{00AB}", with: "\"")
        cleaned = cleaned.replacingOccurrences(of: "\u{00BB}", with: "\"")
        cleaned = cleaned.replacingOccurrences(of: "\u{201C}", with: "\"")
        cleaned = cleaned.replacingOccurrences(of: "\u{201D}", with: "\"")
        cleaned = cleaned.replacingOccurrences(of: "\u{201E}", with: "\"")

        cleaned = cleaned.replacingOccurrences(of: "\u{2019}", with: "'")
        cleaned = cleaned.replacingOccurrences(of: "\u{2018}", with: "'")

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func removeRepeatedHeadersFooters(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var lineCounts: [String: Int] = [:]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                lineCounts[trimmed, default: 0] += 1
            }
        }

        let repeatedLines = Set(lineCounts.filter { $0.value > 3 }.keys)
        let filteredLines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !repeatedLines.contains(trimmed)
        }

        return filteredLines.joined(separator: "\n")
    }

    func removeFootnotes(from text: String) -> String {
        var cleaned = text

        cleaned = cleaned.replacingOccurrences(
            of: "\\[\\d+\\]",
            with: "",
            options: .regularExpression
        )

        cleaned = cleaned.replacingOccurrences(
            of: "[\\u{00B9}\\u{00B2}\\u{00B3}\\u{2070}-\\u{209F}]",
            with: "",
            options: .regularExpression
        )

        cleaned = cleaned.replacingOccurrences(
            of: "(?i)\\b(?:op\\.\\s*cit\\.|ibid\\.|loc\\.\\s*cit\\.|cf\\.|voir\\s+note\\s+\\d+)\\b",
            with: "",
            options: .regularExpression
        )

        return cleaned
    }
}

// MARK: - Supporting Types

struct ChapterData: Codable {
    let title: String
    let text: String
}

struct MetadataData: Codable {
    let title: String
    let author: String
}

enum TextExtractorError: Error, LocalizedError {
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .extractionFailed(let message):
            return "Échec de l'extraction du texte : \(message)"
        }
    }
}
