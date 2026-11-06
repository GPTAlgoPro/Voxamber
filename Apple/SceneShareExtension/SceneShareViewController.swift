import UIKit
import UniformTypeIdentifiers
import Foundation
import Darwin

/// Receives one UTF8 representation, asks for an explicit save, then finishes.
/// The extension never executes code, fetches URLs or opens the main App.
@MainActor final class SceneShareViewController: UIViewController {
    private let titleLabel = UILabel(), detailLabel = UILabel(), statusLabel = UILabel()
    private let preview = UITextView(), saveButton = UIButton(type: .system), cancelButton = UIButton(type: .system)
    private let provider = ShareProviderProgress(), decision = ShareSaveDecision()
    private var workflow: Task<Void, Never>?
    private var committed = false, ending = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        titleLabel.text = "存入维珀"; titleLabel.font = .preferredFont(forTextStyle: .title2)
        detailLabel.numberOfLines = 0; statusLabel.numberOfLines = 0
        detailLabel.font = .preferredFont(forTextStyle: .body); statusLabel.font = .preferredFont(forTextStyle: .footnote)
        for label in [titleLabel, detailLabel, statusLabel] { label.adjustsFontForContentSizeCategory = true }
        detailLabel.text = "接收一份代码文件或文本。存入后，请打开维珀检查并生成三维模型。"
        preview.isEditable = false; preview.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        preview.backgroundColor = .secondarySystemBackground; preview.layer.cornerRadius = 12
        saveButton.setTitle("存入维珀", for: .normal); saveButton.isEnabled = false
        cancelButton.setTitle("取消", for: .normal)
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [cancelButton, saveButton]); buttons.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel, preview, statusLabel, buttons])
        stack.axis = .vertical; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 160), buttons.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        statusLabel.text = "正在读取分享内容…"
        workflow = Task { [weak self] in
            guard let self else { return }
            await self.runWorkflow()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !ending { requestCancellation() }
    }

    @objc private func saveTapped() {
        saveButton.isEnabled = false; statusLabel.text = "正在安全存入…"
        decision.resolve(true)
    }
    @objc private func cancelTapped() { requestCancellation() }
    private func requestCancellation() {
        guard !ending else { return }
        saveButton.isEnabled = false; cancelButton.isEnabled = false; statusLabel.text = "正在取消…"
        workflow?.cancel(); provider.cancel(); decision.resolve(false)
    }

    private func runWorkflow() async {
        defer { workflow = nil }
        let provider = self.provider, decision = self.decision
        do {
            let payload = try await withTaskCancellationHandler {
                try await receiveOnePayload()
            } onCancel: { provider.cancel(); decision.resolve(false) }
            try Task.checkCancellation()
            let text = try Self.validatedText(payload.bytes)
            preview.text = String(text.prefix(12_000))
            let name = payload.filename.map { $0 + " · " } ?? ""
            detailLabel.text = name + ByteCountFormatter.string(fromByteCount: Int64(payload.bytes.count), countStyle: .file)
                + "\n请确认要存入的原文。这里不会运行代码。"
            statusLabel.text = text.count > 12_000 ? "预览只显示前 12000 字，存入时会保留完整原文。" : "等待你确认存入。"
            saveButton.isEnabled = true
            let accepted = await withTaskCancellationHandler { await decision.wait() } onCancel: { decision.resolve(false) }
            guard accepted else { throw CancellationError() }
            try Task.checkCancellation()
            let inbox = try SceneImportInbox.openShared()
            _ = try await inbox.store(bytes: payload.bytes, originalFilename: payload.filename)
            // Store's atomic entry commit has won. Do not check cancellation
            // here and incorrectly tell the user that a saved entry was lost.
            committed = true; ending = true
            saveButton.isEnabled = false; cancelButton.isEnabled = false
            statusLabel.text = "已存入维珀。请打开维珀，从导入箱继续。"
            if view.window == nil { extensionContext?.completeRequest(returningItems: nil); return }
            let notice = UIAlertController(title: "已存入维珀", message: "请打开维珀，在导入箱检查代码并生成模型。", preferredStyle: .alert)
            notice.addAction(UIAlertAction(title: "完成", style: .default) { [weak self] _ in
                self?.extensionContext?.completeRequest(returningItems: nil)
            })
            present(notice, animated: true)
        } catch {
            ending = true
            if committed { extensionContext?.completeRequest(returningItems: nil); return }
            if Task.isCancelled || error is CancellationError || provider.isCancelled {
                extensionContext?.cancelRequest(withError: CocoaError(.userCancelled)); return
            }
            statusLabel.text = error.localizedDescription; saveButton.isEnabled = false
            cancelButton.isEnabled = true; cancelButton.setTitle("关闭", for: .normal)
            cancelButton.removeTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
            cancelButton.addTarget(self, action: #selector(closeFailedRequest), for: .touchUpInside)
        }
    }

    @objc private func closeFailedRequest() {
        extensionContext?.cancelRequest(withError: ShareInputError.unsupported)
    }

    private func receiveOnePayload() async throws -> SharePayload {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let attachments = items.flatMap { $0.attachments ?? [] }
        if attachments.isEmpty, items.count == 1, let text = items[0].attributedContentText?.string {
            let bytes = Data(text.utf8); _ = try Self.validatedText(bytes)
            return SharePayload(bytes: bytes, filename: nil)
        }
        guard attachments.count == 1, let item = attachments.first else { throw ShareInputError.oneItemOnly }
        // Conversation links are not fetched or converted into content.
        if item.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           !item.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { throw ShareInputError.linkOnly }
        if item.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return try await loadFile(item, type: UTType.fileURL.identifier)
        }
        let textTypes = [UTType.utf8PlainText.identifier, UTType.plainText.identifier]
        if let type = textTypes.first(where: { item.hasItemConformingToTypeIdentifier($0) }) {
            return try await loadText(item, type: type)
        }
        guard let type = item.registeredTypeIdentifiers.first(where: { identifier in
            guard let type = UTType(identifier), !type.conforms(to: .url) else { return false }
            return type.conforms(to: .data) || type.conforms(to: .item)
        }) else { throw ShareInputError.unsupported }
        return try await loadFile(item, type: type)
    }

    private func loadText(_ item: NSItemProvider, type: String) async throws -> SharePayload {
        let state = provider
        return try await withCheckedThrowingContinuation { continuation in
            let completion = ShareCompletion(continuation)
            let progress = item.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if state.isCancelled { completion.finish(.failure(CancellationError())); return }
                if let error { completion.finish(.failure(error)); return }
                guard let data else { completion.finish(.failure(ShareInputError.unsupported)); return }
                do { _ = try Self.validatedText(data); completion.finish(.success(.init(bytes: data, filename: nil))) }
                catch { completion.finish(.failure(error)) }
            }
            state.install(progress)
        }
    }

    private func loadFile(_ item: NSItemProvider, type: String) async throws -> SharePayload {
        let state = provider
        return try await withCheckedThrowingContinuation { continuation in
            let completion = ShareCompletion(continuation)
            let progress = item.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                if state.isCancelled { completion.finish(.failure(CancellationError())); return }
                if let error { completion.finish(.failure(error)); return }
                guard let url else { completion.finish(.failure(ShareInputError.unsupported)); return }
                do {
                    // Provider temporary URLs are only valid during this
                    // callback. Read the bounded regular file here, not later.
                    let bytes = try Self.readProviderFile(url, cancellation: state)
                    _ = try Self.validatedText(bytes)
                    completion.finish(.success(.init(bytes: bytes, filename: url.lastPathComponent)))
                } catch { completion.finish(.failure(error)) }
            }
            state.install(progress)
        }
    }

    private nonisolated static func validatedText(_ bytes: Data) throws -> String {
        guard !bytes.isEmpty else { throw ShareInputError.empty }
        guard bytes.count <= SceneImportInbox.maximumBytes else { throw ShareInputError.tooLarge }
        guard let text = String(data: bytes, encoding: .utf8) else { throw ShareInputError.notUTF8 }
        return text
    }

    private nonisolated static func readProviderFile(_ url: URL, cancellation: ShareProviderProgress) throws -> Data {
        guard url.isFileURL else { throw ShareInputError.unsupported }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ShareInputError.unsafeFile }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= SceneImportInbox.maximumBytes else { throw ShareInputError.unsafeFile }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            if cancellation.isCancelled { throw CancellationError() }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw ShareInputError.unsafeFile }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count <= SceneImportInbox.maximumBytes else { throw ShareInputError.tooLarge }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, bytes.count == before.st_size, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw ShareInputError.unsafeFile }
        if cancellation.isCancelled { throw CancellationError() }
        return bytes
    }
}

