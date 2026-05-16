import UIKit
import ImageIO

class ShareViewController: UIViewController {

    private let appGroupId = "group.com.lab1908.instadamn"

    private let captionField = UITextField()
    private let postButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let imageView = UIImageView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()

    private var sharedImageData: Data?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadSharedImage()
    }

    private func setupUI() {
        view.backgroundColor = .systemBackground

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancelButton)

        let titleLabel = UILabel()
        titleLabel.text = "A/SIDE"
        titleLabel.font = .boldSystemFont(ofSize: 17)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        postButton.setTitle("Post", for: .normal)
        postButton.titleLabel?.font = .boldSystemFont(ofSize: 17)
        postButton.isEnabled = false
        postButton.addTarget(self, action: #selector(postTapped), for: .touchUpInside)
        postButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(postButton)

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemBackground
        imageView.layer.cornerRadius = 8
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)

        captionField.placeholder = "Write a caption..."
        captionField.font = .systemFont(ofSize: 16)
        captionField.returnKeyType = .done
        captionField.delegate = self
        captionField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(captionField)

        activityIndicator.hidesWhenStopped = true
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityIndicator)

        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),

            postButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            postButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            separator.topAnchor.constraint(equalTo: cancelButton.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            imageView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            imageView.widthAnchor.constraint(equalToConstant: 80),
            imageView.heightAnchor.constraint(equalToConstant: 80),

            captionField.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            captionField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            captionField.trailingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: -12),
            captionField.heightAnchor.constraint(equalToConstant: 44),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 30),

            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: activityIndicator.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    @objc private func postTapped() {
        guard let imageData = sharedImageData else { return }

        guard let token = readFromContainer("auth_token"),
              let baseUrl = readFromContainer("api_base_url") else {
            showStatus("Please sign in to the app first", isError: true)
            return
        }

        let caption = captionField.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        setUploading(true)
        showStatus("Uploading...", isError: false)

        getUploadUrl(baseUrl: baseUrl, token: token) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let (uploadUrl, key)):
                DispatchQueue.main.async { self.showStatus("Uploading photo...", isError: false) }
                self.uploadImage(data: imageData, to: uploadUrl) { uploadResult in
                    switch uploadResult {
                    case .success:
                        DispatchQueue.main.async { self.showStatus("Creating post...", isError: false) }
                        self.createPost(baseUrl: baseUrl, token: token, mediaKey: key, caption: caption) { postResult in
                            DispatchQueue.main.async {
                                switch postResult {
                                case .success:
                                    self.showStatus("Posted!", isError: false)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                        self.extensionContext?.completeRequest(returningItems: nil)
                                    }
                                case .failure:
                                    self.showStatus("Failed to create post", isError: true)
                                    self.setUploading(false)
                                }
                            }
                        }
                    case .failure:
                        DispatchQueue.main.async {
                            self.showStatus("Upload failed", isError: true)
                            self.setUploading(false)
                        }
                    }
                }
            case .failure:
                DispatchQueue.main.async {
                    self.showStatus("Failed to connect", isError: true)
                    self.setUploading(false)
                }
            }
        }
    }

    private func setUploading(_ uploading: Bool) {
        postButton.isEnabled = !uploading
        cancelButton.isEnabled = !uploading
        captionField.isEnabled = !uploading
        if uploading { activityIndicator.startAnimating() }
        else { activityIndicator.stopAnimating() }
    }

    private func showStatus(_ text: String, isError: Bool) {
        statusLabel.text = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabel
        statusLabel.isHidden = false
    }

    // MARK: - Load shared image (ImageIO — memory efficient)

    private func loadSharedImage() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return }
        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier("public.image") {
                    provider.loadItem(forTypeIdentifier: "public.image", options: nil) { [weak self] data, error in
                        guard let self = self, error == nil else { return }

                        DispatchQueue.global(qos: .userInitiated).async {
                            var jpegData: Data?
                            var previewImage: UIImage?

                            if let url = data as? URL {
                                // Downsample via ImageIO — never loads full bitmap
                                jpegData = self.downsampleJPEG(url: url, maxDimension: 1080)
                                if let d = jpegData { previewImage = UIImage(data: d) }
                            } else if let image = data as? UIImage {
                                jpegData = image.jpegData(compressionQuality: 0.85)
                                previewImage = image
                            }

                            DispatchQueue.main.async {
                                guard let jpegData = jpegData else {
                                    self.showStatus("Could not load image", isError: true)
                                    return
                                }
                                self.sharedImageData = jpegData
                                self.imageView.image = previewImage
                                self.postButton.isEnabled = true
                            }
                        }
                    }
                    return
                }
            }
        }
    }

    /// Memory-efficient downsampling — doesn't decode full image into memory
    private func downsampleJPEG(url: URL, maxDimension: CGFloat) -> Data? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85)
    }

    // MARK: - App Group

    private func readFromContainer(_ key: String) -> String? {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId) else { return nil }
        let fileUrl = url.appendingPathComponent("\(key).txt")
        guard let value = try? String(contentsOf: fileUrl, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    // MARK: - API

    private func getUploadUrl(baseUrl: String, token: String, completion: @escaping (Result<(String, String), Error>) -> Void) {
        guard let url = URL(string: "\(baseUrl)/v1/posts/upload-url") else {
            completion(.failure(NSError(domain: "ShareExt", code: -1))); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["content_type": "image/jpeg", "count": 1])

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error { return completion(.failure(error)) }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let uploads = json["uploads"] as? [[String: Any]],
                  let first = uploads.first,
                  let uploadUrl = first["upload_url"] as? String,
                  let key = first["key"] as? String else {
                return completion(.failure(NSError(domain: "ShareExt", code: -2)))
            }
            completion(.success((uploadUrl, key)))
        }.resume()
    }

    private func uploadImage(data: Data, to urlString: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "ShareExt", code: -1))); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error { return completion(.failure(error)) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 200 && status < 300 { completion(.success(())) }
            else { completion(.failure(NSError(domain: "ShareExt", code: status))) }
        }.resume()
    }

    private func createPost(baseUrl: String, token: String, mediaKey: String, caption: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: "\(baseUrl)/v1/posts") else {
            completion(.failure(NSError(domain: "ShareExt", code: -1))); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "media": [["key": mediaKey, "media_type": "photo", "position": 0]]
        ]
        if let caption = caption, !caption.isEmpty {
            body["caption"] = caption
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error { return completion(.failure(error)) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 200 && status < 300 { completion(.success(())) }
            else { completion(.failure(NSError(domain: "ShareExt", code: status))) }
        }.resume()
    }
}

// MARK: - Caption length limit

extension ShareViewController: UITextFieldDelegate {
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let current = textField.text ?? ""
        guard let range = Range(range, in: current) else { return false }
        let updated = current.replacingCharacters(in: range, with: string)
        return updated.count <= 280
    }
}
