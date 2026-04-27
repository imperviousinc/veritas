//
//  ShareViewController.swift
//  VeritasShare
//
//
//

import Cocoa
import UniformTypeIdentifiers

class ShareViewController: NSViewController {

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        let label = NSTextField(labelWithString: "Analyzing with Veritas…")
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -10),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 8),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        processSharedItems()
    }

    private func processSharedItems() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = extensionItem.attachments else {
            done(query: nil)
            return
        }

        // Try image first
        if let imageProvider = attachments.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }) {
            imageProvider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { [weak self] data, _ in
                var image: NSImage?
                if let url = data as? URL {
                    image = NSImage(contentsOf: url)
                } else if let imgData = data as? Data {
                    image = NSImage(data: imgData)
                } else if let nsImage = data as? NSImage {
                    image = nsImage
                }

                guard let image else {
                    self?.done(query: nil)
                    return
                }

                Task {
                    let query = await ImageOCR.extractQuery(from: image)
                    self?.done(query: query)
                }
            }
            return
        }

        // Try plain text
        if let textProvider = attachments.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }) {
            textProvider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] data, _ in
                let text = data as? String
                self?.done(query: text)
            }
            return
        }

        // Try URL
        if let urlProvider = attachments.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) {
            urlProvider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] data, _ in
                let url = data as? URL
                self?.done(query: url?.absoluteString)
            }
            return
        }

        done(query: nil)
    }

    private func done(query: String?) {
        if let query, !query.isEmpty {
            // Post a distributed notification so the main app picks it up
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("com.impervious.veritas.shareQuery"),
                object: query,
                userInfo: nil,
                deliverImmediately: true
            )
        }

        DispatchQueue.main.async {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
}
