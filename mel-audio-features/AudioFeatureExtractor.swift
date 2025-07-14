import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import Accelerate

struct ArchiveRecord: Identifiable, Codable {
    let id: UUID
    let date: Date
    let audioFileName: String // 상대경로
    let features: [Float]
}

typealias Archive = [ArchiveRecord]

class AudioFeatureExtractor: NSObject, ObservableObject, AVAudioRecorderDelegate {
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var audioFileURL: URL?
    
    private var recordingTimer: Timer?
    private let maxRecordingDuration: TimeInterval = 3.0
    
    @Published var isRecording = false
    @Published var extractedFeatures: [Float]? // 추출된 특징 벡터
    @Published var errorMessage: String?
    @Published var archive: Archive = []
    
    private let archiveFileName = "audio_archive.json"
    
    override init() {
        super.init()
        setupAudioSession()
        self.loadArchive()
    }
    
    // 오디오 세션 설정 (녹음 권한 요청)
    private func setupAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
            audioSession.requestRecordPermission { [weak self] granted in
                if !granted {
                    DispatchQueue.main.async {
                        self?.errorMessage = "Microphone permission denied."
                    }
                }
            }
        } catch {
            errorMessage = "Failed to set up audio session: \(error.localizedDescription)"
        }
    }
    
    func analyzeExternalFile(url: URL) {
        processAudioFile(url: url)
    }
    
    func startRecording() {
        let filename = UUID().uuidString + ".m4a"
        audioFileURL = getDocumentsDirectory().appendingPathComponent(filename)
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 22050, // 샘플레이트
            AVNumberOfChannelsKey: 1, // 모노 채널
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFileURL!, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()
            isRecording = true
            errorMessage = nil
            
            // Start auto-stop timer
            recordingTimer?.invalidate()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: maxRecordingDuration, repeats: false) { [weak self] _ in
                self?.stopRecording()
            }
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }
    
    // 녹음 종료 후 오디오 파일 처리
    func stopRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        audioRecorder?.stop()
        isRecording = false
        if let url = audioFileURL {
            processAudioFile(url: url)
        }
    }
    
    func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }
    
    func getArchiveFileURL() -> URL {
        getDocumentsDirectory().appendingPathComponent(archiveFileName)
    }
    
    // 기록된 archive 로드
    func loadArchive() {
        let url = getArchiveFileURL()
        do {
            let data = try Data(contentsOf: url)
            let loaded = try JSONDecoder().decode(Archive.self, from: data)
            DispatchQueue.main.async {
                self.archive = loaded
            }
        } catch {
            // 파일 없으면 빈 배열로 시작
            self.archive = []
        }
    }
    
    func saveArchive() {
        let url = getArchiveFileURL()
        do {
            let data = try JSONEncoder().encode(archive)
            try data.write(to: url)
        } catch {
            print("Failed to save archive: \(error)")
        }
    }
    
    // 오디오 파일 처리 → 특징 추출
    func processAudioFile(url: URL) {
        do {
            let originalAudioFile = try AVAudioFile(forReading: url)
            let originalFormat = originalAudioFile.processingFormat
            let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 1, interleaved: false)!

            let needsConversion = originalFormat.channelCount != 1 || originalFormat.commonFormat != .pcmFormatFloat32 || originalFormat.sampleRate != 22050
            var audioFile: AVAudioFile = originalAudioFile

            if needsConversion {
                // Prepare AVAudioConverter
                let converter = AVAudioConverter(from: originalFormat, to: targetFormat)!
                let frameCount = AVAudioFrameCount(originalAudioFile.length)
                guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: originalFormat, frameCapacity: frameCount) else {
                    errorMessage = "Failed to create input buffer."
                    return
                }
                try originalAudioFile.read(into: inputBuffer)
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
                    errorMessage = "Failed to create output buffer."
                    return
                }
                var error: NSError? = nil
                let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                    outStatus.pointee = .haveData
                    return inputBuffer
                }
                converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
                if let error = error {
                    self.errorMessage = "Error converting audio: \(error.localizedDescription)"
                    return
                }
                // Write to a temp file
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
                do {
                    let outputFile = try AVAudioFile(forWriting: tempURL, settings: targetFormat.settings)
                    try outputFile.write(from: outputBuffer)
                    audioFile = try AVAudioFile(forReading: tempURL)
                } catch {
                    self.errorMessage = "Error writing converted file: \(error.localizedDescription)"
                    return
                }
            }

            let format = audioFile.processingFormat
            let frameCount = AVAudioFrameCount(audioFile.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                errorMessage = "Failed to create audio buffer."
                return
            }
            try audioFile.read(into: buffer)
            guard let floatChannelData = buffer.floatChannelData else {
                errorMessage = "Failed to get float channel data."
                return
            }
            let audioSamples = Array(UnsafeBufferPointer(start: floatChannelData[0], count: Int(frameCount)))
            let preprocessedSamples = preprocessAudio(samples: audioSamples, sampleRate: Float(format.sampleRate))
            extractedFeatures = extractFeatures(samples: preprocessedSamples, sampleRate: 22050)
            if let features = self.extractedFeatures, !features.isEmpty {
                let record = ArchiveRecord(id: UUID(), date: Date(), audioFileName: url.lastPathComponent, features: features)
                self.archive.append(record)
                self.saveArchive()
            }
        } catch {
            errorMessage = "Error processing audio file: \(error.localizedDescription)"
        }
    }
    
    // 오디오 정규화 + 단순 무음 제거
    private func preprocessAudio(samples: [Float], sampleRate: Float) -> [Float] {
        var processedSamples = samples
        
        // 1. -1 ~ 1 사이로 정규화
        if let maxAbs = processedSamples.map({ abs($0) }).max(), maxAbs > 0 {
            processedSamples = processedSamples.map { $0 / maxAbs }
        }
        
        
        // 2. 무음 구간 앞뒤 잘라내기 (단순 임계값 기반)
        let silenceThreshold: Float = 0.01
        var startIndex = 0
        for i in 0..<processedSamples.count {
            if abs(processedSamples[i]) > silenceThreshold {
                startIndex = i
                break
            }
        }
        
        var endIndex = processedSamples.count - 1
        for i in (0..<processedSamples.count).reversed() {
            if abs(processedSamples[i]) > silenceThreshold {
                endIndex = i
                break
            }
        }
        
        if startIndex <= endIndex {
            processedSamples = Array(processedSamples[startIndex...endIndex])
        } else {
            processedSamples = [] // 전체 무음인 경우
        }
        
        return processedSamples
    }
    
    func calculateRMSEnergy(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0.0 }
        var squaredSamples = [Float](repeating: 0.0, count: samples.count)
        vDSP_vsq(samples, 1, &squaredSamples, 1, vDSP_Length(samples.count))
        var sumOfSquares: Float = 0.0
        vDSP_sve(squaredSamples, 1, &sumOfSquares, vDSP_Length(squaredSamples.count))
        return sqrt(sumOfSquares / Float(samples.count))
    }
    
    func calculateEnergyEntropy(samples: [Float], frameSize: Int, hopSize: Int) -> Float {
        guard !samples.isEmpty else { return 0.0 }
        
        var energies: [Float] = []
        for i in stride(from: 0, to: samples.count - frameSize + 1, by: hopSize) {
            let frame = Array(samples[i..<i+frameSize])
            var sumOfSquares: Float = 0.0
            var squaredFrame = [Float](repeating: 0.0, count: frame.count)
            vDSP_vsq(frame, 1, &squaredFrame, 1, vDSP_Length(frame.count))
            vDSP_sve(squaredFrame, 1, &sumOfSquares, vDSP_Length(squaredFrame.count))
            energies.append(sumOfSquares)
        }
        
        guard !energies.isEmpty else { return 0.0 }
        
        let totalEnergy = energies.reduce(0, +)
        guard totalEnergy > 0 else { return 0.0 }
        
        let probabilities = energies.map { $0 / totalEnergy }
        
        var entropy: Float = 0.0
        for p in probabilities {
            if p > 0 {
                entropy -= p * log2(p)
            }
        }
        return entropy
    }
    
    func calculateDynamicRange(peakEnergy: Float, rmsEnergy: Float) -> Float {
        guard rmsEnergy > 0 else { return 0.0 } // 0으로 나누는 것 방지
        return 20 * log10(peakEnergy / rmsEnergy)
    }
    
    func calculateZeroCrossingRate(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0.0 }
        var zcr: Float = 0.0
        for i in 1..<samples.count {
            if (samples[i-1] >= 0 && samples[i] < 0) || (samples[i-1] < 0 && samples[i] >= 0) {
                zcr += 1
            }
        }
        return zcr / Float(samples.count)
    }
    
    // 해닝 윈도우 함수
    func hanningWindow(size: Int) -> [Float] {
        var window = [Float](repeating: 0.0, count: size)
        for i in 0..<size {
            window[i] = 0.5 * (1 - cos(2 * .pi * Float(i) / Float(size - 1)))
        }
        return window
    }
    
    // Short-Time Fourier Transform (STFT)
    func stft(samples: [Float], n_fft: Int, hop_length: Int) -> [[Float]] {
        var spectrogram: [[Float]] = []
        let window = hanningWindow(size: n_fft)
        
        let numFrames = Int(floor(Float(samples.count - n_fft) / Float(hop_length))) + 1
        
        // numFrames가 1보다 작을 때(즉, 잘못된 범위가 만들어질 때) 반복을 건너뛰고 빈 배열을 반환
        if numFrames < 1 {
            return []
        }
        
        for i in 0..<numFrames {
            let start = i * hop_length
            let end = start + n_fft
            guard end <= samples.count else { break }
            
            var frame = Array(samples[start..<end])
            
            // Apply window
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(n_fft))
            
            // Perform FFT
            let log2n = vDSP_Length(log2(Float(n_fft)))
            let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
            
            var real = [Float](repeating: 0.0, count: n_fft / 2)
            var imag = [Float](repeating: 0.0, count: n_fft / 2)
            var complex = DSPSplitComplex(realp: &real, imagp: &imag)
            
            frame.withUnsafeMutableBufferPointer { (frameBuffer: inout UnsafeMutableBufferPointer<Float>) in
                frameBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n_fft / 2) { (complexBuffer: UnsafeMutablePointer<DSPComplex>) in
                    vDSP_ctoz(complexBuffer, 2, &complex, 1, vDSP_Length(n_fft / 2))
                }
            }
            
            vDSP_fft_zrip(fftSetup!, &complex, 1, log2n, FFTDirection(kFFTDirection_Forward))
            
            // 크기 계산
            var magnitudes = [Float](repeating: 0.0, count: n_fft / 2)
            vDSP_zvmags(&complex, 1, &magnitudes, 1, vDSP_Length(n_fft / 2))
            
            // 파워 스펙트럼으로 변환 (크기 제곱)
            var powerSpectrum = [Float](repeating: 0.0, count: n_fft / 2)
            vDSP_vsq(magnitudes, 1, &powerSpectrum, 1, vDSP_Length(n_fft / 2))
            
            spectrogram.append(powerSpectrum)
            
            vDSP_destroy_fftsetup(fftSetup)
        }
        return spectrogram
    }
    
    func calculateSpectralCentroid(spectrogram: [[Float]], sampleRate: Float, n_fft: Int) -> [Float] {
        guard !spectrogram.isEmpty else { return [] }
        
        var centroids: [Float] = []
        let fftBins = n_fft / 2
        let frequencies = (0..<fftBins).map { Float($0) * sampleRate / Float(n_fft) }
        
        for frame in spectrogram {
            var sumWeightedFrequencies: Float = 0.0
            var sumMagnitudes: Float = 0.0
            
            for i in 0..<frame.count {
                sumWeightedFrequencies += frequencies[i] * frame[i]
                sumMagnitudes += frame[i]
            }
            
            if sumMagnitudes > 0 {
                centroids.append(sumWeightedFrequencies / sumMagnitudes)
            } else {
                centroids.append(0.0)
            }
        }
        return centroids
    }
    
    func calculateSpectralBandwidth(spectrogram: [[Float]], spectralCentroids: [Float], sampleRate: Float, n_fft: Int) -> Float {
        guard !spectrogram.isEmpty && !spectralCentroids.isEmpty else { return 0.0 }
        
        var bandwidths: [Float] = []
        let fftBins = n_fft / 2
        let frequencies = (0..<fftBins).map { Float($0) * sampleRate / Float(n_fft) }
        
        for (frameIndex, frame) in spectrogram.enumerated() {
            let centroid = spectralCentroids[frameIndex]
            var sumWeightedSquaredFrequencies: Float = 0.0
            var sumMagnitudes: Float = 0.0
            
            for i in 0..<frame.count {
                sumWeightedSquaredFrequencies += pow(frequencies[i] - centroid, 2) * frame[i]
                sumMagnitudes += frame[i]
            }
            
            if sumMagnitudes > 0 {
                bandwidths.append(sqrt(sumWeightedSquaredFrequencies / sumMagnitudes))
            } else {
                bandwidths.append(0.0)
            }
        }
        return bandwidths.reduce(0, +) / Float(bandwidths.count)
    }
    
    func calculateSpectralContrast(spectrogram: [[Float]]) -> Float {
        guard !spectrogram.isEmpty else { return 0.0 }
        
        var contrasts: [Float] = []
        for frame in spectrogram {
            // 단순화된 콘트라스트 계산: 피크(봉우리)와 밸리(골짜기)의 비율
            // 더 견고한 구현은 서브 밴드 분석을 포함할 수 있음
            guard let maxVal = frame.max(), let minVal = frame.min() else { continue }
            if minVal > 0 {
                contrasts.append(20 * log10(maxVal / minVal))
            } else {
                contrasts.append(0.0)
            }
        }
        return contrasts.reduce(0, +) / Float(contrasts.count)
    }
    
    func calculateSpectralFlatness(spectrogram: [[Float]]) -> Float {
        guard !spectrogram.isEmpty else { return 0.0 }
        
        var flatnessValues: [Float] = []
        for frame in spectrogram {
            guard frame.count > 0 else { continue }
            let geometricMean = pow(frame.reduce(1.0, *), 1.0 / Float(frame.count))
            let arithmeticMean = frame.reduce(0.0, +) / Float(frame.count)
            
            if arithmeticMean > 0 {
                flatnessValues.append(geometricMean / arithmeticMean)
            } else {
                flatnessValues.append(0.0)
            }
        }
        return flatnessValues.reduce(0, +) / Float(flatnessValues.count)
    }
    
    func calculateSpectralRolloff(spectrogram: [[Float]], sampleRate: Float, n_fft: Int, rollOffPercent: Float = 0.85) -> Float {
        guard !spectrogram.isEmpty else { return 0.0 }
        
        var rolloffs: [Float] = []
        let fftBins = n_fft / 2
        let frequencies = (0..<fftBins).map { Float($0) * sampleRate / Float(n_fft) }
        
        for frame in spectrogram {
            let totalEnergy = frame.reduce(0, +)
            guard totalEnergy > 0 else { rolloffs.append(0.0); continue }
            
            let thresholdEnergy = totalEnergy * rollOffPercent
            var currentEnergy: Float = 0.0
            
            for i in 0..<frame.count {
                currentEnergy += frame[i]
                if currentEnergy >= thresholdEnergy {
                    rolloffs.append(frequencies[i])
                    break
                }
            }
        }
        return rolloffs.reduce(0, +) / Float(rolloffs.count)
    }
    
    func calculateOnsetStrengthMean(spectrogram: [[Float]]) -> Float {
        guard !spectrogram.isEmpty else { return 0.0 }
        
        var onsetStrengths: [Float] = []
        for i in 1..<spectrogram.count {
            let currentFrame = spectrogram[i]
            let previousFrame = spectrogram[i-1]
            
            var diff: [Float] = Array(repeating: 0.0, count: currentFrame.count)
            vDSP_vsub(previousFrame, 1, currentFrame, 1, &diff, 1, vDSP_Length(currentFrame.count))
            
            // 하프 웨이브 정류 (양수 차이만 반영)
            let rectifiedDiff = diff.map { max(0, $0) }
            onsetStrengths.append(rectifiedDiff.reduce(0, +))
        }
        return onsetStrengths.reduce(0, +) / Float(onsetStrengths.count)
    }
    
    // 2차원 배열의 표준편차 계산
    func calculateStd(data: [[Float]]) -> Float {
        let flatData = data.flatMap { $0 }
        guard !flatData.isEmpty else { return 0.0 }
        let mean = flatData.reduce(0, +) / Float(flatData.count)
        let variance = flatData.map { pow($0 - mean, 2) }.reduce(0, +) / Float(flatData.count)
        return sqrt(variance)
    }
    
    // 2차원 배열의 최솟값 계산
    func calculateMin(data: [[Float]]) -> Float {
        let flatData = data.flatMap { $0 }
        return flatData.min() ?? 0.0
    }
    
    // 2차원 배열의 최댓값 계산
    func calculateMax(data: [[Float]]) -> Float {
        let flatData = data.flatMap { $0 }
        return flatData.max() ?? 0.0
    }
    
    // 2차원 배열의 중앙값 계산
    func calculateMedian(data: [[Float]]) -> Float {
        let flatData = data.flatMap { $0 }
        guard !flatData.isEmpty else { return 0.0 }
        let sortedData = flatData.sorted()
        let mid = sortedData.count / 2
        if sortedData.count % 2 == 0 {
            return (sortedData[mid - 1] + sortedData[mid]) / 2
        } else {
            return sortedData[mid]
        }
    }
    
    // 2차원 배열의 분위수 계산 (25번째 또는 75번째 백분위수)
    func calculateQuantile(data: [[Float]], quantile: Float) -> Float {
        let flatData = data.flatMap { $0 }
        guard !flatData.isEmpty else { return 0.0 }
        let sortedData = flatData.sorted()
        let index = Int(quantile * Float(sortedData.count - 1))
        return sortedData[index]
    }
    
    // 2차원 배열의 첨도 계산
    func calculateSkewness(data: [[Float]]) -> Float {
        let flatData = data.flatMap { $0 }
        guard !flatData.isEmpty else { return 0.0 }
        let mean = flatData.reduce(0, +) / Float(flatData.count)
        let std = calculateStd(data: data)
        guard std > 0 else { return 0.0 }
        var sum: Float = 0.0
        for x in flatData {
            sum += pow(x - mean, 3)
        }
        return sum / (Float(flatData.count) * pow(std, 3))
    }
    
    // 2차원 배열의 왜도 계산
    func calculateKurtosis(data: [[Float]]) -> Float {
        let flatData = data.flatMap { $0 }
        guard !flatData.isEmpty else { return 0.0 }
        let mean = flatData.reduce(0, +) / Float(flatData.count)
        let std = calculateStd(data: data)
        guard std > 0 else { return 0.0 }
        var sum: Float = 0.0
        for x in flatData {
            sum += pow(x - mean, 4)
        }
        return (sum / (Float(flatData.count) * pow(std, 4))) - 3
    }
    
    // 2차원 배열의 에너지 계산
    func calculateEnergy(data: [[Float]]) -> Float {
        let flatData = data.flatMap { $0 }
        guard !flatData.isEmpty else { return 0.0 }
        var sumOfSquares: Float = 0.0
        var squaredData = [Float](repeating: 0.0, count: flatData.count)
        vDSP_vsq(flatData, 1, &squaredData, 1, vDSP_Length(flatData.count))
        vDSP_sve(squaredData, 1, &sumOfSquares, vDSP_Length(squaredData.count))
        return sumOfSquares
    }
    
    // 2차원 배열의 RMS (제곱평균제곱근) 계산
    func calculateRMS(data: [[Float]]) -> Float {
        let flatData = data.flatMap { $0 }
        guard !flatData.isEmpty else { return 0.0 }
        var sumOfSquares: Float = 0.0
        var squaredData = [Float](repeating: 0.0, count: flatData.count)
        vDSP_vsq(flatData, 1, &squaredData, 1, vDSP_Length(flatData.count))
        vDSP_sve(squaredData, 1, &sumOfSquares, vDSP_Length(squaredData.count))
        return sqrt(sumOfSquares / Float(flatData.count))
    }
    
    // 2차원 배열의 피크값 계산
    func calculatePeak(data: [[Float]]) -> Float {
        let flatData = data.flatMap { $0 }
        return flatData.max() ?? 0.0
    }
    
    // 2차원 배열의 크레스트 팩터 계산
    func calculateCrestFactor(data: [[Float]]) -> Float {
        let flatData = data.flatMap { $0 }
        guard !flatData.isEmpty else { return 0.0 }
        let peak = calculatePeak(data: data)
        let rms = calculateRMS(data: data)
        guard rms > 0 else { return 0.0 }
        return peak / rms
    }
    
    // 2차원 배열의 스펙트럼 기울기 계산
    func calculateSpectralSlope(spectrogram: [[Float]], sampleRate: Float, n_fft: Int) -> Float {
        guard !spectrogram.isEmpty else { return 0.0 }
        
        var slopes: [Float] = []
        let fftBins = n_fft / 2
        let frequencies = (0..<fftBins).map { Float($0) * sampleRate / Float(n_fft) }
        
        for frame in spectrogram {
            guard frame.count > 1 else { continue }
            var sumX: Float = 0.0
            var sumY: Float = 0.0
            var sumXY: Float = 0.0
            var sumX2: Float = 0.0
            
            for i in 0..<frame.count {
                sumX += frequencies[i]
                sumY += frame[i]
                sumXY += frequencies[i] * frame[i]
                sumX2 += frequencies[i] * frequencies[i]
            }
            
            let numerator = Float(frame.count) * sumXY - sumX * sumY
            let denominator = Float(frame.count) * sumX2 - sumX * sumX
            
            if denominator != 0 {
                slopes.append(numerator / denominator)
            } else {
                slopes.append(0.0)
            }
        }
        return slopes.reduce(0, +) / Float(slopes.count)
    }
    
    // 2차원 배열의 조화평균 계산
    func calculateHarmonicMean(data: [[Float]]) -> Float {
        let flatData = data.flatMap { $0 }
        guard !flatData.isEmpty else { return 0.0 }
        var sumReciprocals: Float = 0.0
        for x in flatData {
            if x != 0 {
                sumReciprocals += 1 / x
            }
        }
        guard sumReciprocals > 0 else { return 0.0 }
        return Float(flatData.count) / sumReciprocals
    }
    
    // 2차원 배열의 엔트로피 계산
    func calculateEntropy(data: [[Float]]) -> Float {
        let flatData = data.flatMap { $0 }
        guard !flatData.isEmpty else { return 0.0 }
        
        let totalSum = flatData.reduce(0, +)
        guard totalSum > 0 else { return 0.0 }
        
        var entropy: Float = 0.0
        for x in flatData {
            if x > 0 {
                let p = x / totalSum
                entropy -= p * log2(p)
            }
        }
        return entropy
    }
    
    // 멜 스펙트로그램을 로그 멜 스펙트로그램으로 변환
    func logMelSpectrogram(melSpec: [[Float]]) -> [[Float]] {
        return melSpec.map { frame in
            frame.map { value in
                log10(max(1e-10, value)) // log(0) 방지를 위해 작은 엡실론 추가
            }
        }
    }
    
    // 이산 코사인 변환 (DCT) 타입 II
    func dct(input: [Float], numCoefficients: Int) -> [Float] {
        let N = input.count
        var output = [Float](repeating: 0.0, count: numCoefficients)
        
        for k in 0..<numCoefficients {
            var sum: Float = 0.0
            for n in 0..<N {
                sum += input[n] * cos(Float.pi * Float(k) * (2 * Float(n) + 1) / (2 * Float(N)))
            }
            output[k] = sum * sqrt(2.0 / Float(N))
            if k == 0 {
                output[k] *= (1.0 / sqrt(2.0))
            }
        }
        return output
    }
    
    // 헤르츠(Hz)를 멜(Mel)로 변환
    func hzToMel(_ hz: Float) -> Float {
        return 2595 * log10(1 + hz / 700)
    }
    
    // 멜(Mel)을 헤르츠(Hz)로 변환
    func melToHz(_ mel: Float) -> Float {
        return 700 * (pow(10, mel / 2595) - 1)
    }
    
    // 멜 필터 뱅크 생성
    func melFilterBank(n_fft: Int, n_mels: Int, sampleRate: Float) -> [[Float]] {
        let maxHz = sampleRate / 2
        let minMel = hzToMel(0)
        let maxMel = hzToMel(maxHz)
        
        let melPoints = (0..<n_mels + 2).map { melToHz(minMel + Float($0) * (maxMel - minMel) / Float(n_mels + 1)) }
        
        let fftBins = n_fft / 2 + 1
        let binFrequencies = (0..<fftBins).map { Float($0) * sampleRate / Float(n_fft) }
        
        var filterBank = [[Float]](repeating: [Float](repeating: 0.0, count: fftBins), count: n_mels)
        
        for i in 0..<n_mels {
            let leftMel = melPoints[i]
            let centerMel = melPoints[i+1]
            let rightMel = melPoints[i+2]
            
            for j in 0..<fftBins {
                let freq = binFrequencies[j]
                var weight: Float = 0.0
                if freq > leftMel && freq <= centerMel {
                    weight = (freq - leftMel) / (centerMel - leftMel)
                } else if freq > centerMel && freq < rightMel {
                    weight = (rightMel - freq) / (rightMel - centerMel)
                }
                filterBank[i][j] = weight
            }
        }
        return filterBank
    }
    
    // 멜 스펙트로그램 계산
    func melSpectrogram(spectrogram: [[Float]], melFilterBank: [[Float]]) -> [[Float]] {
        var melSpec: [[Float]] = []
        for frame in spectrogram {
            var melFrame = [Float](repeating: 0.0, count: melFilterBank.count)
            for i in 0..<melFilterBank.count {
                var sum: Float = 0.0
                vDSP_dotpr(frame, 1, melFilterBank[i], 1, &sum, vDSP_Length(frame.count))
                melFrame[i] = sum
            }
            melSpec.append(melFrame)
        }
        return melSpec
    }
    
    // Fundamental frequency estimation (autocorrelation, naive)
    func estimateFundamentalFrequency(samples: [Float], sampleRate: Float, minHz: Float = 50, maxHz: Float = 1000) -> Float {
        guard samples.count > 1 else { return 0.0 }
        let minLag = Int(sampleRate / maxHz)
        let maxLag = Int(sampleRate / minHz)
        var bestLag = minLag
        var maxCorr: Float = 0.0
        for lag in minLag...maxLag {
            var sum: Float = 0.0
            for i in 0..<(samples.count - lag) {
                sum += samples[i] * samples[i + lag]
            }
            if sum > maxCorr {
                maxCorr = sum
                bestLag = lag
            }
        }
        return bestLag > 0 ? sampleRate / Float(bestLag) : 0.0
    }
    
    // Sub-band energy ratio calculator helper
    func subbandEnergyRatio(samples: [Float], sampleRate: Float) -> Float {
        let n_fft = 2048
        var fftReal = [Float](samples.prefix(n_fft))
        if fftReal.count < n_fft { fftReal += Array(repeating: 0, count: n_fft - fftReal.count) }
        var imag = [Float](repeating: 0, count: n_fft)
        var splitComplex = DSPSplitComplex(realp: &fftReal, imagp: &imag)
        let log2n = vDSP_Length(log2(Float(n_fft)))
        let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        fftReal.withUnsafeMutableBufferPointer { realPtr in
            realPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n_fft/2) { complexPtr in
                vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(n_fft/2))
            }
        }
        vDSP_fft_zrip(fftSetup!, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
        var mags = [Float](repeating: 0, count: n_fft/2)
        vDSP_zvmags(&splitComplex, 1, &mags, 1, vDSP_Length(n_fft/2))
        vDSP_destroy_fftsetup(fftSetup)
        func bandEnergy(_ lowHz: Float, _ highHz: Float) -> Float {
            let lowBin = Int(lowHz / sampleRate * Float(n_fft))
            let highBin = Int(highHz / sampleRate * Float(n_fft))
            guard lowBin < highBin && highBin < mags.count else { return 0 }
            return mags[lowBin..<highBin].reduce(0, +)
        }
        let e1 = bandEnergy(250, 3000)
        let e2 = bandEnergy(3000, 8000)
        return e2 > 0 ? e1 / e2 : 0
    }
    
    private func extractFeatures(samples: [Float], sampleRate: Float) -> [Float] {
        var features: [Float] = []
        
        // Add fundamental frequency and sub-band ratio estimation early
        let fundamental = estimateFundamentalFrequency(samples: samples, sampleRate: sampleRate)
        let subband = subbandEnergyRatio(samples: samples, sampleRate: sampleRate)
        
        // 특징 추출을 위한 상수들
        let n_fft: Int = 2048
        let hop_length: Int = 512
        let n_mels: Int = 128
        
        // 스펙트럼 특징을 위해 STFT를 한 번 계산
        let spectrogram = stft(samples: samples, n_fft: n_fft, hop_length: hop_length)
        
        // 멜 필터 뱅크 및 멜 스펙트로그램 계산
        let melFB = melFilterBank(n_fft: n_fft, n_mels: n_mels, sampleRate: sampleRate)
        let melSpec = melSpectrogram(spectrogram: spectrogram, melFilterBank: melFB)
        
        // --- 1. MFCC Features (13) ---
        let logMelSpec = logMelSpectrogram(melSpec: melSpec)
        var mfccs: [Float] = []
        for frame in logMelSpec {
            let dctCoefficients = dct(input: frame, numCoefficients: 13)
            mfccs.append(contentsOf: dctCoefficients)
        }
        // Take the mean of MFCCs across all frames
        if !mfccs.isEmpty {
            let frameCount = Float(logMelSpec.count)
            for i in 0..<13 {
                var sum: Float = 0.0
                for j in 0..<logMelSpec.count {
                    sum += mfccs[j * 13 + i]
                }
                features.append(sum / frameCount)
            }
        } else {
            features.append(contentsOf: Array(repeating: 0.0, count: 13))
        }
        
        // --- 2. Spectral Features (7) ---
        let spectralCentroids = calculateSpectralCentroid(spectrogram: spectrogram, sampleRate: sampleRate, n_fft: n_fft)
        features.append(spectralCentroids.reduce(0, +) / Float(spectralCentroids.count)) // spectral_centroid
        let spectralBandwidth = calculateSpectralBandwidth(spectrogram: spectrogram, spectralCentroids: spectralCentroids, sampleRate: sampleRate, n_fft: n_fft)
        features.append(spectralBandwidth) // spectral_bandwidth
        let spectralContrast = calculateSpectralContrast(spectrogram: spectrogram)
        features.append(spectralContrast) // spectral_contrast
        let spectralFlatness = calculateSpectralFlatness(spectrogram: spectrogram)
        features.append(spectralFlatness) // spectral_flatness
        let spectralRolloff = calculateSpectralRolloff(spectrogram: spectrogram, sampleRate: sampleRate, n_fft: n_fft)
        features.append(spectralRolloff) // spectral_rolloff
        let zeroCrossingRate = calculateZeroCrossingRate(samples: samples)
        features.append(zeroCrossingRate) // zero_crossing_rate
        let rmsEnergy = calculateRMSEnergy(samples: samples)
        features.append(rmsEnergy) // rmse_energy
        
        // --- 3. Energy Features (4) ---
        features.append(rmsEnergy) // rms_energy_mean
        let peakEnergy = samples.map { abs($0) }.max() ?? 0.0
        features.append(peakEnergy) // peak_energy
        
        let energyEntropy = calculateEnergyEntropy(samples: samples, frameSize: n_fft, hopSize: hop_length)
        features.append(energyEntropy) // energy_entropy
        
        let dynamicRange = calculateDynamicRange(peakEnergy: peakEnergy, rmsEnergy: rmsEnergy)
        features.append(dynamicRange) // dynamic_range
        
        // --- 4. Rhythm Features (3) ---
        let onsetStrengthMean = calculateOnsetStrengthMean(spectrogram: spectrogram)
        features.append(contentsOf: Array(repeating: 0.0, count: 2)) // tempo, beat_strength (Placeholders)
        features.append(onsetStrengthMean) // onset_strength_mean
        
        // --- 5. Watermelon Specific Features (8) ---
        // These are highly specialized and will require custom DSP.
        // Placeholder for now.
        features.append(contentsOf: Array(repeating: 0.0, count: 8)) // Placeholder
        
        // --- 6. Mel-Spectrogram Statistical Features (16) ---
        // Calculate mean of Mel Spectrogram
        let melSpecMean = melSpec.flatMap { $0 }.reduce(0, +) / Float(melSpec.flatMap { $0 }.count)
        features.append(melSpecMean) // mel_spec_mean
        let melSpecStd = calculateStd(data: melSpec)
        features.append(melSpecStd) // mel_spec_std
        let melSpecMin = calculateMin(data: melSpec)
        features.append(melSpecMin) // mel_spec_min
        let melSpecMax = calculateMax(data: melSpec)
        features.append(melSpecMax) // mel_spec_max
        let melSpecMedian = calculateMedian(data: melSpec)
        features.append(melSpecMedian) // mel_spec_median
        let melSpecQ25 = calculateQuantile(data: melSpec, quantile: 0.25)
        features.append(melSpecQ25) // mel_spec_q25
        let melSpecQ75 = calculateQuantile(data: melSpec, quantile: 0.75)
        features.append(melSpecQ75) // mel_spec_q75
        let melSpecSkewness = calculateSkewness(data: melSpec)
        features.append(melSpecSkewness) // mel_spec_skewness
        let melSpecKurtosis = calculateKurtosis(data: melSpec)
        features.append(melSpecKurtosis) // mel_spec_kurtosis
        let melSpecEnergy = calculateEnergy(data: melSpec)
        features.append(melSpecEnergy) // mel_spec_energy
        let melSpecRMS = calculateRMS(data: melSpec)
        features.append(melSpecRMS) // mel_spec_rms
        let melSpecPeak = calculatePeak(data: melSpec)
        features.append(melSpecPeak) // mel_spec_peak
        let melSpecCrestFactor = calculateCrestFactor(data: melSpec)
        features.append(melSpecCrestFactor) // mel_spec_crest_factor
        let melSpecSpectralSlope = calculateSpectralSlope(spectrogram: melSpec, sampleRate: sampleRate, n_fft: n_fft)
        features.append(melSpecSpectralSlope) // mel_spec_spectral_slope
        let melSpecHarmonicMean = calculateHarmonicMean(data: melSpec)
        features.append(melSpecHarmonicMean) // mel_spec_harmonic_mean
        let melSpecEntropy = calculateEntropy(data: melSpec)
        features.append(melSpecEntropy) // mel_spec_entropy
        
        // --- 7. Added Features (2) ---
        features.append(fundamental) // Fundamental Frequency
        features.append(subband)     // Sub-band Energy Ratio
        
        // Total features: 13 + 7 + 4 + 3 + 8 + 16 + 2 = 53
        assert(features.count == 53, "Expected 53 features, got \(features.count)")
        
        return features
    }
}
