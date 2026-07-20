import Foundation
import RielaNote

@MainActor
public extension RielaNoteLibraryViewModel {
  func setContentMode(_ mode: NoteContentMode) async {
    guard mode == .sourceImage else {
      contentMode = .text
      rememberContentMode(.text)
      return
    }
    guard let sourcePageImageAttachment else {
      contentMode = .text
      rememberContentMode(.text)
      return
    }
    contentMode = .sourceImage
    rememberContentMode(.sourceImage)
    await resolveSourceImageAttachment(sourcePageImageAttachment, generation: selectionGeneration)
  }

  func retrySourceImage() async {
    let attachment = sourcePageImageAttachment ?? selectedResolvedFile.map {
      NoteFileAttachment(noteId: selectedNote?.noteId ?? "", file: $0.file, role: .related, position: 0)
    }
    guard let attachment else {
      return
    }
    removeResolvedFileCacheValue(forKey: attachment.file.fileId)
    removeDecodedSourceImageCacheValue(forKey: attachment.file.fileId)
    if resolvedSourceImage?.file.fileId == attachment.file.fileId {
      resolvedSourceImage = nil
      decodedSourceImage = nil
    }
    contentMode = .sourceImage
    await resolveSourceImageAttachment(attachment, generation: selectionGeneration, useCache: false)
  }

  func zoomInSourceImage() {
    sourceImageZoom = clampedSourceImageZoom(sourceImageZoom + Self.sourceImageZoomStep)
  }

  func zoomOutSourceImage() {
    sourceImageZoom = clampedSourceImageZoom(sourceImageZoom - Self.sourceImageZoomStep)
  }

  func resetSourceImageZoom() {
    sourceImageZoom = 1.0
  }

  func selectFileAttachment(_ attachment: NoteFileAttachment) async {
    if attachment.role == .sourcePageImage || attachment.file.mediaType.hasPrefix("image/") {
      contentMode = .sourceImage
      await resolveSourceImageAttachment(attachment, generation: selectionGeneration)
      return
    }
    let generation = selectionGeneration
    do {
      let resolved = try await resolveFile(attachment.file.fileId)
      guard isCurrentSelection(generation) else {
        return
      }
      selectedResolvedFile = resolved
    } catch {
      guard isCurrentSelection(generation) else {
        return
      }
      state = .failed(rielaNoteLoadFailureMessage(error))
    }
  }
}

@MainActor
extension RielaNoteLibraryViewModel {
  func prepareSelectedNoteFiles(preferredMode: NoteContentMode) async {
    clearResolvedFileSelection()
    let generation = selectionGeneration
    guard selectedDetail != nil else {
      contentMode = .text
      return
    }
    if preferredMode == .sourceImage, let sourcePageImageAttachment {
      contentMode = .sourceImage
      await resolveSourceImageAttachment(sourcePageImageAttachment, generation: generation)
    } else {
      contentMode = .text
    }
    scheduleAdjacentSourceImagePrefetch(generation: generation)
  }

  func clearResolvedFileSelection() {
    resolvedSourceImage = nil
    decodedSourceImage = nil
    selectedResolvedFile = nil
    isSourceImageLoading = false
  }

  private func scheduleAdjacentSourceImagePrefetch(generation: Int) {
    Task { @MainActor [weak self] in
      guard let self, self.isCurrentSelection(generation) else {
        return
      }
      await self.prefetchAdjacentSourceImages()
    }
  }

  private func resolveSourceImageAttachment(
    _ attachment: NoteFileAttachment,
    generation: Int,
    useCache: Bool = true
  ) async {
    isSourceImageLoading = true
    do {
      let resolved = try await resolveFile(attachment.file.fileId, useCache: useCache)
      guard isCurrentSelection(generation) else {
        return
      }
      resolvedSourceImage = resolved
      selectedResolvedFile = resolved
      let decoded = try await decodeSourceImage(resolved, useCache: useCache)
      guard isCurrentSelection(generation) else {
        return
      }
      decodedSourceImage = decoded
      isSourceImageLoading = false
    } catch {
      guard isCurrentSelection(generation) else {
        return
      }
      isSourceImageLoading = false
      state = .failed(rielaNoteLoadFailureMessage(error))
    }
  }

  private func prefetchAdjacentSourceImages() async {
    guard let selectedNoteIndex else {
      return
    }
    let adjacentIndices = [selectedNoteIndex - 1, selectedNoteIndex + 1]
    for index in adjacentIndices where notebookNotes.indices.contains(index) {
      await prefetchSourceImage(noteId: notebookNotes[index].noteId)
    }
  }

