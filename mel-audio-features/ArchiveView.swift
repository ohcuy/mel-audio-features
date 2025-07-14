import SwiftUI
import AVFoundation

let acousticFeatureIndices: [(name: String, idx: Int)] = [
    ("기본 주파수 (Hz)", 0),
    ("스펙트럼 중심 (Hz)", 13),
    ("제로 크로싱 비율", 18),
    ("RMS", 19),
    ("멜스펙트로그램 엔트로피", 48),
    ("서브밴드 에너지 비율", 49)
]

// 핵심 10가지 특징
enum CoreFeature: String, CaseIterable {
    case fundamentalFrequency = "fundamental_frequency"
    case melSpecMedian = "mel_spec_median"
    case spectralRolloff = "spectral_rolloff"
    case melSpecQ75 = "mel_spec_q75"
    case melSpecRms = "mel_spec_rms"
    case mfcc5 = "MFCC_5"
    case mfcc13 = "MFCC_13"
    case mfcc10 = "MFCC_10"
    case melSpecKurtosis = "mel_spec_kurtosis"
    case decayRate = "decay_rate"
}

// 특징 이름 리스트에서 CoreFeature의 인덱스 찾기
extension Array where Element == String {
    func index(for feature: CoreFeature) -> Int? {
        if let idx = self.firstIndex(where: { $0.caseInsensitiveCompare(feature.rawValue) == .orderedSame }) {
            return idx
        }

        switch feature {
        case .mfcc5: return self.firstIndex { $0.lowercased().contains("mfcc_5") }
        case .mfcc10: return self.firstIndex { $0.lowercased().contains("mfcc_10") }
        case .mfcc13: return self.firstIndex { $0.lowercased().contains("mfcc_13") }
        default: return nil
        }
    }
}

struct ArchiveView: View {
    @ObservedObject var audioFeatureExtractor: AudioFeatureExtractor
    let featureNames: [String]
    let featureCategories: [(name: String, count: Int)]
    
    // 카테고리 이름과 인덱스 범위 매핑
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

    @State private var playingRecordID: UUID? = nil
    @State private var audioPlayer: AVAudioPlayer?
    
    // 선택된 녹음 파일 2개
    @State private var selectedRecords: [ArchiveRecord] = []
    
    // 아카이브 최신순 정렬
    var sortedArchive: [ArchiveRecord] {
        audioFeatureExtractor.archive.sorted { $0.date > $1.date }
    }
    
    func deleteRecord(at offsets: IndexSet) {
        for offset in offsets {
            let record = sortedArchive[offset]
            // audioFeatureExtractor.archive에서 삭제
            if let index = audioFeatureExtractor.archive.firstIndex(where: { $0.id == record.id }) {
                audioFeatureExtractor.archive.remove(at: index)
                audioFeatureExtractor.saveArchive()
            }
            // 선택 목록에서도 제거
            if let selIdx = selectedRecords.firstIndex(where: { $0.id == record.id }) {
                selectedRecords.remove(at: selIdx)
            }
        }
    }
    
    func play(record: ArchiveRecord) {
        let url = audioFeatureExtractor.getDocumentsDirectory().appendingPathComponent(record.audioFileName)
        do {
            audioPlayer?.stop()
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            playingRecordID = record.id
        } catch {
            print("Playback error: \(error)")
        }
    }
    
    var body: some View {
        VStack {
            Text("녹음된 소리들")
                .font(.largeTitle)
                .padding(.bottom, 8)
            if audioFeatureExtractor.archive.isEmpty {
                Text("저장된 녹음이 없습니다.")
                    .foregroundColor(.gray)
            } else {
                List {
                    ForEach(sortedArchive) { record in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("날짜: \(record.date.formatted(.dateTime))")
                                    .font(.subheadline)
                                Spacer()
                                Button(action: { play(record: record) }) {
                                    Image(systemName: playingRecordID == record.id ? "stop.circle.fill" : "play.circle.fill")
                                        .resizable()
                                        .frame(width: 32, height: 32)
                                        .foregroundColor(playingRecordID == record.id ? .red : .blue)
                                }
                                // 선택 버튼
                                Button(action: {
                                    if let idx = selectedRecords.firstIndex(where: { $0.id == record.id }) {
                                        selectedRecords.remove(at: idx)
                                    } else {
                                        if selectedRecords.count < 2 {
                                            selectedRecords.append(record)
                                        } else {
                                            // 선택 버튼
                                            selectedRecords.removeFirst()
                                            selectedRecords.append(record)
                                        }
                                    }
                                }) {
                                    Image(systemName: selectedRecords.contains(where: { $0.id == record.id }) ? "checkmark.circle.fill" : "circle")
                                        .resizable()
                                        .frame(width: 24, height: 24)
                                        .foregroundColor(.green)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                VStack(alignment: .leading) {
                                    ForEach(categoryRanges, id: \.name) { category in
                                        Section(header: Text(category.name).font(.headline)) {
                                            HStack(spacing: 12) {
                                                ForEach(category.range, id: \.self) { idx in
                                                    if idx < record.features.count && idx < featureNames.count {
                                                        VStack(alignment: .leading) {
                                                            Text(featureNames[idx])
                                                                .font(.caption2)
                                                                .foregroundColor(.secondary)
                                                            Text(String(format: "%.4f", record.features[idx]))
                                                                .font(.caption)
                                                        }
                                                    } else if idx < record.features.count {
                                                        VStack(alignment: .leading) {
                                                            Text("Unknown \(idx)")
                                                                .font(.caption2)
                                                            Text(String(format: "%.4f", record.features[idx]))
                                                                .font(.caption)
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .background(selectedRecords.contains(where: { $0.id == record.id }) ? Color.green.opacity(0.1) : Color.clear)
                        .cornerRadius(8)
                    }
                    .onDelete(perform: deleteRecord)
                }
                
                if selectedRecords.count == 2 {
                    VStack(alignment: .leading) {
                        Text("선택한 두 🍉 소리의 핵심 특징 비교").font(.headline).padding(.top)
                        let rec1 = selectedRecords[0]
                        let rec2 = selectedRecords[1]

                        ForEach(acousticFeatureIndices, id: \.name) { feature in
                            HStack {
                                Text(feature.name)
                                    .frame(width: 150, alignment: .leading)
                                    .font(.caption)
                                if feature.idx < rec1.features.count && feature.idx < rec2.features.count {
                                    Text(String(format: "%.4f", rec1.features[feature.idx]))
                                        .frame(width: 80, alignment: .trailing)
                                        .foregroundColor(.blue)
                                    Text("vs")
                                        .foregroundColor(.gray)
                                    Text(String(format: "%.4f", rec2.features[feature.idx]))
                                        .frame(width: 80, alignment: .trailing)
                                        .foregroundColor(.red)
                                } else {
                                    Text("-").foregroundColor(.gray)
                                    Text("")
                                    Text("-").foregroundColor(.gray)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color.yellow.opacity(0.07))
                    .cornerRadius(12)
                }
            }
        }
        .padding()
    }
}
