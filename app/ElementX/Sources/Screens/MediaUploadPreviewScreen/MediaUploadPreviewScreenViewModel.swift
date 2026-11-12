//
// Copyright 2025 Element Creations Ltd.
// Copyright 2022-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import MatrixRustSDK
import SwiftUI

typealias MediaUploadPreviewScreenViewModelType = StateStoreViewModelV2<MediaUploadPreviewScreenViewState, MediaUploadPreviewScreenViewAction>

class MediaUploadPreviewScreenViewModel: MediaUploadPreviewScreenViewModelType, MediaUploadPreviewScreenViewModelProtocol {
    private let timelineController: TimelineControllerProtocol
    private let userIndicatorController: UserIndicatorControllerProtocol
    
    private let mediaUploadingPreprocessor: MediaUploadingPreprocessor
    private var mediaURLs: [URL]
    
    private var processingTask: Task<Result<[MediaInfo], MediaUploadingPreprocessorError>, Never>
    private var requestHandle: SendAttachmentJoinHandleProtocol?
    private let clientProxy: ClientProxyProtocol
    private let galleryEnabled: Bool
    /// Completing the camera/library/document picker is already the user's send action.
    /// Paste, drag and Share Extension still use the ordinary preview and explicit Send.
    private let confirmedPicker: Bool
    private var hasSubmittedPickerSelection = false
    
    private var actionsSubject: PassthroughSubject<MediaUploadPreviewScreenViewModelAction, Never> = .init()
    
    var actions: AnyPublisher<MediaUploadPreviewScreenViewModelAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    init(mediaURLs: [URL],
         caption: NSAttributedString?,
         title: String?,
         shouldShowCaptionWarning: Bool,
         galleryEnabled: Bool,
         mediaUploadingPreprocessor: MediaUploadingPreprocessor,
         timelineController: TimelineControllerProtocol,
         clientProxy: ClientProxyProtocol,
         userIndicatorController: UserIndicatorControllerProtocol,
         confirmedPicker: Bool = false) {
        self.mediaURLs = mediaURLs
        self.mediaUploadingPreprocessor = mediaUploadingPreprocessor
        self.timelineController = timelineController
        self.clientProxy = clientProxy
        self.userIndicatorController = userIndicatorController
        self.galleryEnabled = galleryEnabled
        self.confirmedPicker = confirmedPicker
        
        // Start processing the media whilst the user is reviewing it/adding a caption.
        processingTask = Self.processMedia(at: mediaURLs, preprocessor: mediaUploadingPreprocessor, clientProxy: clientProxy)
        
        super.init(initialViewState: MediaUploadPreviewScreenViewState(mediaURLs: mediaURLs,
                                                                       title: title,
                                                                       shouldShowCaptionWarning: shouldShowCaptionWarning,
                                                                       bindings: .init(caption: caption ?? NSAttributedString())))
    }
    
