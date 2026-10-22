import Foundation

/// Metadata-only configuration: no credentials or provider request can succeed.
func writeOfflineGmailSDKConfiguration(in root: URL) throws -> URL {
  let config = root.appendingPathComponent("gmail.toml")
  try """
  [storage]
  cache_dir = "cache"
  attachment_dir = "attachments"
  allowed_send_attachment_roots = []
  [[credentials]]
  id = "gmail-personal"
  provider = "gmail"
  access_mode = "read_send"
  oauth_client_secret_path = "missing-client.json"
  token_store_path = "missing-token.json"
  [[accounts]]
  id = "personal"
  provider = "gmail"
  email_address = "fixture@example.test"
  credential_id = "gmail-personal"
  default_label_ids = ["INBOX"]
  """.write(to: config, atomically: true, encoding: .utf8)
  return config
}
