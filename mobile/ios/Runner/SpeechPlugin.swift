import Flutter
import UIKit
import AVFoundation
import Speech

/// Platform channel plugin for on-device speech recognition using SpeechAnalyzer (iOS 26+).
/// Audio never leaves the device.
class SpeechPlugin: NSObject, FlutterPlugin {
    private let methodChannel: FlutterMethodChannel
    private var eventSink: FlutterEventSink?

    private var audioEngine: AVAudioEngine?
    private var isListening = false
    private var startTime: Date?

    // SpeechAnalyzer references (iOS 26+)
    private var analyzer: Any?
    private var transcriber: Any?
    private var transcriptionTask: Any?
    private var analysisTask: Any?
    private var silenceTimer: Any?
    private var inputContinuation: Any?
    private let silenceTimeoutSeconds: TimeInterval = 30

    init(methodChannel: FlutterMethodChannel) {
        self.methodChannel = methodChannel
        super.init()
    }

    static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "com.lab1908.instadamn/speech",
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: "com.lab1908.instadamn/speech_events",
            binaryMessenger: registrar.messenger()
        )
        let instance = SpeechPlugin(methodChannel: methodChannel)
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isAvailable":
            result(checkAvailability())
        case "startListening":
            startListening(result: result)
        case "stopListening":
            stopListening(result: result)
        case "cancelListening":
            cancelListening(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Availability

    private func checkAvailability() -> Bool {
        guard #available(iOS 26, *) else { return false }
        return true
    }

    // MARK: - Permissions

    @available(iOS 17, *)
    private func requestPermissions(completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { micGranted in
            guard micGranted else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            if #available(iOS 26, *) {
                SFSpeechRecognizer.requestAuthorization { status in
                    DispatchQueue.main.async {
                        completion(status == .authorized)
                    }
                }
            } else {
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    // MARK: - Start Listening

    private func startListening(result: @escaping FlutterResult) {
        guard #available(iOS 26, *) else {
            result(FlutterError(code: "UNAVAILABLE", message: "Requires iOS 26+", details: nil))
            return
        }

        if isListening {
            result(FlutterError(code: "ALREADY_LISTENING", message: "Already listening", details: nil))
            return
        }

        requestPermissions { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                result(FlutterError(code: "PERMISSION_DENIED", message: "Microphone or speech recognition permission denied", details: nil))
                return
            }

            if #available(iOS 26, *) {
                Task { @MainActor in
                    await self.startSpeechAnalyzer(result: result)
                }
            }
        }
    }

    @available(iOS 26, *)
    private func startSpeechAnalyzer(result: @escaping FlutterResult) async {
        do {
            // Configure audio session first
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            // progressiveLongDictation: streaming partial results + long-form + auto-punctuation
            let dictTranscriber = DictationTranscriber(locale: Locale.current, preset: .progressiveLongDictation)
            self.transcriber = dictTranscriber

            // Create the analyzer and prepare it (allocates locale resources)
            let speechAnalyzer = SpeechAnalyzer(modules: [dictTranscriber])
            self.analyzer = speechAnalyzer

            // Get the format SpeechAnalyzer needs (16-bit Int16)
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [dictTranscriber])
            guard let targetFormat = analyzerFormat else {
                result(FlutterError(code: "FORMAT_ERROR", message: "No compatible audio format available", details: nil))
                return
            }

            // Prepare the analyzer with the target format (allocates locale)
            try await speechAnalyzer.prepareToAnalyze(in: targetFormat)

            // Configure audio engine
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let hardwareFormat = inputNode.outputFormat(forBus: 0)

            // Create converter from hardware format (48kHz Float32) to analyzer format (16kHz Int16)
            guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
                result(FlutterError(code: "CONVERTER_ERROR", message: "Cannot create audio format converter", details: nil))
                return
            }

            // Create async stream for feeding audio buffers to the analyzer
            let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
            self.inputContinuation = inputBuilder

            // Tap audio in hardware format, convert to analyzer format, then feed
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { buffer, _ in
                let frameCount = AVAudioFrameCount(
                    Double(buffer.frameLength) * targetFormat.sampleRate / hardwareFormat.sampleRate
                )
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

                var error: NSError?
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                if error == nil && convertedBuffer.frameLength > 0 {
                    inputBuilder.yield(AnalyzerInput(buffer: convertedBuffer))
                }
            }

            engine.prepare()
            try engine.start()

            self.audioEngine = engine
            self.isListening = true
            self.startTime = Date()

            // Start silence timeout
            resetSilenceTimer()

            // Start analysis on the input sequence in a background task
            self.analysisTask = Task {
                do {
                    try await speechAnalyzer.start(inputSequence: inputSequence)
                } catch {
                    // Analysis ended
                }
            }

            // Observe transcription results in a background task
            self.transcriptionTask = Task { [weak self] in
                do {
                    for try await transcript in dictTranscriber.results {
                        guard let self = self else { break }
                        let text = String(transcript.text.characters)
                        let isFinal = transcript.isFinal

                        DispatchQueue.main.async {
                            // Reset silence timer on every result
                            self.resetSilenceTimer()
                            self.eventSink?([
                                "text": text,
                                "isFinal": isFinal
                            ])
                        }
                    }
                } catch {
                    // Stream ended or error
                }
            }

            result(true)
        } catch {
            await cleanupAudio(finalize: false)
            result(FlutterError(code: "START_FAILED", message: "\(error)", details: "\(error.localizedDescription)"))
        }
    }

    // MARK: - Stop Listening

    private func stopListening(result: @escaping FlutterResult) {
        guard isListening else {
            result(nil)
            return
        }

        if #available(iOS 26, *) {
            Task { @MainActor in
                await self.cleanupAudio(finalize: true)
                result(nil)
            }
        } else {
            result(nil)
        }
    }

    // MARK: - Cancel Listening

    private func cancelListening(result: @escaping FlutterResult) {
        if #available(iOS 26, *) {
            Task { @MainActor in
                await self.cleanupAudio(finalize: false)
                result(nil)
            }
        } else {
            result(nil)
        }
    }

    // MARK: - Silence Timer

    private func resetSilenceTimer() {
        if let timer = silenceTimer as? Timer {
            timer.invalidate()
        }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeoutSeconds, repeats: false) { [weak self] _ in
            guard let self = self, self.isListening else { return }
            // Silence timeout — send a done event and stop
            self.eventSink?(["text": "", "isFinal": true, "timedOut": true])
            if #available(iOS 26, *) {
                Task { @MainActor in
                    await self.cleanupAudio(finalize: true)
                }
            }
        }
    }

    private func cancelSilenceTimer() {
        if let timer = silenceTimer as? Timer {
            timer.invalidate()
        }
        silenceTimer = nil
    }

    // MARK: - Cleanup

    @available(iOS 26, *)
    private func cleanupAudio(finalize: Bool) async {
        cancelSilenceTimer()

        // Stop audio engine
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        // Finish the input stream
        if let continuation = inputContinuation as? AsyncStream<AnalyzerInput>.Continuation {
            continuation.finish()
        }
        inputContinuation = nil

        // Finalize or cancel the analyzer
        if let analyzer = self.analyzer as? SpeechAnalyzer {
            if finalize {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            } else {
                await analyzer.cancelAndFinishNow()
            }
        }

        // Cancel tasks
        if let task = analysisTask as? Task<Void, Never> {
            task.cancel()
        }
        analysisTask = nil

        if let task = transcriptionTask as? Task<Void, Never> {
            task.cancel()
        }
        transcriptionTask = nil

        analyzer = nil
        transcriber = nil
        isListening = false
        startTime = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - FlutterStreamHandler

extension SpeechPlugin: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