    override func process(viewAction: MediaUploadPreviewScreenViewAction) {
        // Get the current caption before all the processing starts.
        let caption = state.bindings.caption.nonBlankString
        
        switch viewAction {
        case .send:
            guard !state.shouldDisableInteraction, !hasSubmittedPickerSelection else { return }
            if confirmedPicker {
                hasSubmittedPickerSelection = true
                // Clear only the draft consumed by this confirmed selection.
                // Upload completion must never erase a newer message being typed.
                timelineController.callbacks.send(.messageSentOrEdited)
            }
            startLoading()
            
            Task { [processingTask] in
                defer {
                    stopLoading()
                    if confirmedPicker { actionsSubject.send(.dismiss) }
                }
                
                let result = await processingTask.value
                guard !processingTask.isCancelled else { return }
                switch result {
                case .success(let mediaInfos):
                    if confirmedPicker {
                        // The native timeline now owns upload progress/cancel/retry.
                        userIndicatorController.retractIndicatorWithId(loadingIndicatorIdentifier)
                    }
                    if galleryEnabled, mediaInfos.count > 1 {
                        switch await sendGallery(mediaInfos: mediaInfos, caption: caption) {
                        case .success:
                            break
                        case .failure(let error):
                            if case .timelineProxyError(.attachmentEnqueueFailed) = error {
                                restoreCaptionAfterPreparationFailure(caption)
                            }
                            MXLog.error("Failed sending gallery with error: \(error)")
                            showError(label: L10n.screenMediaUploadPreviewErrorFailedSending)
                        }
                    } else {
                        var perItemCaption = caption
                        for mediaInfo in mediaInfos {
                            switch await sendAttachment(mediaInfo: mediaInfo, caption: perItemCaption) {
                            case .success:
                                perItemCaption = nil // Set the caption only on the first uploaded file.
                            case .failure(let error):
                                // Once the SDK returns a handle, its local echo/retry
                                // owns this caption even if uploading later fails.
                                if requestHandle != nil { perItemCaption = nil }
                                MXLog.error("Failed sending media with error: \(error)")
                                showError(label: L10n.screenMediaUploadPreviewErrorFailedSending)
                            }
                        }
                        restoreCaptionAfterPreparationFailure(perItemCaption)
                    }
                    
                    if !confirmedPicker { actionsSubject.send(.dismiss) }
                case .failure(.maxUploadSizeUnknown):
                    restoreCaptionAfterPreparationFailure(caption)
                    showAlert(.maxUploadSizeUnknown)
                case .failure(.maxUploadSizeExceeded(let limit)):
                    restoreCaptionAfterPreparationFailure(caption)
                    showAlert(.maxUploadSizeExceeded(limit: limit))
                case .failure(let error):
                    restoreCaptionAfterPreparationFailure(caption)
                    MXLog.error("Failed processing media to upload with error: \(error)")
                    showError(label: L10n.screenMediaUploadPreviewErrorFailedProcessing)
                }
            }
        case .cancel:
            requestHandle?.cancel()
            actionsSubject.send(.dismiss)
        case .editedMedia(let image, let index):
            guard mediaURLs.indices.contains(index),
                  let data = image.jpegData(compressionQuality: 1.0) else {
                return
            }
            
            do {
                try data.write(to: mediaURLs[index], options: .atomic)
                
                state.mediaEditVersion += 1
                
                processingTask.cancel()
                processingTask = Self.processMedia(at: mediaURLs, preprocessor: mediaUploadingPreprocessor, clientProxy: clientProxy)
            } catch {
                MXLog.error("Failed writing cropped image with error: \(error)")
            }
        }
    }
    
    private func sendGallery(mediaInfos: [MediaInfo], caption: String?) async -> Result<Void, TimelineControllerError> {
        let itemInfos: [GalleryItemInfo] = mediaInfos.map { mediaInfo in
            switch mediaInfo {
            case let .image(imageURL, thumbnailURL, imageInfo):
                .image(imageInfo: imageInfo,
                       source: .file(filename: imageURL.path(percentEncoded: false)),
                       caption: nil,
                       formattedCaption: nil,
                       thumbnailSource: .file(filename: thumbnailURL.path(percentEncoded: false)))
            case let .video(videoURL, thumbnailURL, videoInfo):
                .video(videoInfo: videoInfo,
                       source: .file(filename: videoURL.path(percentEncoded: false)),
                       caption: nil,
                       formattedCaption: nil,
                       thumbnailSource: .file(filename: thumbnailURL.path(percentEncoded: false)))
            case let .audio(audioURL, audioInfo):
                .audio(audioInfo: audioInfo,
                       source: .file(filename: audioURL.path(percentEncoded: false)),
                       caption: nil,
                       formattedCaption: nil)
            case let .file(fileURL, fileInfo):
                .file(fileInfo: fileInfo,
                      source: .file(filename: fileURL.path(percentEncoded: false)),
                      caption: nil,
                      formattedCaption: nil)
            }
        }
        
        return await timelineController.sendGallery(itemInfos: itemInfos,
                                                    caption: caption,
                                                    inReplyToEventID: nil)
    }
    
    func stopProcessing() {
        processingTask.cancel()
    }
    
    // MARK: - Private
    
    private static func processMedia(at urls: [URL],
                                     preprocessor: MediaUploadingPreprocessor,
                                     clientProxy: ClientProxyProtocol) -> Task<Result<[MediaInfo], MediaUploadingPreprocessorError>, Never> {
        Task {
            guard case let .success(maxUploadSize) = await clientProxy.maxMediaUploadSize else { return .failure(.maxUploadSizeUnknown) }
            return await preprocessor.processMedia(at: urls, maxUploadSize: maxUploadSize)
        }
    }
    
