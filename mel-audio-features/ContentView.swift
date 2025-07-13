import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var audioFeatureExtractor = AudioFeatureExtractor()

    let featureNames: [String] = [
        // MFCC Features (13)
        "MFCC_1", "MFCC_2", "MFCC_3", "MFCC_4", "MFCC_5", "MFCC_6", "MFCC_7", "MFCC_8", "MFCC_9", "MFCC_10", "MFCC_11", "MFCC_12", "MFCC_13",
        // Spectral Features (7)
        "spectral_centroid", "spectral_bandwidth", "spectral_contrast", "spectral_flatness", "spectral_rolloff", "zero_crossing_rate", "rmse_energy",
        // Energy Features (4)
        "rms_energy_mean", "peak_energy", "energy_entropy", "dynamic_range",
        // Rhythm Features (3)
        "tempo", "beat_strength", "onset_strength_mean",
        // Watermelon Specific Features (8)
        "fundamental_frequency", "harmonic_ratio", "attack_time", "decay_rate", "sustain_level", "brightness", "roughness", "inharmonicity",
        // Mel-Spectrogram Statistical Features (16)
        "mel_spec_mean", "mel_spec_std", "mel_spec_min", "mel_spec_max", "mel_spec_median", "mel_spec_q25", "mel_spec_q75", "mel_spec_skewness", "mel_spec_kurtosis", "mel_spec_energy", "mel_spec_entropy", "mel_spec_rms", "mel_spec_peak", "mel_spec_crest_factor", "mel_spec_spectral_slope", "mel_spec_harmonic_mean"
    ]
    
    let featureCategories: [(name: String, count: Int)] = [
        ("MFCC Features", 13),
        ("Spectral Features", 7),
        ("Energy Features", 4),
        ("Rhythm Features", 3),
        ("Watermelon Specific Features", 8),
        ("Mel-Spectrogram Statistical Features", 16)
    ]
    
    var categoryRanges: [(name: String, range: Range<Int>)] {
        var result: [(String, Range<Int>)] = []
        var start = 0
        for (name, count) in featureCategories {
            let range = start..<(start+count)
            result.append((name, range))
            start += count
        }
        return result
    }

    var body: some View {
        TabView {
            VStack {
                Text("수박 두드리는 소리 👊")
                    .font(.largeTitle)
                    .padding()

                if audioFeatureExtractor.isRecording {
                    Text("Recording...")
                        .foregroundColor(.red)
                } else {
                    Text("Ready to record")
                        .foregroundColor(.green)
                }

                Button(action: {
                    if audioFeatureExtractor.isRecording {
                        audioFeatureExtractor.stopRecording()
                    } else {
                        audioFeatureExtractor.startRecording()
                    }
                }) {
                    Text(audioFeatureExtractor.isRecording ? "Stop Recording" : "Start Recording")
                        .font(.title2)
                        .padding()
                        .background(audioFeatureExtractor.isRecording ? Color.red : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding()

                if let errorMessage = audioFeatureExtractor.errorMessage {
                    Text("Error: \(errorMessage)")
                        .foregroundColor(.red)
                        .padding()
                }

                if let features = audioFeatureExtractor.extractedFeatures {
                    Text("추출된 특징들:")
                        .font(.headline)
                        .padding(.top)
                    
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(categoryRanges, id: \.name) { category in
                                Section(header: Text(category.name).font(.headline).padding(.top)) {
                                    ForEach(category.range, id: \.self) { idx in
                                        if idx < features.count && idx < featureNames.count {
                                            Text("\(featureNames[idx]): \(String(format: "%.4f", features[idx]))")
                                        } else if idx < features.count {
                                            Text("Unknown Feature \(idx): \(String(format: "%.4f", features[idx]))")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .tabItem {
                Label("측정", systemImage: "mic")
            }
            
            ArchiveView(audioFeatureExtractor: audioFeatureExtractor, featureNames: featureNames, featureCategories: featureCategories)
                .tabItem {
                    Label("아카이브", systemImage: "archivebox")
                }
        }
    }
}


#Preview {
    ContentView()
}
