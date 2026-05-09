import Foundation
import SwiftUI

/// ViewModel principal du pipeline de traitement
@MainActor
class PipelineViewModel: ObservableObject {
    @Published var currentStep: PipelineStep = .import_
    @Published var project: Project?
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var progressText: String = ""
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var isPaused = false

    // Éditeur de balises
    @Published var selectedChapterIndex: Int = 0
    @Published var tagColors: [String: Color] = [
        "[whisper]": .purple,
        "[excited]": .orange,
        "[sad]": .blue,
        "[pause]": .gray,
        "[angry]": .red,
        "[laughing]": .yellow,
        "[chuckle]": .yellow,
        "[emphasis]": .green,
        "[clearing throat]": .brown,
        "[inhale]": .cyan,
        "[professional broadcast tone]": .indigo,
        "[warm]": .pink,
        "[tense]": .red,
        "[mysterious]": .purple
    ]

    private let textExtractor = TextExtractorService.shared
    private let ollamaService = OllamaService.shared
    private let audioService = AudioGenerationService.shared
    private let exportService = ExportService.shared
    private let projectManager = ProjectManager.shared

    enum PipelineStep: Int, CaseIterable {
        case import_ = 0
        case tags = 1
        case voice = 2
        case generation = 3
        case export = 4

        var title: String {
            switch self {
            case .import_: "Import"
            case .tags: "Balises"
            case .voice: "Voix"
            case .generation: "Génération"
            case .export: "Export"
            }
        }

        var icon: String {
            switch self {
            case .import_: "doc.badge.plus"
            case .tags: "tag"
            case .voice: "waveform"
            case .generation: "gearshape.2"
            case .export: "square.and.arrow.up"
            }
        }
    }

    func loadProject(_ project: Project) {
        self.project = project
        updateCurrentStep()
    }

    private func updateCurrentStep() {
        guard let project = project else { return }

        switch project.status {
        case .imported:
            currentStep = .import_
        case .textExtracted:
            currentStep = .tags
        case .tagsInjected:
            currentStep = .voice
        case .audioGenerated:
            currentStep = .export
        case .exported:
            currentStep = .export
        case .error:
            break
        }
    }

    // MARK: - Étape 1: Import + Extraction

    func extractText() async {
        guard let project = project else { return }
        isProcessing = true
        progressText = "Extraction du texte..."
        errorMessage = nil

        do {
            let (chapters, metadata, coverPath) = try await textExtractor.extractText(
                from: project.sourceFilePath,
                type: project.sourceFileType
            )

            var updatedProject = project
            updatedProject.metadata.title = metadata.title
            updatedProject.metadata.author = metadata.author
            updatedProject.coverImagePath = coverPath

            // Nettoyer le texte
            var cleanedChapters: [Chapter] = []
            for (index, chapter) in chapters.enumerated() {
                var cleaned = textExtractor.cleanText(chapter.text)
                cleaned = textExtractor.removeRepeatedHeadersFooters(from: cleaned)
                cleaned = textExtractor.removeFootnotes(from: cleaned)

                let chapterObj = Chapter(
                    index: index + 1,
                    title: chapter.title.isEmpty ? "Chapitre \(index + 1)" : chapter.title,
                    rawText: cleaned,
                    status: .textReady
                )
                cleanedChapters.append(chapterObj)

                // Sauvegarder le texte
                try? projectManager.saveChapterText(project: updatedProject, chapter: chapterObj)
            }

            updatedProject.chapters = cleanedChapters
            updatedProject.status = .textExtracted

            projectManager.updateProject(updatedProject)
            self.project = updatedProject
            currentStep = .tags

        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }

        isProcessing = false
    }

    // MARK: - Étape 2: Injection de balises

    func injectTags() async {
        guard let project = project, !project.chapters.isEmpty else { return }
        isProcessing = true
        isPaused = false
        errorMessage = nil

        do {
            let updatedChapters = try await ollamaService.processAllChapters(
                chapters: project.chapters,
                progressHandler: { [weak self] current, total in
                    self?.progress = Double(current) / Double(total)
                    self?.progressText = "Chapitre \(current)/\(total) enrichi..."
                }
            )

            var updatedProject = project
            updatedProject.chapters = updatedChapters
            updatedProject.status = .tagsInjected

            // Sauvegarder les textes enrichis
            for chapter in updatedChapters {
                try? projectManager.saveChapterText(project: updatedProject, chapter: chapter)
            }

            projectManager.updateProject(updatedProject)
            self.project = updatedProject
            currentStep = .voice

        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }

        isProcessing = false
    }