  private func prefetchSourceImage(noteId: String) async {
    do {
      let detail = try await client.noteDetail(noteId: noteId)
      guard let attachment = detail.files.first(where: { $0.role == .sourcePageImage }) else {
        return
      }
      _ = try await resolveFile(attachment.file.fileId)
    } catch {
      // Prefetch is best-effort; explicit image selection still surfaces errors.
    }
  }

  private func rememberContentMode(_ mode: NoteContentMode) {
    guard let notebookId = selectedDetail?.note.notebookId ?? selectedNotebookId else {
      return
    }
    notebookContentModes[notebookId] = mode
  }

  private func prefetchFile(_ fileId: String) async {
    do {
      _ = try await resolveFile(fileId)
    } catch {
      // Prefetch is best-effort; explicit file selection still surfaces errors.
    }
  }

  private func resolveFile(_ fileId: String, useCache: Bool = true) async throws -> RielaNoteResolvedFile {
    if useCache, let cached = resolvedFileCache[fileId] {
      touchResolvedFileCacheKey(fileId)
      return cached
    }
    let resolved = try await client.resolveFile(fileId: fileId)
    storeResolvedFileCacheValue(resolved, forKey: fileId)
    return resolved
  }

  private func decodeSourceImage(
    _ resolvedFile: RielaNoteResolvedFile,
    useCache: Bool = true
  ) async throws -> RielaNoteDecodedSourceImage {
    let fileId = resolvedFile.file.fileId
    if useCache, let cached = decodedSourceImageCache[fileId] {
      touchDecodedSourceImageCacheKey(fileId)
      return cached
    }
    let data = resolvedFile.data
    let decoded = try await Task.detached(priority: .userInitiated) {
      try RielaNoteSourceImageDecoder.decode(fileId: fileId, data: data)
    }.value
    storeDecodedSourceImageCacheValue(decoded, forKey: fileId)
    return decoded
  }

  private func storeResolvedFileCacheValue(_ value: RielaNoteResolvedFile, forKey fileId: String) {
    resolvedFileCache[fileId] = value
    touchResolvedFileCacheKey(fileId)
    evictResolvedFileCacheIfNeeded()
  }

  private func touchResolvedFileCacheKey(_ fileId: String) {
    resolvedFileCacheOrder.removeAll { $0 == fileId }
    resolvedFileCacheOrder.append(fileId)
  }

  private func evictResolvedFileCacheIfNeeded() {
    while resolvedFileCacheOrder.count > sourceImageCacheLimit {
      let evicted = resolvedFileCacheOrder.removeFirst()
      resolvedFileCache.removeValue(forKey: evicted)
    }
  }

  private func removeResolvedFileCacheValue(forKey fileId: String) {
    resolvedFileCache.removeValue(forKey: fileId)
    resolvedFileCacheOrder.removeAll { $0 == fileId }
  }

  private func storeDecodedSourceImageCacheValue(_ value: RielaNoteDecodedSourceImage, forKey fileId: String) {
    decodedSourceImageCache[fileId] = value
    touchDecodedSourceImageCacheKey(fileId)
    evictDecodedSourceImageCacheIfNeeded()
  }

  private func touchDecodedSourceImageCacheKey(_ fileId: String) {
    decodedSourceImageCacheOrder.removeAll { $0 == fileId }
    decodedSourceImageCacheOrder.append(fileId)
  }

  private func evictDecodedSourceImageCacheIfNeeded() {
    while decodedSourceImageCacheOrder.count > sourceImageCacheLimit {
      let evicted = decodedSourceImageCacheOrder.removeFirst()
      decodedSourceImageCache.removeValue(forKey: evicted)
    }
  }

  private func removeDecodedSourceImageCacheValue(forKey fileId: String) {
    decodedSourceImageCache.removeValue(forKey: fileId)
    decodedSourceImageCacheOrder.removeAll { $0 == fileId }
  }

  private func clampedSourceImageZoom(_ zoom: Double) -> Double {
    min(max(zoom, Self.sourceImageMinimumZoom), Self.sourceImageMaximumZoom)
  }

  func fileDisplayName(_ file: FileRecord) -> String {
    file.originalFilename ?? file.fileId
  }

  func byteCountText(_ byteSize: Int64) -> String {
    byteSize == 1 ? "1 byte" : "\(byteSize) bytes"
  }
}
