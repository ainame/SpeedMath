import JavaScriptKit

/// `fetch` POSTs of small JSON control messages to this site's API.
public enum BrowserHTTP {
  public enum Failure: Error {
    /// HTTP 429 from a rate limiter.
    case slow
    /// Any other failure: network, abort, non-2xx status, unreadable body.
    case unavailable
  }

  /// A request that can be aborted (which completes it with `.unavailable`).
  public final class Request {
    fileprivate let controller: AbortController?

    fileprivate init(controller: AbortController?) { self.controller = controller }

    public func abort() { try? controller?.abort() }
  }

  /// POSTs `body` as JSON to `/api/<path>` and returns the response text.
  @discardableResult
  public static func post(
    _ path: String, body: String, completion: @escaping (Result<String, Failure>) -> Void
  ) -> Request {
    let controller = try? AbortController()
    let request = Request(controller: controller)
    let options = FetchOptions(
      method: "POST", headers: ["Content-Type": "application/json"], body: body, signal: try? controller?.signal)
    guard let promise = try? fetch("/api/" + path, options) else {
      completion(.failure(.unavailable))
      return request
    }
    JS.then(
      promise.jsValue,
      { value in
        guard let object = value.object else { return completion(.failure(.unavailable)) }
        let response = Response(unsafelyWrapping: object)
        guard (try? response.ok) == true, let text = try? response.text() else {
          return completion(.failure((try? response.status) == 429 ? .slow : .unavailable))
        }
        JS.then(
          text.jsValue,
          { value in
            if let text = value.string { completion(.success(text)) } else { completion(.failure(.unavailable)) }
          }, { completion(.failure(.unavailable)) })
      }, { completion(.failure(.unavailable)) })
    return request
  }
}
