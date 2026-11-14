import Foundation
import RielaCore
import RielaNote

struct NotePageInput {
  var bodyMarkdown: String
  var readOnly: Bool
  var tags: [NoteTagInput]
  var metaJSON: String?
  var number: Int?
  var pageImageRef: String?
}

func notePageInputs(_ context: NoteAddonContext) throws -> [NotePageInput] {
  let value = context.value("pages")
  guard case let .array(values)? = value, !values.isEmpty else {
    throw noteAddonInvalidInput("riela/notebook-ingest-pages pages must be a non-empty array")
  }
  guard values.count <= context.maxPageCount else {
    throw noteAddonInvalidInput(
      "riela/notebook-ingest-pages pages has \(values.count) items; max \(context.maxPageCount)"
    )
  }
  return try values.enumerated().map { index, value in
    guard case let .object(page) = value else {
      throw noteAddonInvalidInput("riela/notebook-ingest-pages pages[\(index)] must be an object")
    }
    guard let body = nonEmptyString(page["bodyMarkdown"])
      ?? nonEmptyString(page["body"])
      ?? nonEmptyString(page["markdown"])
      ?? nonEmptyString(page["text"]) else {
      throw noteAddonInvalidInput(
        "riela/notebook-ingest-pages pages[\(index)].bodyMarkdown is required"
      )
    }
    let title = nonEmptyString(page["title"])
    let bodyMarkdown = title == nil || body.hasPrefix("# ")
      ? body
      : "# \(title ?? "")\n\n\(body)"
    return NotePageInput(
      bodyMarkdown: bodyMarkdown,
      readOnly: boolValue(page["readOnly"]) ?? true,
      tags: try noteTags(page["tags"]),
      metaJSON: noteMetaJSONString(page["meta"], page["metaJSON"]),
      number: intValue(page["number"]) ?? intValue(page["pageNumber"]),
      pageImageRef: nonEmptyString(page["pageImageRef"])
        ?? nonEmptyString(page["imageRef"])
    )
  }
}

func pageMetaJSON(_ page: NotePageInput) -> String? {
  var meta = page.metaJSON.flatMap(jsonObjectString)
  if page.number == nil, page.pageImageRef == nil {
    return page.metaJSON
  }
  if meta == nil {
    meta = [:]
  }
  if let number = page.number {
    meta?["number"] = .number(Double(number))
  }
  if let pageImageRef = page.pageImageRef {
    meta?["pageImageRef"] = .string(pageImageRef)
  }
  return JSONValue.object(meta ?? [:]).compactJSONStringOrEmpty()
}

func applyIngestedPageReadOnlyState(
  pages: [NotePageInput],
  notes: [Note],
  service: NoteService
) throws -> [Note] {
  try zip(notes, pages).map { note, page in
    page.readOnly ? try service.setReadOnly(noteId: note.noteId, readOnly: true) : note
  }
}

private func jsonObjectString(_ string: String) -> JSONObject? {
  guard let data = string.data(using: .utf8),
        case let .object(object) = try? JSONDecoder().decode(JSONValue.self, from: data) else {
    return nil
  }
  return object
}
