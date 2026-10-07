import EmbeddingCore
import Foundation
import LiteRTEmbeddingProvider

private actor ProbeCompletion {
  var completed = false
  func finish() { completed = true }
}

public struct KoreanRetrievalResult: Codable, Sendable {
  public let query: String
  public let expected: Int?
  public let topDocument: Int
  public let score: Double
  public let margin: Double
  public var matched: Bool? { expected.map { $0 == topDocument } }
}

public struct EmbeddingQualificationReport: Codable, Sendable {
  public let profile: EmbeddingProfile
  public let retrieval: [KoreanRetrievalResult]
  public let positiveMatches: Int
  public let positiveCount: Int
  public let inferenceMilliseconds: [Double]
  public let overflowRejected: Bool
  public let cancellationJoined: Bool
  public let reuseAfterCancellation: Bool
  public let closedAdmissionRejected: Bool
  public let reloadSucceeded: Bool
}

/// Approved synthetic Korean fixtures only. Quality results report misses;
/// they do not redefine a quality failure as an inference failure or PASS.
public enum EmbeddingQualification {
  public static func verifyAndClose(model: LiteRTEmbeddingModel, modelURL: URL, cacheDirectory: URL) async throws -> EmbeddingQualificationReport {
    let documents = [
      "금요일 오후 세 시에 치과 정기 검진을 예약했다. 보험증을 챙겨야 한다.",
      "토요일 아침 한강 공원에서 친구와 달리기 운동을 하기로 했다.",
      "부산 여행 숙소를 해운대 근처로 예약했다. 기차는 다음 주 월요일 출발한다.",
      "회사 출장 택시 비용을 돌려받으려면 영수증을 제출하고 경비 신청서를 작성해야 한다.",
      "어머니 생신 선물로 꽃다발을 주문했다. 배송일은 다음 달 십 일이다.",
      "프로젝트 회의는 수요일 오전 열 시다. 회의 전에 설계 문서를 읽어야 한다.",
      "아버지 생신 선물로 운동화를 주문했다. 배송일은 다음 달 십오 일이다.",
      "주말 독서 모임에서 소설을 읽고 감상을 나누기로 했다."
    ]
    let queries: [(String, Int?)] = [
      ("이를 검사하러 언제 가야 하지?", 0),
      ("친구랑 뛰기로 한 장소", 1),
      ("바닷가 여행 숙박 예약", 2),
      ("업무 이동에 쓴 돈을 환급받는 방법", 3),
      ("엄마 생일에 드릴 것", 4),
      ("설계 논의 전에 준비할 자료", 5),
      ("아빠에게 드릴 생일 선물", 6),
      ("책 이야기 나누는 모임", 7),
      ("화성 탐사선의 착륙 기록", nil)
    ]
    do {
      var timings: [Double] = []
      var corpus: [EmbeddingVector] = []
      for text in documents {
        let start = ContinuousClock.now
        corpus.append(try await model.embed(.document(text: text)))
        let elapsed = start.duration(to: .now).components
        timings.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
      }
      var retrieval: [KoreanRetrievalResult] = []
      for (query, expected) in queries {
        let vector = try await model.embed(.query(query))
        let ranking = try corpus.enumerated().map { (index: $0.offset, score: try vector.cosineSimilarity(to: $0.element)) }
          .sorted { $0.score > $1.score }
        retrieval.append(.init(query: query, expected: expected, topDocument: ranking[0].index,
          score: ranking[0].score, margin: ranking[0].score - ranking[1].score))
      }
      var overflowRejected = false
      do {
        _ = try await model.embed(.query(String(repeating: "hello ", count: 1200)))
      } catch EmbeddingFailure.nativeFailure(code: 3) {
        // Official canonical status 3 is INVALID_ARGUMENT. Other native
        // failures must propagate, not masquerade as successful overflow rejection.
        overflowRejected = true
      }
      let completion = ProbeCompletion()
      let pending = Task {
        do {
          let output = try await model.embed(.query(String(repeating: "hello ", count: 700)))
          await completion.finish()
          return output
        } catch {
          await completion.finish()
          throw error
        }
      }
      // Observe admission, not a timed assumption about native execution.
      while await model.status() == .ready, !(await completion.completed) { await Task.yield() }
      pending.cancel()
      var cancellationJoined = false
      do { _ = try await pending.value }
      catch is CancellationError { cancellationJoined = await model.status() == .ready }
      let reused = try await model.embed(.query("취소 뒤 재사용 확인"))
      try await model.shutdown()
      try await model.shutdown()
      var closedRejected = false
      do { _ = try await model.embed(.query("종료 뒤 요청")) }
      catch EmbeddingFailure.closed { closedRejected = true }
      let reloaded = try await LiteRTEmbeddingModel.load(modelURL: modelURL, cacheDirectory: cacheDirectory)
      let reloadSucceeded: Bool
      do {
        let vector = try await reloaded.embed(.query("재로딩 확인"))
        reloadSucceeded = vector.values.count == 256
        try await reloaded.shutdown()
      } catch {
        try await reloaded.shutdown()
        throw error
      }
      return .init(profile: model.profile, retrieval: retrieval,
        positiveMatches: retrieval.filter { $0.matched == true }.count,
        positiveCount: queries.filter { $0.1 != nil }.count,
        inferenceMilliseconds: timings, overflowRejected: overflowRejected,
        cancellationJoined: cancellationJoined, reuseAfterCancellation: reused.values.count == 256,
        closedAdmissionRejected: closedRejected, reloadSucceeded: reloadSucceeded)
    } catch {
      try await model.shutdown()
      throw error
    }
  }
}
