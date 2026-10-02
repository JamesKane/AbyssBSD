// AgentLoop — model, tool, model, until the model answers (PHASE18 P18.8).
//
// It runs **inside** an agent jail, and everything it can do is bounded from
// outside: the model only through abyss-model's socket (its budget, its
// transcript), and the tools only within what the jail sees. The loop adds
// the bounds that are its own:
//
//   - a step limit per question, so a model that keeps calling tools stops
//     with a reason rather than running until the budget does;
//   - a refusal from abyss-model (the budget, HTTP 429) ends the question
//     with abyss-model's own words — the loop never retries around it;
//   - a tool's failure is the model's to see ("error: …"), never a crash.
//
// The conversation persists across questions in one session, as a chat does.

import Model

/// The model, as the loop sees it: a request in, a status and a body out.
public typealias ModelCall = (JSON) throws -> (status: Int, body: JSON)

public struct AgentTool: Sendable {
    public let name: String
    public let description: String
    public let parameters: JSON
    public let run: @Sendable (JSON) -> String

    public init(name: String, description: String, parameters: JSON, run: @escaping @Sendable (JSON) -> String) {
        self.name = name; self.description = description; self.parameters = parameters; self.run = run
    }

    var schema: JSON {
        .object([("type", .string("function")), ("function", .object([
            ("name", .string(name)), ("description", .string(description)), ("parameters", parameters)]))])
    }
}

public struct AgentAnswer: Equatable {
    public enum Stop: String, Equatable { case answered, steps, budget, failed }
    public var text: String
    public var stop: Stop
    /// The tools called, in order, as "name(arguments)".
    public var calls: [String]
    public var steps: Int
}

public final class AgentLoop {
    public let tools: [AgentTool]
    public let maxSteps: Int
    public private(set) var messages: [JSON]
    /// Each tool call as it starts, as "name(arguments)" — so the person
    /// watches what the agent does while it does it, not after.
    public var onCall: (String) -> Void = { _ in }
    let model: ModelCall

    public init(system: String, tools: [AgentTool], maxSteps: Int = 12, model: @escaping ModelCall) {
        self.tools = tools; self.maxSteps = maxSteps; self.model = model
        messages = [.object([("role", .string("system")), ("content", .string(system))])]
    }

    func request() -> JSON {
        var r: [(String, JSON)] = [("model", .string("default")), ("messages", .array(messages)),
                                   ("temperature", .number(0)), ("max_tokens", .number(1024)),
                                   // Thinking off: a tool call should be quick, and a
                                   // reasoning model can spend its reply thinking (§6b.1).
                                   ("chat_template_kwargs", .object([("enable_thinking", .bool(false))]))]
        if !tools.isEmpty { r.append(("tools", .array(tools.map(\.schema)))) }
        return .object(r)
    }

    public func ask(_ text: String) -> AgentAnswer {
        messages.append(.object([("role", .string("user")), ("content", .string(text))]))
        var calls: [String] = []
        for step in 1...maxSteps {
            let status: Int, body: JSON
            do { (status, body) = try model(request()) } catch {
                return AgentAnswer(text: "the model could not be reached: \(error)", stop: .failed, calls: calls, steps: step)
            }
            guard status == 200 else {
                let why = body["error"]?["message"]?.string ?? "abyss-model said \(status)"
                let stop: AgentAnswer.Stop = body["error"]?["type"]?.string == "budget" ? .budget : .failed
                return AgentAnswer(text: why, stop: stop, calls: calls, steps: step)
            }
            guard let msg = body["choices"]?[0]?["message"] else {
                return AgentAnswer(text: "the model's reply had no message", stop: .failed, calls: calls, steps: step)
            }
            let toolCalls = msg["tool_calls"]?.array ?? []
            // The assistant's turn goes into the conversation as it came, so
            // the tool results that follow answer the calls it made.
            var turn: [(String, JSON)] = [("role", .string("assistant")), ("content", msg["content"] ?? .null)]
            if !toolCalls.isEmpty { turn.append(("tool_calls", .array(toolCalls))) }
            messages.append(.object(turn))
            if toolCalls.isEmpty {
                return AgentAnswer(text: msg["content"]?.string ?? "", stop: .answered, calls: calls, steps: step)
            }
            for (i, call) in toolCalls.enumerated() {
                let name = call["function"]?["name"]?.string ?? ""
                let argText = call["function"]?["arguments"]?.string ?? "{}"
                let id = call["id"]?.string ?? "call\(step)-\(i)"
                calls.append("\(name)(\(argText))")
                onCall(calls.last!)
                let result: String
                if let tool = tools.first(where: { $0.name == name }) {
                    if let args = try? JSON.parse(argText) { result = tool.run(args) }
                    else { result = "error: the arguments are not JSON: \(argText)" }
                } else {
                    result = "error: there is no tool named \(name)"
                }
                messages.append(.object([("role", .string("tool")), ("tool_call_id", .string(id)),
                                         ("content", .string(result))]))
            }
        }
        return AgentAnswer(text: "stopped after \(maxSteps) steps without an answer", stop: .steps, calls: calls, steps: maxSteps)
    }
}

/// abyss-model over its unix socket: the only way out of the jail to a model.
public func modelOverSocket(_ path: String) -> ModelCall {
    { request in
        let r = try HTTP.call(.unix(path: path), method: "POST", path: "/v1/chat/completions", json: request)
        return (r.status, (try? JSON.parse(r.body)) ?? .null)
    }
}
