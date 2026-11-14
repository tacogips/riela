import Foundation

let runtimeVariablesElidedKeysMarker = "$rielaElidedKeys"
let runtimeVariablesSameAsMarker = "$rielaSameAs"

func deduplicatedRuntimeVariablesView(_ runtimeVariables: JSONObject) -> JSONObject {
  guard case var .object(rielaInput)? = runtimeVariables["_rielaInput"],
        case var .array(messages)? = rielaInput["messages"] else {
    return runtimeVariables
  }

  for index in messages.indices {
    guard case var .object(message) = messages[index],
          case var .object(payload)? = message["payload"] else {
      continue
    }
    let elidedKeys = payload.keys.filter { key in
      guard let topLevelValue = runtimeVariables[key], let payloadValue = payload[key],
            let topJSON = try? topLevelValue.compactJSONString(),
            let payloadJSON = try? payloadValue.compactJSONString() else {
        return false
      }
      return topJSON == payloadJSON
    }.sorted()
    for key in elidedKeys {
      payload.removeValue(forKey: key)
    }
    if !elidedKeys.isEmpty {
      payload[runtimeVariablesElidedKeysMarker] = .array(elidedKeys.map(JSONValue.string))
    }
    message["payload"] = .object(payload)
    messages[index] = .object(message)
  }

  rielaInput["messages"] = .array(messages)
  if !messages.isEmpty, case var .object(latest)? = rielaInput["latest"] {
    latest["payload"] = .object([
      runtimeVariablesSameAsMarker: .string("/_rielaInput/messages/\(messages.count - 1)/payload")
    ])
    rielaInput["latest"] = .object(latest)
  }
  var result = runtimeVariables
  result["_rielaInput"] = .object(rielaInput)
  return result
}