    private func sendAttachment(mediaInfo: MediaInfo, caption: String?) async -> Result<Void, TimelineControllerError> {
        requestHandle = nil
        let requestHandle: (@MainActor @Sendable (SendAttachmentJoinHandleProtocol) -> Void) = { [weak self] handle in
            self?.requestHandle = handle
        }
        
        switch mediaInfo {
        case let .image(imageURL, thumbnailURL, imageInfo):
            return await timelineController.sendImage(url: imageURL,
                                                      thumbnailURL: thumbnailURL,
                                                      imageInfo: imageInfo,
                                                      caption: caption,
                                                      clearComposer: !confirmedPicker,
                                                      requestHandle: requestHandle)
        case let .video(videoURL, thumbnailURL, videoInfo):
            return await timelineController.sendVideo(url: videoURL,
                                                      thumbnailURL: thumbnailURL,
                                                      videoInfo: videoInfo,
                                                      caption: caption,
                                                      clearComposer: !confirmedPicker,
                                                      requestHandle: requestHandle)
        case let .audio(audioURL, audioInfo):
            return await timelineController.sendAudio(url: audioURL,
                                                      audioInfo: audioInfo,
                                                      caption: caption,
                                                      clearComposer: !confirmedPicker,
                                                      requestHandle: requestHandle)
        case let .file(fileURL, fileInfo):
            return await timelineController.sendFile(url: fileURL,
                                                     fileInfo: fileInfo,
                                                     caption: caption,
                                                     clearComposer: !confirmedPicker,
                                                     requestHandle: requestHandle)
        }
    }
    
    // Separate selections may be preparing/uploading concurrently.
    private let loadingIndicatorIdentifier = "MediaUploadPreview-" + UUID().uuidString
    
    private func startLoading() {
        userIndicatorController.submitIndicator(UserIndicator(id: loadingIndicatorIdentifier,
                                                              type: confirmedPicker ? .toast(progress: .indeterminate) : .modal(progress: .indeterminate, interactiveDismissDisabled: false, allowsInteraction: true),
                                                              title: L10n.commonPreparing,
                                                              persistent: true),
                                                delay: .milliseconds(100))
        
        state.shouldDisableInteraction = true
    }
    
    private func stopLoading() {
        userIndicatorController.retractIndicatorWithId(loadingIndicatorIdentifier)
        state.shouldDisableInteraction = false
        requestHandle = nil
    }
    
    private func showError(label: String) {
        userIndicatorController.submitIndicator(UserIndicator(title: label))
    }

    private func restoreCaptionAfterPreparationFailure(_ caption: String?) {
        guard confirmedPicker, let caption else { return }
        timelineController.callbacks.send(.restoreComposerDraftIfEmpty(caption))
    }
    
    private func showAlert(_ alertType: MediaUploadPreviewAlertType) {
        if confirmedPicker {
            // There is no hidden preview on which to present an alert. Keep the
            // native validation/error text visible in the active room instead.
            switch alertType {
            case .maxUploadSizeUnknown:
                showError(label: L10n.screenMediaUploadPreviewErrorCouldNotBeUploaded)
            case .maxUploadSizeExceeded(let limit):
                showError(label: L10n.screenMediaUploadPreviewErrorTooLargeMessage(limit.formatted(.byteCount(style: .file))))
            }
            return
        }
        switch alertType {
        case .maxUploadSizeUnknown:
            state.bindings.alertInfo = .init(id: alertType,
                                             title: L10n.commonSomethingWentWrong,
                                             message: L10n.screenMediaUploadPreviewErrorCouldNotBeUploaded,
                                             primaryButton: .init(title: L10n.actionTryAgain) { [weak self] in
                                                 guard let self else { return }
                                                 processingTask = Self.processMedia(at: mediaURLs, preprocessor: mediaUploadingPreprocessor, clientProxy: clientProxy)
                                                 process(viewAction: .send)
                                             },
                                             secondaryButton: .init(title: L10n.actionCancel, role: .cancel) { })
        case .maxUploadSizeExceeded(let limit):
            state.bindings.alertInfo = .init(id: alertType,
                                             title: L10n.screenMediaUploadPreviewErrorTooLargeTitle,
                                             message: L10n.screenMediaUploadPreviewErrorTooLargeMessage(limit.formatted(.byteCount(style: .file))),
                                             primaryButton: .init(title: L10n.actionCancel, role: .cancel) { })
        }
    }
}

extension NSAttributedString {
    var nonBlankString: String? {
        guard !string.isBlank else { return nil }
        return string
    }
}