    func regenerateChapter(at index: Int) async {
        guard var project = project,
              index < project.chapters.count else { return }

        isProcessing = true
        errorMessage = nil

        do {
            let taggedText = try await ollamaService.injectTags(
                chapterText: project.chapters[index].rawText
            )

            project.chapters[index].taggedText = taggedText
            project.chapters[index].status = .tagged

            try? projectManager.saveChapterText(project: project, chapter: project.chapters[index])
            projectManager.updateProject(project)
            self.project = project

        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }

        isProcessing = false
    }

    func removeAllTags(from chapterIndex: Int) {
        guard var project = project,
              chapterIndex < project.chapters.count else { return }

        project.chapters[chapterIndex].taggedText = nil
        project.chapters[chapterIndex].status = .textReady
        projectManager.updateProject(project)
        self.project = project
    }

    // MARK: - Étape 3: Configuration voix

    func setVoiceReference(audioPath: String, transcription: String) {
        guard var project = project else { return }

        project.voiceConfig.referenceAudioPath = audioPath
        project.voiceConfig.referenceTranscription = transcription
        projectManager.updateProject(project)
        self.project = project
    }

    func updateVoiceSpeed(_ speed: Double) {
        guard var project = project else { return }
        project.voiceConfig.speedScale = speed
        projectManager.updateProject(project)
        self.project = project
    }

    func updateVoiceTemperature(_ temperature: Double) {
        guard var project = project else { return }
        project.voiceConfig.temperature = temperature
        projectManager.updateProject(project)
        self.project = project
    }

    func generateVoicePreview() async {
        guard let project = project,
              project.voiceConfig.hasValidReference,
              let firstChapter = project.chapters.first else { return }

        isProcessing = true
        progressText = "Génération du preview vocal..."
        errorMessage = nil

        let previewPath = "\(project.projectDirectory)/voice_preview.wav"

        do {
            try await audioService.generatePreview(
                text: String(firstChapter.rawText.prefix(500)),
                voiceConfig: project.voiceConfig,
                outputPath: previewPath
            )
            progressText = "Preview prêt !"
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }

        isProcessing = false
    }

    // MARK: - Étape 4: Génération audio

    func generateAudio() async {
        guard let project = project,
              project.voiceConfig.hasValidReference else { return }

        isProcessing = true
        isPaused = false
        errorMessage = nil

        var updatedProject = project

        for (chapterIndex, chapter) in updatedProject.chapters.enumerated() {
            guard !isPaused else { break }

            progressText = "Génération du chapitre \(chapterIndex + 1)/\(updatedProject.chapters.count)..."
            progress = Double(chapterIndex) / Double(updatedProject.chapters.count)

            do {
                let (chunks, chapterAudioPath) = try await audioService.generateChapterAudio(
                    chapter: chapter,
                    projectDir: updatedProject.projectDirectory,
                    voiceConfig: updatedProject.voiceConfig,
                    progressHandler: { [weak self] current, total in
                        self?.progressText = "Chunk \(current)/\(total) du chapitre \(chapterIndex + 1)"
                    }
                )

                // Normaliser
                try await audioService.normalizeAudio(filePath: chapterAudioPath)

                updatedProject.chapters[chapterIndex].audioFilePath = chapterAudioPath
                updatedProject.chapters[chapterIndex].status = .audioReady

                // Sauvegarder la progression
                projectManager.updateProject(updatedProject)

            } catch {
                updatedProject.chapters[chapterIndex].status = .error
                errorMessage = "Erreur chapitre \(chapterIndex + 1): \(error.localizedDescription)"
                showError = true
            }
        }

        if !isPaused {
            updatedProject.status = .audioGenerated
            progress = 1.0
            progressText = "Génération terminée !"
        }

        projectManager.updateProject(updatedProject)
        self.project = updatedProject

        if updatedProject.status == .audioGenerated {
            currentStep = .export
        }

        isProcessing = false
    }

    func togglePause() {
        isPaused.toggle()
    }

    // MARK: - Étape 5: Export

    func exportAudio(format: ExportFormat, structure: ExportStructure) async {
        guard let project = project else { return }

        isProcessing = true
        errorMessage = nil

        do {
            let exportedFiles = try await exportService.exportProject(
                project: project,
                format: format,
                structure: structure,
                progressHandler: { [weak self] progress in
                    self?.progress = progress
                    self?.progressText = "Export : \(Int(progress * 100))%"
                }
            )

            var updatedProject = project
            updatedProject.status = .exported
            updatedProject.exportConfig.format = format
            updatedProject.exportConfig.structure = structure
            projectManager.updateProject(updatedProject)
            self.project = updatedProject

            progressText = "Export terminé ! \(exportedFiles.count) fichier(s) créé(s)"

            // Notification macOS
            let notification = NSUserNotification()
            notification.title = "AudiobookForge"
            notification.informativeText = "Export terminé : \(exportedFiles.count) fichier(s)"
            NSUserNotificationCenter.default.deliver(notification)

        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }

        isProcessing = false
    }
}
