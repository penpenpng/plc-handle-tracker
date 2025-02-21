import Fluent
import Foundation
import Vapor

struct ImportExportLogCommand: AsyncCommand {
  struct Signature: CommandSignature {
    @Option(name: "count", short: nil)
    var count: UInt?
  }

  var help: String {
    "Import from https://plc.directory/export"
  }

  func run(using context: CommandContext, signature: Signature) async throws {
    let app = context.application
    var after: String? = nil
    if let last = try await PollingHistory.query(on: app.db).filter(\.$failed == false).sort(
      \.$insertedAt, .descending
    ).first() {
      guard last.completed else {
        throw "latest polling job not completed"
      }
      let dateFormatter = ISO8601DateFormatter()
      dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      after = dateFormatter.string(from: last.createdAt)
    }
    let (exportedLog, lastOp) = try await fetchExportedLog(
      app, after: after, count: signature.count ?? 1000)
    let pollingHistory = try await self.logToPollingHistory(app, lastOp: lastOp)
    do {
      try await app.queues.queue.dispatch(
        ImportExportedLogJob.self,
        .init(json: exportedLog, historyId: try pollingHistory.requireID())
      )
      if let after {
        context.console.print("Queued fetching export log, after \(after)")
      } else {
        context.console.print("Queued fetching export log")
      }
    } catch {
      app.logger.report(error: error)
      pollingHistory.failed = true
      try await pollingHistory.update(on: app.db)
    }
  }

  private func fetchExportedLog(_ app: Application, after: String?, count: UInt) async throws
    -> (String, ExportedOperation?)
  {
    var url: URI = "https://plc.directory/export"
    if let after {
      url.query = "count=\(count)&after=\(after)"
    } else {
      url.query = "count=\(count)"
    }
    let response = try await app.client.get(url)
    let decoder = try ContentConfiguration.global.requireDecoder(for: .plainText)
    let jsonLines = try response.content.decode(String.self, using: decoder).split(separator: "\n")
    let json = try jsonLines.last.map { lastOp in
      let decoder = try ContentConfiguration.global.requireDecoder(for: .json)
      return try decoder.decode(
        ExportedOperation.self, from: .init(string: String(lastOp)), headers: [:])
    }
    return ("[\(jsonLines.joined(separator: ","))]", json)
  }

  private func logToPollingHistory(_ app: Application, lastOp: ExportedOperation?) async throws
    -> PollingHistory
  {
    guard let lastOp else {
      throw "Empty export"
    }
    let pollingHistory = PollingHistory(cid: lastOp.cid, createdAt: lastOp.createdAt)
    try await pollingHistory.create(on: app.db)
    return pollingHistory
  }
}