private struct SharePayload: Sendable { let bytes: Data; let filename: String? }
private enum ShareInputError: LocalizedError {
    case unsupported, oneItemOnly, linkOnly, empty, tooLarge, notUTF8, unsafeFile
    var errorDescription: String? {
        switch self {
        case .unsupported: "请选择代码文件或纯文本分享。"
        case .oneItemOnly: "每次请分享一份代码文件或文本。"
        case .linkOnly: "收到的是链接。请分享场景代码文本或代码文件；维珀不会读取对话链接。"
        case .empty: "分享内容为空。"
        case .tooLarge: "分享内容超过 4 MiB，请精简后重试。"
        case .notUTF8: "请选择 UTF8 文本或代码文件。"
        case .unsafeFile: "无法安全读取这份文件，请重新从“文件”分享。"
        }
    }
}

private final class ShareProviderProgress: @unchecked Sendable {
    private let lock = NSLock(); private var progress: Progress?; private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func install(_ value: Progress) { lock.lock(); progress = value; let cancel = cancelled; lock.unlock(); if cancel { value.cancel() } }
    func cancel() { lock.lock(); cancelled = true; let value = progress; lock.unlock(); value?.cancel() }
}
private final class ShareCompletion: @unchecked Sendable {
    private let lock = NSLock(); private var continuation: CheckedContinuation<SharePayload, Error>?
    init(_ continuation: CheckedContinuation<SharePayload, Error>) { self.continuation = continuation }
    func finish(_ result: Result<SharePayload, Error>) { lock.lock(); let waiting = continuation; continuation = nil; lock.unlock(); waiting?.resume(with: result) }
}
private final class ShareSaveDecision: @unchecked Sendable {
    private let lock = NSLock(); private var answer: Bool?; private var continuation: CheckedContinuation<Bool, Never>?
    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock(); let answer = self.answer; if answer == nil { self.continuation = continuation }; lock.unlock()
            if let answer { continuation.resume(returning: answer) }
        }
    }
    func resolve(_ answer: Bool) { lock.lock(); guard self.answer == nil else { lock.unlock(); return }; self.answer = answer; let waiting = continuation; continuation = nil; lock.unlock(); waiting?.resume(returning: answer) }
}
